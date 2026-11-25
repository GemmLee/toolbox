import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'quiz_models.dart';
import 'quiz_schema.dart';
import '../logic/quiz_initials.dart';
import '../logic/quiz_search.dart';

/// 数据库入口。
///
/// 生产环境使用 sqflite 插件工厂；测试可先
/// `databaseFactory = databaseFactoryFfi` 并传入 [path] 为内存库。
class QuizDb {
  QuizDb._(this.db);

  final Database db;

  static QuizDb? _instance;

  /// 进程内单例（首次调用时打开）。
  static Future<QuizDb> instance({String? path}) async {
    final existing = _instance;
    if (existing != null && path == null) return existing;
    final file = path ?? join(await getDatabasesPath(), 'quiz.db');
    final db = await databaseFactory.openDatabase(
      file,
      options: OpenDatabaseOptions(
        version: quizSchemaVersion,
        onCreate: (db, version) => migrateQuiz(db, 0, version),
        onUpgrade: (db, from, to) => migrateQuiz(db, from, to),
      ),
    );
    final instance = QuizDb._(db);
    if (path == null) _instance = instance;
    return instance;
  }

  /// 关闭（测试用）。
  Future<void> close() async {
    _instance = null;
    await db.close();
  }
}

/// 搜索结果项。
class SearchHit {
  const SearchHit({
    required this.question,
    required this.bankName,
    this.relevance = 0,
  });

  final Question question;
  final String bankName;

  /// 关键词模式下的内部相关度，只用于排序，不展示给用户。
  final double relevance;
}

/// 分页搜索结果。
class SearchResult {
  const SearchResult({required this.items, required this.total});

  final List<SearchHit> items;
  final int total;
}

/// 题库数据仓库：所有 SQL 集中在此，UI 只调用本类。
class QuizRepository {
  QuizRepository(this.db);

  final Database db;

  // ---------- 题库 ----------

  Future<List<Bank>> listBanks() async {
    final rows = await db.rawQuery('''
      SELECT b.*,
        IFNULL(q.c, 0) AS questionCount,
        IFNULL(w.c, 0) AS wrongCount,
        IFNULL(f.c, 0) AS favoriteCount
      FROM banks b
      LEFT JOIN (SELECT bankId, COUNT(*) c FROM questions GROUP BY bankId) q
        ON q.bankId = b.id
      LEFT JOIN (SELECT bankId, COUNT(*) c FROM wrong_entries GROUP BY bankId) w
        ON w.bankId = b.id
      LEFT JOIN (SELECT bankId, COUNT(*) c FROM favorites GROUP BY bankId) f
        ON f.bankId = b.id
      ORDER BY b.createdAt DESC
    ''');
    return rows.map(Bank.fromRow).toList();
  }

  /// 单个题库（带上题目 / 错题 / 收藏计数，与列表口径一致）。
  Future<Bank?> bankById(String id) async {
    for (final bank in await listBanks()) {
      if (bank.id == id) return bank;
    }
    return null;
  }

  Future<void> renameBank(String id, String name) => db.update(
        'banks',
        <String, Object?>{'name': name},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

  Future<String> createBank({
    required String name,
    String? importId,
    String? description,
  }) async {
    final id = newId();
    await db.insert('banks', <String, Object?>{
      'id': id,
      'name': name,
      'importId': importId,
      'description': description,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  /// 删除题库，级联删除题目、错题、收藏与该题库的会话（含作答）。
  Future<void> deleteBank(String id) async {
    await db.transaction((txn) async {
      final sessions = await txn.query('sessions',
          columns: <String>['id'],
          where: 'bankId = ?',
          whereArgs: <Object?>[id]);
      for (final s in sessions) {
        await txn.delete('session_questions',
            where: 'sessionId = ?', whereArgs: <Object?>[s['id']]);
      }
      await txn
          .delete('sessions', where: 'bankId = ?', whereArgs: <Object?>[id]);
      await txn
          .delete('questions', where: 'bankId = ?', whereArgs: <Object?>[id]);
      await txn.delete('wrong_entries',
          where: 'bankId = ?', whereArgs: <Object?>[id]);
      await txn
          .delete('favorites', where: 'bankId = ?', whereArgs: <Object?>[id]);
      await txn.delete('notes', where: 'bankId = ?', whereArgs: <Object?>[id]);
      await txn.delete('study_history',
          where: 'bankId = ?', whereArgs: <Object?>[id]);
      await txn.delete('banks', where: 'id = ?', whereArgs: <Object?>[id]);
    });
  }

  /// 合并题库：把 [sourceIds] 的题目迁入 [targetId]，删除来源题库。
  ///
  /// 只搬题目，不搬会话/错题/收藏/笔记——那些记录仍指向来源题库，
  /// 来源删除时会一并清掉，避免把历史状态错误地挂到目标题库上。
  /// 题目按 contentHash 去重（空 hash 按题干+答案生成），保留目标原有顺序。
  /// 返回实际迁入的题目数。
  Future<int> mergeBanks(String targetId, List<String> sourceIds) async {
    final sources = sourceIds.where((id) => id != targetId).toList();
    if (sources.isEmpty) return 0;
    var moved = 0;
    await db.transaction((txn) async {
      final targetRows = await txn.query('questions',
          columns: <String>['contentHash', 'stem', 'answerJson'],
          where: 'bankId = ?',
          whereArgs: <Object?>[targetId]);
      final seen = <String>{
        for (final row in targetRows)
          _questionKey(
            row['contentHash'],
            row['stem'],
            row['answerJson'],
          ),
      };
      final maxOrder = await txn.rawQuery(
        'SELECT COALESCE(MAX(orderNo), 0) AS m FROM questions WHERE bankId = ?',
        <Object?>[targetId],
      );
      var orderNo = ((maxOrder.first['m'] as num?)?.toInt() ?? 0) + 1;
      for (final sourceId in sources) {
        final rows = await txn.query('questions',
            where: 'bankId = ?',
            whereArgs: <Object?>[sourceId],
            orderBy: 'orderNo ASC, rowid ASC');
        for (final row in rows) {
          final key = _questionKey(
            row['contentHash'],
            row['stem'],
            row['answerJson'],
          );
          if (!seen.add(key)) continue;
          final id = row['id'].toString();
          await txn.update(
              'questions',
              <String, Object?>{
                'bankId': targetId,
                'orderNo': orderNo++,
              },
              where: 'id = ?',
              whereArgs: <Object?>[id]);
          moved++;
        }
      }
      // 来源题库的会话/记录随题库一起清掉，避免残留悬挂数据。
      for (final sourceId in sources) {
        final sessions = await txn.query('sessions',
            columns: <String>['id'],
            where: 'bankId = ?',
            whereArgs: <Object?>[sourceId]);
        for (final s in sessions) {
          await txn.delete('session_questions',
              where: 'sessionId = ?', whereArgs: <Object?>[s['id']]);
        }
        for (final table in <String>[
          'sessions',
          'questions',
          'wrong_entries',
          'favorites',
          'notes',
          'study_history',
        ]) {
          await txn.delete(table,
              where: 'bankId = ?', whereArgs: <Object?>[sourceId]);
        }
        await txn
            .delete('banks', where: 'id = ?', whereArgs: <Object?>[sourceId]);
      }
    });
    return moved;
  }

  static String _questionKey(Object? hash, Object? stem, Object? answer) {
    final h = hash?.toString().trim() ?? '';
    if (h.isNotEmpty) return h;
    return '${stem ?? ''}|${answer ?? ''}';
  }

  // ---------- 题目 ----------

  Future<void> insertQuestions(List<Question> questions) async {
    if (questions.isEmpty) return;
    final batch = db.batch();
    for (final q in questions) {
      batch.insert('questions', q.toRow());
    }
    await batch.commit(noResult: true);
  }

  Future<Question?> questionById(String id) async {
    final rows =
        await db.query('questions', where: 'id = ?', whereArgs: <Object?>[id]);
    return rows.isEmpty ? null : Question.fromRow(rows.first);
  }

  /// 覆盖保存题目内容（题干 / 选项 / 答案 / 解析 / 指纹）。
  /// id、bankId、题型与排序不变，避免影响正在进行的会话与错题/收藏关联。
  Future<void> updateQuestion(Question q) async {
    final row = q.toRow()..remove('id');
    await db
        .update('questions', row, where: 'id = ?', whereArgs: <Object?>[q.id]);
  }

  /// 把文本写入题目解析；题干 / 选项 / 答案与指纹保持不变。
  Future<Question> saveAnalysis(Question q, String analysis) async {
    final text = analysis.trim();
    final updated = q.withContent(
      stem: q.stem,
      options: q.options,
      answer: q.answer,
      analysis: text.isEmpty ? null : text,
    );
    await updateQuestion(updated);
    return updated;
  }

  Future<List<Question>> questionsOfBank(String bankId,
      {QuestionType? type, int limit = 50, int offset = 0}) async {
    final where = <String>['bankId = ?'];
    final args = <Object?>[bankId];
    if (type != null) {
      where.add('type = ?');
      args.add(type.key);
    }
    final rows = await db.query(
      'questions',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'orderNo ASC, rowid ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Question.fromRow).toList(growable: false);
  }

  /// 各题型库存数量。
  Future<Map<QuestionType, int>> stockOf(String? bankId) async {
    final where = bankId == null ? '' : 'WHERE bankId = ?';
    final args = bankId == null ? null : <Object?>[bankId];
    final rows = await db.rawQuery(
        'SELECT type, COUNT(*) c FROM questions $where GROUP BY type', args);
    final out = <QuestionType, int>{};
    for (final row in rows) {
      final type = QuestionTypeExt.fromKey(row['type'] as String?);
      if (type != null) out[type] = row['c'] as int? ?? 0;
    }
    return out;
  }

  /// 各题型「没做过」的库存数量（随机练习开关打开时显示）。
  Future<Map<QuestionType, int>> unseenStockOf(String? bankId) async {
    final bankWhere = bankId == null ? '' : ' AND bankId = ?';
    final args = bankId == null ? null : <Object?>[bankId];
    final rows = await db.rawQuery(
      'SELECT type, COUNT(*) c FROM questions '
      'WHERE id NOT IN ('
      'SELECT DISTINCT questionId FROM session_questions WHERE $_answeredWhere'
      ')$bankWhere GROUP BY type',
      args,
    );
    final out = <QuestionType, int>{};
    for (final row in rows) {
      final type = QuestionTypeExt.fromKey(row['type'] as String?);
      if (type != null) out[type] = row['c'] as int? ?? 0;
    }
    return out;
  }

  /// 已作答过的题目 id（跨全部历史会话）。
  ///
  /// 「做过」= 有作答内容、有判分结果或简答已自评。会话开始时预插入的
  /// 空白 session_questions 不计入，所以抽到但没答的题下次仍会出现。
  static const String _answeredWhere =
      "(userAnswerJson IS NOT NULL AND userAnswerJson NOT IN ('', '[]')) "
      'OR isCorrect IS NOT NULL OR selfJudged = 1';

  Future<Set<String>> answeredQuestionIds() async {
    final rows = await db.rawQuery(
        'SELECT DISTINCT questionId FROM session_questions WHERE $_answeredWhere');
    return rows.map((r) => r['questionId'] as String).toSet();
  }

  Future<List<Question>> questionsByIds(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return const <Question>[];
    final placeholders = List<String>.filled(list.length, '?').join(',');
    final rows = await db.rawQuery(
        'SELECT * FROM questions WHERE id IN ($placeholders) ORDER BY rowid',
        list);
    final byId = <String, Question>{
      for (final q in rows.map(Question.fromRow)) q.id: q,
    };
    return list.map((id) => byId[id]).whereType<Question>().toList();
  }

  // ---------- 错题 ----------

  /// 写入错题：INSERT OR IGNORE，已存在不更新任何字段。
  /// 同时把该题的「累计答对次数」清零，避免旧计数影响新一轮练习。
  Future<void> addWrong(String bankId, String questionId) async {
    await db.insert(
      'wrong_entries',
      <String, Object?>{'bankId': bankId, 'questionId': questionId},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await clearWrongCorrectCount(questionId);
  }

  Future<void> removeWrong(String bankId, String questionId) async {
    await db.delete(
      'wrong_entries',
      where: 'bankId = ? AND questionId = ?',
      whereArgs: <Object?>[bankId, questionId],
    );
    await clearWrongCorrectCount(questionId);
  }

  /// 错题累计答对次数存 settings 表的一个 JSON 里，无需为它加表 / 迁移 schema。
  static const String wrongCorrectCountKey = 'wrongCorrectCounts';

  Future<Map<String, int>> _wrongCorrectCounts() async {
    final raw = await getSetting(wrongCorrectCountKey);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return <String, int>{
          for (final entry in decoded.entries)
            '${entry.key}': entry.value is num
                ? (entry.value as num).toInt()
                : (int.tryParse('${entry.value}') ?? 0),
        };
      }
    } catch (_) {
      // 旧值损坏时按空表处理，不让练习流程崩掉。
    }
    return <String, int>{};
  }

  /// 记一次答对并返回累计次数；达到阈值后由调用方移出错题本。
  Future<int> bumpWrongCorrectCount(String questionId) async {
    final counts = await _wrongCorrectCounts();
    final next = (counts[questionId] ?? 0) + 1;
    counts[questionId] = next;
    await setSetting(wrongCorrectCountKey, jsonEncode(counts));
    return next;
  }

  Future<void> clearWrongCorrectCount(String questionId) async {
    final counts = await _wrongCorrectCounts();
    if (counts.remove(questionId) == null) return;
    await setSetting(wrongCorrectCountKey, jsonEncode(counts));
  }

  Future<bool> isWrong(String bankId, String questionId) async {
    final rows = await db.query('wrong_entries',
        where: 'bankId = ? AND questionId = ?',
        whereArgs: <Object?>[bankId, questionId]);
    return rows.isNotEmpty;
  }

  Future<Set<String>> wrongIds({String? bankId}) async {
    final where = bankId == null ? null : 'bankId = ?';
    final args = bankId == null ? null : <Object?>[bankId];
    final rows = await db.query('wrong_entries',
        columns: <String>['questionId'], where: where, whereArgs: args);
    return rows.map((r) => r['questionId'] as String).toSet();
  }

  Future<List<Question>> wrongQuestions({String? bankId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (bankId != null) {
      where.add('w.bankId = ?');
      args.add(bankId);
    }
    final rows = await db.rawQuery(
      'SELECT q.* FROM questions q '
      'JOIN wrong_entries w ON w.questionId = q.id '
      '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY q.bankId, q.orderNo',
      args,
    );
    return rows.map(Question.fromRow).toList(growable: false);
  }

  // ---------- 收藏 ----------

  Future<void> addFavorite(String bankId, String questionId) => db.insert(
        'favorites',
        <String, Object?>{'bankId': bankId, 'questionId': questionId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  Future<void> removeFavorite(String bankId, String questionId) => db.delete(
        'favorites',
        where: 'bankId = ? AND questionId = ?',
        whereArgs: <Object?>[bankId, questionId],
      );

  Future<bool> isFavorite(String bankId, String questionId) async {
    final rows = await db.query('favorites',
        where: 'bankId = ? AND questionId = ?',
        whereArgs: <Object?>[bankId, questionId]);
    return rows.isNotEmpty;
  }

  Future<Set<String>> favoriteIds({String? bankId}) async {
    final where = bankId == null ? null : 'bankId = ?';
    final args = bankId == null ? null : <Object?>[bankId];
    final rows = await db.query('favorites',
        columns: <String>['questionId'], where: where, whereArgs: args);
    return rows.map((r) => r['questionId'] as String).toSet();
  }

  Future<List<Question>> favoriteQuestions({String? bankId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (bankId != null) {
      where.add('f.bankId = ?');
      args.add(bankId);
    }
    final rows = await db.rawQuery(
      'SELECT q.* FROM questions q '
      'JOIN favorites f ON f.questionId = q.id '
      '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY q.bankId, q.orderNo',
      args,
    );
    return rows.map(Question.fromRow).toList(growable: false);
  }

  // ---------- 背题记录 ----------

  /// 标记某题为「已背」：INSERT OR REPLACE 更新时间，同一 (题库, 题) 只留一条。
  /// [at] 仅供测试注入固定时间，正常调用用当前时刻。
  Future<void> markStudied(String bankId, String questionId, {int? at}) async {
    await db.insert(
      'study_history',
      <String, Object?>{
        'bankId': bankId,
        'questionId': questionId,
        'studiedAt': at ?? DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 某题库已背过的题目 id 集合（背题页用于「已背过的题不出现」）。
  Future<Set<String>> studiedIds(String bankId) async {
    final rows = await db.query('study_history',
        columns: <String>['questionId'],
        where: 'bankId = ?',
        whereArgs: <Object?>[bankId]);
    return rows.map((r) => r['questionId'] as String).toSet();
  }

  /// 某题库已背过的题目（按最近一次背诵时间倒序，供记录栏展示）。
  Future<List<Question>> studiedQuestions(String bankId) async {
    final rows = await db.rawQuery(
      'SELECT q.* FROM questions q '
      'JOIN study_history s ON s.questionId = q.id '
      'WHERE s.bankId = ? ORDER BY s.studiedAt DESC',
      <Object?>[bankId],
    );
    return rows.map(Question.fromRow).toList(growable: false);
  }

  Future<int> countStudied(String bankId) async {
    final result = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM study_history WHERE bankId = ?',
        <Object?>[bankId]);
    return result.first['n'] as int? ?? 0;
  }

  Future<void> clearStudyHistory(String bankId) => db.delete(
        'study_history',
        where: 'bankId = ?',
        whereArgs: <Object?>[bankId],
      );

  // ---------- 会话 ----------

  Future<void> insertSession(QuizSession session) =>
      db.insert('sessions', session.toRow());

  Future<void> updateSession(QuizSession session) => db.update(
        'sessions',
        session.toRow(),
        where: 'id = ?',
        whereArgs: <Object?>[session.id],
      );

  /// 切题时只回写断点题号，避免整行更新覆盖计时等其它字段。
  Future<void> updateSessionIndex(String id, int index) => db.update(
        'sessions',
        <String, Object?>{'lastIndex': index},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

  Future<QuizSession?> sessionById(String id) async {
    final rows =
        await db.query('sessions', where: 'id = ?', whereArgs: <Object?>[id]);
    return rows.isEmpty ? null : QuizSession.fromRow(rows.first);
  }

  Future<List<QuizSession>> sessions(
      {SessionStatus? status, int limit = 20}) async {
    final where = status == null ? null : 'status = ?';
    final args = status == null ? null : <Object?>[status.key];
    // 按「最近动过」排：同时有多套没刷完时，首页要回到刚放下的那套。
    final rows = await db.query('sessions',
        where: where,
        whereArgs: args,
        orderBy: 'activeAt DESC, startedAt DESC',
        limit: limit);
    return rows.map(QuizSession.fromRow).toList(growable: false);
  }

  /// 某个题库的考试 / 练习记录（题库之间互不可见）。
  Future<List<QuizSession>> sessionsOfBank(String bankId,
      {int limit = 50}) async {
    final rows = await db.query('sessions',
        where: 'bankId = ?',
        whereArgs: <Object?>[bankId],
        orderBy: 'startedAt DESC',
        limit: limit);
    return rows.map(QuizSession.fromRow).toList(growable: false);
  }

  /// 某题库未完成的会话（最近动过的那套优先，「继续上次」用）。
  Future<QuizSession?> activeSessionOfBank(String bankId) async {
    final rows = await db.query('sessions',
        where: 'bankId = ? AND status = ?',
        whereArgs: <Object?>[bankId, SessionStatus.active.key],
        orderBy: 'activeAt DESC, startedAt DESC',
        limit: 1);
    return rows.isEmpty ? null : QuizSession.fromRow(rows.first);
  }

  /// 记录会话「最近动过」的时刻，首页据此决定「继续上次」指向哪一套。
  ///
  /// 只更新一列，不碰计时、断点与状态，避免和 [updateSession] 的全行写互相覆盖。
  Future<void> touchSession(String id, {int? at}) => db.update(
        'sessions',
        <String, Object?>{
          'activeAt': at ?? DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

  Future<void> insertSessionQuestions(List<SessionQuestion> items) async {
    if (items.isEmpty) return;
    final batch = db.batch();
    for (final item in items) {
      batch.insert('session_questions', item.toRow());
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateSessionQuestion(SessionQuestion item) => db.update(
        'session_questions',
        item.toRow(),
        where: 'sessionId = ? AND questionId = ?',
        whereArgs: <Object?>[item.sessionId, item.questionId],
      );

  Future<List<SessionQuestion>> sessionQuestions(String sessionId) async {
    final rows = await db.query('session_questions',
        where: 'sessionId = ?',
        whereArgs: <Object?>[sessionId],
        orderBy: 'orderNo ASC');
    return rows.map(SessionQuestion.fromRow).toList(growable: false);
  }

  Future<void> deleteSession(String id) async {
    await db.transaction((txn) async {
      await txn.delete('session_questions',
          where: 'sessionId = ?', whereArgs: <Object?>[id]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: <Object?>[id]);
    });
  }

  /// 删除已完成的旧会话，保留最近 [keep] 条（0 表示全删），返回删除条数。
  ///
  /// 刷题记录是唯一会无限增长的数据：每练一次就多一条会话加一份明细。
  /// 进行中的会话（active）一律保留，避免把「继续上次」清掉。
  /// 已交卷会话的条数（缓存明细展示「旧刷题记录」用）。
  Future<int> finishedSessionCount() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM sessions WHERE status = ?',
      <Object?>[SessionStatus.submitted.key],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<int> pruneFinishedSessions({int keep = 30}) async {
    final rows = await db.query(
      'sessions',
      columns: <String>['id'],
      where: 'status = ?',
      whereArgs: <Object?>[SessionStatus.submitted.key],
      orderBy: 'startedAt DESC',
    );
    if (rows.length <= keep) return 0;
    var removed = 0;
    for (final row in rows.skip(keep)) {
      final id = row['id'] as String?;
      if (id == null) continue;
      await deleteSession(id);
      removed++;
    }
    return removed;
  }

  // ---------- 搜索 ----------

  /// 题库范围：`bankIds` 优先，老的单值 [bankId] 兜底，都为空表示全部题库。
  ///
  /// 空集合与 null 等价——调用方拿「勾选了哪些题库」直接传进来即可，
  /// 一个都没勾就是不限题库。
  static Set<String>? bankScope(String? bankId, Set<String>? bankIds) {
    if (bankIds != null && bankIds.isNotEmpty) return bankIds;
    if (bankId != null && bankId.isNotEmpty) return <String>{bankId};
    return null;
  }

  /// 生成 `q.bankId IN (...)` 片段与参数（范围为空时返回 null）。
  static ({String clause, List<Object?> args})? bankScopeClause(
    Set<String>? scope,
  ) {
    if (scope == null || scope.isEmpty) return null;
    final ids = scope.toList(growable: false);
    return (
      clause: 'q.bankId IN (${List<String>.filled(ids.length, '?').join(',')})',
      args: ids,
    );
  }

  /// 跨题库搜索题干 / 选项 / 解析 / 标签（MVP 用 LIKE，后续可换 FTS5）。
  Future<SearchResult> search({
    String query = '',
    Set<QuestionType>? types,
    bool onlyWrong = false,
    bool onlyFavorite = false,
    String? bankId,
    Set<String>? bankIds,
    int limit = 20,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    final q = query.trim();
    if (q.isNotEmpty) {
      where.add('(q.stem LIKE ? OR q.optionsJson LIKE ? '
          'OR IFNULL(q.analysis, \'\') LIKE ? OR q.tagsJson LIKE ?)');
      final like = '%$q%';
      args.addAll(<Object?>[like, like, like, like]);
    }
    final scope = bankScopeClause(bankScope(bankId, bankIds));
    if (scope != null) {
      where.add(scope.clause);
      args.addAll(scope.args);
    }
    if (types != null && types.isNotEmpty) {
      where.add(
          'q.type IN (${List<String>.filled(types.length, '?').join(',')})');
      args.addAll(types.map((t) => t.key));
    }
    if (onlyWrong) {
      where.add('EXISTS (SELECT 1 FROM wrong_entries w '
          'WHERE w.questionId = q.id AND w.bankId = q.bankId)');
    }
    if (onlyFavorite) {
      where.add('EXISTS (SELECT 1 FROM favorites f '
          'WHERE f.questionId = q.id AND f.bankId = q.bankId)');
    }
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final total = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM questions q $clause', args)) ??
        0;
    final rows = await db.rawQuery(
      'SELECT q.*, b.name AS bankName FROM questions q '
      'LEFT JOIN banks b ON b.id = q.bankId '
      '$clause ORDER BY q.bankId, q.orderNo LIMIT ? OFFSET ?',
      <Object?>[...args, limit, offset],
    );
    final items = rows.map((row) {
      final map = Map<String, Object?>.of(row)..remove('bankName');
      return SearchHit(
        question: Question.fromRow(map),
        bankName: row['bankName'] as String? ?? '',
      );
    }).toList(growable: false);
    return SearchResult(items: items, total: total);
  }

  /// 关键词模式：按「词项精确等同命中」筛题，并按内部相关度排序。
  ///
  /// SQL 只做 OR 粗筛，真正的命中判定与打分在 Dart 侧完成
  /// （英文整词边界、中文子串、字段权重、覆盖率）。相关度不展示给用户。
  /// 所有过滤条件与 [search] 保持一致；关键词为空时退回普通搜索。
  Future<SearchResult> searchKeywords({
    String query = '',
    Set<QuestionType>? types,
    bool onlyWrong = false,
    bool onlyFavorite = false,
    String? bankId,
    Set<String>? bankIds,
    int limit = 20,
    int offset = 0,
  }) async {
    final keywords = splitKeywords(query);
    if (keywords.isEmpty) {
      return search(
        types: types,
        onlyWrong: onlyWrong,
        onlyFavorite: onlyFavorite,
        bankId: bankId,
        bankIds: bankIds,
        limit: limit,
        offset: offset,
      );
    }
    final tokenClauses = <String>[];
    final args = <Object?>[];
    for (final keyword in keywords) {
      tokenClauses.add(kKeywordLikeClause);
      final like = likePatternOf(keyword);
      args.addAll(<Object?>[like, like, like, like]);
    }
    // 多个词项之间是「任一命中」，所以用 OR 包成一组条件。
    final where = <String>['(${tokenClauses.join(' OR ')})'];
    final scope = bankScopeClause(bankScope(bankId, bankIds));
    if (scope != null) {
      where.add(scope.clause);
      args.addAll(scope.args);
    }
    if (types != null && types.isNotEmpty) {
      where.add(
          'q.type IN (${List<String>.filled(types.length, '?').join(',')})');
      args.addAll(types.map((t) => t.key));
    }
    if (onlyWrong) {
      where.add('EXISTS (SELECT 1 FROM wrong_entries w '
          'WHERE w.questionId = q.id AND w.bankId = q.bankId)');
    }
    if (onlyFavorite) {
      where.add('EXISTS (SELECT 1 FROM favorites f '
          'WHERE f.questionId = q.id AND f.bankId = q.bankId)');
    }
    // 词项条件排在最前，其余过滤条件追加在后；SQL 与参数顺序一致。
    final clause = 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery(
      'SELECT q.*, b.name AS bankName FROM questions q '
      'LEFT JOIN banks b ON b.id = q.bankId $clause',
      args,
    );
    final scored = <({SearchHit hit, double score})>[];
    for (final row in rows) {
      final map = Map<String, Object?>.of(row)..remove('bankName');
      final question = Question.fromRow(map);
      final score = relevanceOf(question, keywords);
      if (score <= 0) continue;
      scored.add((
        hit: SearchHit(
          question: question,
          bankName: row['bankName'] as String? ?? '',
          relevance: score,
        ),
        score: score,
      ));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byBank = a.hit.bankName.compareTo(b.hit.bankName);
      if (byBank != 0) return byBank;
      return a.hit.question.orderNo.compareTo(b.hit.question.orderNo);
    });
    final total = scored.length;
    if (offset >= total) {
      return SearchResult(items: <SearchHit>[], total: total);
    }
    final end = offset + limit > total ? total : offset + limit;
    return SearchResult(
      items:
          scored.sublist(offset, end).map((e) => e.hit).toList(growable: false),
      total: total,
    );
  }

  /// 首字母模式：题干转拼音首字母后按子串匹配（`zgdd` → 「中国的首都」）。
  ///
  /// 空格可分隔多个片段，片段都要在首字母串里命中（与便捷搜题的多词输入一致）。
  /// 拼音不在库里，所以 SQL 只做题库 / 题型 / 错题 / 收藏过滤，命中与排序在
  /// Dart 侧完成（首字母批量转换一次，见 [QuizInitials]）。排序按「各片段命中
  /// 位置之和靠前 → 题干更短」，短题干更像用户要找的那道题。
  Future<SearchResult> searchInitials({
    String query = '',
    Set<QuestionType>? types,
    bool onlyWrong = false,
    bool onlyFavorite = false,
    String? bankId,
    Set<String>? bankIds,
    int limit = 20,
    int offset = 0,
  }) async {
    final terms = QuizInitials.splitQuery(query);
    if (terms.isEmpty) {
      return const SearchResult(items: <SearchHit>[], total: 0);
    }
    final where = <String>[];
    final args = <Object?>[];
    final scope = bankScopeClause(bankScope(bankId, bankIds));
    if (scope != null) {
      where.add(scope.clause);
      args.addAll(scope.args);
    }
    if (types != null && types.isNotEmpty) {
      where.add(
          'q.type IN (${List<String>.filled(types.length, '?').join(',')})');
      args.addAll(types.map((t) => t.key));
    }
    if (onlyWrong) {
      where.add('EXISTS (SELECT 1 FROM wrong_entries w '
          'WHERE w.questionId = q.id AND w.bankId = q.bankId)');
    }
    if (onlyFavorite) {
      where.add('EXISTS (SELECT 1 FROM favorites f '
          'WHERE f.questionId = q.id AND f.bankId = q.bankId)');
    }
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await db.rawQuery(
      'SELECT q.*, b.name AS bankName FROM questions q '
      'LEFT JOIN banks b ON b.id = q.bankId $clause '
      'ORDER BY q.bankId, q.orderNo',
      args,
    );
    if (rows.isEmpty) {
      return const SearchResult(items: <SearchHit>[], total: 0);
    }
    final questions = <Question>[];
    final names = <String>[];
    for (final row in rows) {
      final map = Map<String, Object?>.of(row)..remove('bankName');
      questions.add(Question.fromRow(map));
      names.add(row['bankName'] as String? ?? '');
    }
    final initials = await QuizInitials.initialsOf(
      <String>[for (final q in questions) q.stem],
    );
    final hits = <({int index, int pos})>[];
    for (var i = 0; i < questions.length; i++) {
      final text = initials[i];
      var posSum = 0;
      var allMatched = true;
      for (final term in terms) {
        final pos = text.indexOf(term);
        if (pos < 0) {
          allMatched = false;
          break;
        }
        posSum += pos;
      }
      if (allMatched) hits.add((index: i, pos: posSum));
    }
    final total = hits.length;
    if (total == 0 || offset >= total) {
      return SearchResult(items: <SearchHit>[], total: total);
    }
    hits.sort((a, b) {
      final byPos = a.pos.compareTo(b.pos);
      if (byPos != 0) return byPos;
      final byLength = questions[a.index]
          .stem
          .length
          .compareTo(questions[b.index].stem.length);
      if (byLength != 0) return byLength;
      return a.index.compareTo(b.index);
    });
    final end = offset + limit > total ? total : offset + limit;
    return SearchResult(
      items: <SearchHit>[
        for (final hit in hits.sublist(offset, end))
          SearchHit(
            question: questions[hit.index],
            bankName: names[hit.index],
          ),
      ],
      total: total,
    );
  }

  // ---------- 搜题用的全量快照 ----------
  /// 拍照搜题：一次取出全部题目 + 题库名，在 Dart 侧做相似度打分。
  ///
  /// [limit] 防止题库特别大时把内存拉满；按题库顺序截断，仍然覆盖前面几个题库。
  Future<List<({Question question, String bankName})>> allQuestionsWithBank({
    int limit = 4000,
    String? bankId,
    Set<String>? bankIds,
  }) async {
    final scope = bankScopeClause(bankScope(bankId, bankIds));
    final rows = await db.rawQuery(
      'SELECT q.*, b.name AS bankName FROM questions q '
      'LEFT JOIN banks b ON b.id = q.bankId '
      '${scope == null ? '' : 'WHERE ${scope.clause} '}'
      'ORDER BY q.bankId, q.orderNo LIMIT ?',
      <Object?>[...?scope?.args, limit],
    );
    final out = <({Question question, String bankName})>[];
    for (final row in rows) {
      final map = Map<String, Object?>.of(row)..remove('bankName');
      out.add((
        question: Question.fromRow(map),
        bankName: row['bankName'] as String? ?? '',
      ));
    }
    return out;
  }

  /// 便捷搜题的悬浮窗索引：原生侧直接拿来渲染，所以选项与答案都预先转成展示文案。
  ///
  /// 判断题按项目口径不输出 `options`（原生补「正确 / 错误」两行），答案走
  /// [answerLabelOf] 的中文文本，避免 `true` / `false` 漏到界面上。
  Future<List<Map<String, dynamic>>> quickSearchIndex({
    int limit = 4000,
    String? bankId,
    Set<String>? bankIds,
  }) async {
    final items = await allQuestionsWithBank(
      limit: limit,
      bankId: bankId,
      bankIds: bankIds,
    );
    return items.map((e) {
      final q = e.question;
      final answers = q.answer.map((a) => a.toLowerCase()).toSet();
      return <String, dynamic>{
        'stem': q.stem,
        'type': q.type.key,
        // 悬浮窗可按题库筛选，索引里必须带上归属。
        'bankId': q.bankId,
        'options': q.type == QuestionType.trueFalse
            ? const <Map<String, dynamic>>[]
            : q.options
                .map(
                  (o) => <String, dynamic>{
                    'key': o.key,
                    'text': o.text,
                    'correct': answers.contains(o.key.toLowerCase()),
                  },
                )
                .toList(growable: false),
        'answer': q.answer,
        'answerText': answerLabelOf(q),
      };
    }).toList(growable: false);
  }

  // ---------- 笔记 ----------

  /// 某个题库的笔记（最近修改的在前）。
  Future<List<QuizNote>> listNotes(String bankId) async {
    final rows = await db.query('notes',
        where: 'bankId = ?',
        whereArgs: <Object?>[bankId],
        orderBy: 'updatedAt DESC, createdAt DESC');
    return rows.map(QuizNote.fromRow).toList(growable: false);
  }

  Future<int> countNotes(String bankId) async {
    final rows = await db.rawQuery(
        'SELECT COUNT(*) FROM notes WHERE bankId = ?', <Object?>[bankId]);
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> insertNote(QuizNote note) => db.insert('notes', note.toRow());

  Future<void> updateNote(QuizNote note) => db.update(
        'notes',
        note.toRow(),
        where: 'id = ?',
        whereArgs: <Object?>[note.id],
      );

  Future<void> deleteNote(String id) => db.delete(
        'notes',
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

  // ---------- 统计 ----------

  Future<QuizStats> stats({String? bankId}) async {
    Future<int> count(String table) async {
      final where = bankId == null ? '' : 'WHERE bankId = ?';
      final args = bankId == null ? null : <Object?>[bankId];
      final rows =
          await db.rawQuery('SELECT COUNT(*) FROM $table $where', args);
      return Sqflite.firstIntValue(rows) ?? 0;
    }

    final answeredWhere = bankId == null
        ? 'WHERE isCorrect IS NOT NULL'
        : 'WHERE isCorrect IS NOT NULL AND sessionId IN '
            '(SELECT id FROM sessions WHERE bankId = ?)';
    final answeredArgs = bankId == null ? null : <Object?>[bankId];
    final correctWhere = bankId == null
        ? 'WHERE isCorrect = 1'
        : 'WHERE isCorrect = 1 AND sessionId IN '
            '(SELECT id FROM sessions WHERE bankId = ?)';

    final banks = bankId == null ? await count('banks') : 1;
    final questions = await count('questions');
    final wrong = await count('wrong_entries');
    final favorite = await count('favorites');
    final answered = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM session_questions $answeredWhere',
            answeredArgs)) ??
        0;
    final correct = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM session_questions $correctWhere',
            answeredArgs)) ??
        0;
    // 「已刷题目」按去重后的题目数统计：同一题刷多次只算一次。
    // 会话预插入的空白作答不算，口径与 answeredQuestionIds() 一致。
    final seenSql = bankId == null
        ? 'SELECT COUNT(DISTINCT questionId) FROM session_questions '
            'WHERE ($_answeredWhere)'
        : 'SELECT COUNT(DISTINCT sq.questionId) FROM session_questions sq '
            'JOIN questions q ON q.id = sq.questionId '
            'WHERE q.bankId = ? AND ($_answeredWhere)';
    final seen =
        Sqflite.firstIntValue(await db.rawQuery(seenSql, answeredArgs)) ?? 0;
    final sessions = await count('sessions');
    return QuizStats(
      bankCount: banks,
      questionCount: questions,
      wrongCount: wrong,
      favoriteCount: favorite,
      answeredCount: answered,
      correctCount: correct,
      sessionCount: sessions,
      seenCount: seen,
    );
  }

  // ---------- 设置 ----------

  Future<String?> getSetting(String key) async {
    final rows =
        await db.query('settings', where: 'key = ?', whereArgs: <Object?>[key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) => db.insert(
        'settings',
        <String, Object?>{'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
}
