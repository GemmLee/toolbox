import 'package:sqflite/sqflite.dart';

/// 数据库当前 schema 版本。
///
/// v2：sessions 增加 lastIndex，用于断点续答回到上次题目。
/// v3：增加 notes 表，笔记按题库隔离。
/// v4：sessions 增加 activeAt（最近一次动过的时刻），首页「继续上次」按它排序。
/// v5：增加 study_history 表，按题库累计记录背过的题目（去重）。
const int quizSchemaVersion = 5;

/// 建表语句（父表在前）。
const List<String> quizCreateTables = <String>[
  // 题库
  '''
  CREATE TABLE banks (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    importId TEXT,
    description TEXT,
    createdAt INTEGER NOT NULL
  )
  ''',
  // 题目
  '''
  CREATE TABLE questions (
    id TEXT PRIMARY KEY,
    bankId TEXT NOT NULL,
    importId TEXT,
    type TEXT NOT NULL,
    stem TEXT NOT NULL,
    optionsJson TEXT NOT NULL,
    answerJson TEXT NOT NULL,
    analysis TEXT,
    tagsJson TEXT NOT NULL,
    difficulty INTEGER,
    score REAL,
    contentHash TEXT NOT NULL,
    orderNo INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX idx_questions_bank ON questions(bankId)',
  'CREATE UNIQUE INDEX idx_questions_bank_import ON questions(bankId, importId)',
  // 会话
  '''
  CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    bankId TEXT,
    mode TEXT NOT NULL,
    configJson TEXT NOT NULL,
    status TEXT NOT NULL,
    startedAt INTEGER NOT NULL,
    elapsedMs INTEGER NOT NULL DEFAULT 0,
    durationSec INTEGER,
    scoreEnabled INTEGER NOT NULL DEFAULT 0,
    totalScore REAL NOT NULL DEFAULT 0,
    maxScore REAL NOT NULL DEFAULT 0,
    finishedAt INTEGER
  )
  ''',
  'CREATE INDEX idx_sessions_status ON sessions(status)',
  // 会话题目与作答
  '''
  CREATE TABLE session_questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sessionId TEXT NOT NULL,
    questionId TEXT NOT NULL,
    orderNo INTEGER NOT NULL,
    userAnswerJson TEXT,
    isCorrect INTEGER,
    selfJudged INTEGER NOT NULL DEFAULT 0,
    optionOrderJson TEXT,
    answeredAt INTEGER
  )
  ''',
  'CREATE UNIQUE INDEX idx_sq_session_question ON session_questions(sessionId, questionId)',
  'CREATE INDEX idx_sq_session ON session_questions(sessionId)',
  // 错题：仅 (bankId, questionId)，不记录次数与时间
  '''
  CREATE TABLE wrong_entries (
    bankId TEXT NOT NULL,
    questionId TEXT NOT NULL,
    PRIMARY KEY (bankId, questionId)
  )
  ''',
  'CREATE INDEX idx_wrong_question ON wrong_entries(questionId)',
  // 收藏
  '''
  CREATE TABLE favorites (
    bankId TEXT NOT NULL,
    questionId TEXT NOT NULL,
    PRIMARY KEY (bankId, questionId)
  )
  ''',
  'CREATE INDEX idx_fav_question ON favorites(questionId)',
  // 键值设置
  '''
  CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )
  ''',
];

/// 迁移脚本：从 [from] 逐级升到 [to]。
///
/// 第一版只有 v1 的建表；后续版本在此追加 `if (from < N) {...}` 步骤，
/// 每步结束后 `from = N`。
Future<void> migrateQuiz(Database db, int from, int to) async {
  if (from < 1) {
    await createQuizSchema(db);
    from = 1;
  }
  // v2：记录上次刷到第几题（0 基），旧会话默认回到第 1 题。
  if (from < 2 && to >= 2) {
    await db.execute(
        'ALTER TABLE sessions ADD COLUMN lastIndex INTEGER NOT NULL DEFAULT 0');
    from = 2;
  }
  // v3：题库笔记。IF NOT EXISTS 让 onCreate（0→3）与旧库升级走同一段代码。
  if (from < 3 && to >= 3) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        bankId TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_notes_bank ON notes(bankId)');
    from = 3;
  }
  // v4：记录「最近一次动过」的时刻，旧会话退回创建时间，避免首页排序突变。
  if (from < 4 && to >= 4) {
    await db.execute(
        'ALTER TABLE sessions ADD COLUMN activeAt INTEGER NOT NULL DEFAULT 0');
    await db
        .execute('UPDATE sessions SET activeAt = startedAt WHERE activeAt = 0');
    // 旧编辑页会把判断题的 options 清空，这里一次性补回「正确 / 错误」两项，
    // 让导出 / 备份也带上选项（运行期读库另有兜底）。
    await db.execute('UPDATE questions SET optionsJson = '
        '\'[{"key":"true","text":"正确"},{"key":"false","text":"错误"}]\' '
        "WHERE type = 'true_false' "
        "AND (optionsJson IS NULL OR optionsJson IN ('', '[]'))");
    from = 4;
  }
  // v5：背题记录表。IF NOT EXISTS 让新建库与旧库升级共用同一段代码。
  if (from < 5 && to >= 5) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS study_history (
        bankId TEXT NOT NULL,
        questionId TEXT NOT NULL,
        studiedAt INTEGER NOT NULL,
        PRIMARY KEY (bankId, questionId)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_study_question ON study_history(questionId)');
    from = 5;
  }
  if (from != to) {
    throw StateError('无法把数据库从 $from 迁移到 $to');
  }
}

/// 建表（v1）。
Future<void> createQuizSchema(Database db) async {
  for (final sql in quizCreateTables) {
    await db.execute(sql);
  }
}
