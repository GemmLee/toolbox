import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/storage/app_files.dart';
import '../../../../core/storage/store_picker.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_excel_export.dart';
import '../logic/quiz_export.dart';
import '../logic/quiz_folders.dart';
import '../logic/quiz_import.dart';
import 'bank_detail_page.dart';
import 'quiz_ai_import_page.dart';
import 'quiz_answer_page.dart';
import 'quiz_backup_page.dart';
import 'quiz_common.dart';
import 'quiz_excel_import_page.dart';
import 'quiz_import_page.dart';
import 'quiz_remote_page.dart';
import 'quiz_search_page.dart';

/// 导入题库：手机文件 / 存储空间。
Future<bool> pickAndImportQuiz(
    BuildContext context, QuizRepository repo) async {
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(tr('导入题库'),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                InfoHint(
                  text: '${tr('支持 .json 题库文件与 .xlsx 表格（每行一题）')}\n'
                      '${tr('也可把 Word / 文本交给内置「题库转换」技能转成题库')}',
                ),
              ],
            ),
          ),
          ListTile(
            key: const ValueKey('quiz-import-json'),
            leading: const Icon(Icons.smartphone_outlined),
            title: Text(tr('从手机选择文件')),
            subtitle: Text(tr('支持 .json / .xlsx')),
            onTap: () => Navigator.of(context).pop('phone'),
          ),
          ListTile(
            key: const ValueKey('quiz-import-store'),
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(tr('从存储空间选择')),
            subtitle: Text(tr('支持 .json / .xlsx')),
            onTap: () => Navigator.of(context).pop('store'),
          ),
          ListTile(
            key: const ValueKey('quiz-import-remote'),
            leading: const Icon(Icons.cloud_download_outlined),
            title: Text(tr('在线题库下载')),
            subtitle: Text(tr('从资源站选择并下载题库')),
            onTap: () => Navigator.of(context).pop('remote'),
          ),
          ListTile(
            key: const ValueKey('quiz-import-ai'),
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(tr('AI 导入')),
            onTap: () => Navigator.of(context).pop('ai'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return false;

  // 在线题库：拉取索引 → 选文件下载 → 预览入库。
  if (source == 'remote') {
    final ok = await Navigator.of(context).push<bool>(
      quizRoute<bool>(
        builder: (_) => QuizRemotePage(repo: repo),
      ),
    );
    return ok == true;
  }

  // AI 导入：转换 → 确认 → 直接入库，不再走本地 JSON 解析分支。
  if (source == 'ai') {
    final ok = await Navigator.of(context).push<bool>(
      quizRoute<bool>(
        builder: (_) => QuizAiImportPage(repo: repo),
      ),
    );
    return ok == true;
  }

  const allowed = <String>['json', 'xlsx'];
  String fileName;
  List<int> bytes;
  if (source == 'store') {
    final file =
        await pickStoredFile(context, extensions: allowed, title: tr('选择题库文件'));
    if (file == null || !context.mounted) return false;
    fileName = file.name;
    try {
      bytes = await file.file.readAsBytes();
    } catch (e) {
      if (context.mounted) {
        showToast(context, trf('文件读取失败：{e}', {'e': '$e'}));
      }
      return false;
    }
  } else {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowed,
      withData: true,
    );
    final picked = result?.files.single;
    if (picked == null) return false;
    fileName = picked.name;
    try {
      bytes = picked.bytes ??
          await File.fromUri(Uri.file(picked.path!)).readAsBytes();
    } catch (e) {
      if (context.mounted) {
        showToast(context, trf('文件读取失败：{e}', {'e': '$e'}));
      }
      return false;
    }
  }
  if (!context.mounted) return false;

  // 按扩展名分流：xlsx 走本地转换 → 结果卡 → 预览入库；json 直接解析预览。
  final bool ok;
  if (fileName.toLowerCase().endsWith('.xlsx')) {
    ok = await Navigator.of(context).push<bool>(
          quizRoute<bool>(
            builder: (_) => QuizExcelImportPage(
              repo: repo,
              initialFile: (name: fileName, bytes: bytes),
            ),
          ),
        ) ==
        true;
  } else {
    ok = await _importJson(context, repo, bytes);
  }
  if (!ok || !context.mounted) return false;

  // 从手机选的文件顺手归档到存储空间，方便以后复用。
  if (source == 'phone') {
    try {
      await AppStore.saveBytes(
        category: AppStoreCategory.quiz,
        name: fileName,
        bytes: bytes,
      );
    } catch (_) {
      // 归档失败不影响导入结果
    }
  }
  return true;
}

/// JSON 题库：解析 → 预览 → 确认入库。
Future<bool> _importJson(
    BuildContext context, QuizRepository repo, List<int> bytes) async {
  ImportPreview preview;
  try {
    preview = QuizImporter.parse(utf8.decode(bytes));
  } on ImportError catch (e) {
    showToast(context, '${tr('导入失败')}：$e');
    return false;
  }
  if (!context.mounted) return false;
  final ok = await Navigator.of(context).push<bool>(
    quizRoute<bool>(
        builder: (_) => QuizImportPage(repo: repo, preview: preview)),
  );
  if (ok != true || !context.mounted) return false;
  if (context.mounted) showToast(context, tr('导入成功'));
  return true;
}

/// 刷题助手首页：以题库为主要类目，错题 / 收藏 / 记录都归属各自的题库。
class QuizPage extends StatelessWidget {
  const QuizPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<QuizRepository>(
      future: QuizServices.repo(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        final repo = snapshot.data;
        if (repo == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return _QuizHome(repo: repo);
      },
    );
  }
}

class _QuizHome extends StatefulWidget {
  const _QuizHome({required this.repo});

  final QuizRepository repo;

  @override
  State<_QuizHome> createState() => _QuizHomeState();
}

class _QuizHomeState extends State<_QuizHome> {
  late Future<_HomeData> _future;

  /// 长按题库卡进入多选：集合非空即处于选中模式。
  final Set<String> _selected = <String>{};

  bool get _selecting => _selected.isNotEmpty;

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _exitSelection() => setState(_selected.clear);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = _HomeData.load(widget.repo);
  }

  Future<void> _refresh() async {
    setState(_load);
    await _future;
  }

  Future<void> _import() async {
    final ok = await pickAndImportQuiz(context, widget.repo);
    if (ok && mounted) await _refresh();
  }

  Future<void> _openBank(Bank bank) async {
    await Navigator.of(context).push(quizRoute<void>(
        builder: (_) => BankDetailPage(repo: widget.repo, bank: bank)));
    if (mounted) await _refresh();
  }

  Future<QuizFoldersData> _folders() async => (await _future).folders;

  Future<void> _saveFolders(QuizFoldersData data) async {
    await QuizFoldersData.save(widget.repo, data);
    await _refresh();
  }

  /// 弹一个输入框，返回非空名称（新建 / 重命名文件夹共用）。
  Future<String?> _askFolderName(
      {String? initial, required String title}) async {
    if (!mounted) return null;
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          _FolderNameDialog(title: tr(title), initial: initial),
    );
    return (name ?? '').isEmpty ? null : name;
  }

  Future<void> _createFolder() async {
    final name = await _askFolderName(title: '新建文件夹');
    if (name == null) return;
    final data = await _folders();
    await _saveFolders(data.copyWith(folders: <QuizFolder>[
      ...data.folders,
      QuizFolder(id: newId(), name: name),
    ]));
  }

  Future<void> _renameFolder(QuizFolder folder) async {
    final name = await _askFolderName(title: '重命名文件夹', initial: folder.name);
    if (name == null || name == folder.name) return;
    final data = await _folders();
    await _saveFolders(data.copyWith(
        folders: data.folders
            .map((f) => f.id == folder.id ? f.copyWith(name: name) : f)
            .toList()));
  }

  Future<void> _deleteFolder(QuizFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除文件夹')),
        content: Text(trf('删除「{n}」？题库会移到「未分类」，不会被删除。', {
          'n': folder.name,
        })),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final data = await _folders();
    final assign = Map<String, String>.from(data.assign)
      ..removeWhere((_, value) => value == folder.id);
    await _saveFolders(data.copyWith(
      folders: data.folders.where((f) => f.id != folder.id).toList(),
      assign: assign,
    ));
  }

  Future<void> _toggleFolder(QuizFolder folder) async {
    final data = await _folders();
    await _saveFolders(data.copyWith(
        folders: data.folders
            .map((f) =>
                f.id == folder.id ? f.copyWith(expanded: !f.expanded) : f)
            .toList()));
  }

  Future<void> _toggleUncategorized() async {
    final data = await _folders();
    await _saveFolders(
        data.copyWith(uncategorizedExpanded: !data.uncategorizedExpanded));
  }

  /// 把题库移入某个文件夹（folderId 为 null 表示移回未分类）。
  Future<void> _moveBank(Bank bank, String? folderId) async {
    final data = await _folders();
    if ((data.assign[bank.id] ?? '') == (folderId ?? '')) return;
    final assign = Map<String, String>.from(data.assign);
    if (folderId == null) {
      assign.remove(bank.id);
    } else {
      assign[bank.id] = folderId;
    }
    await _saveFolders(data.copyWith(assign: assign));
  }

  Future<void> _pickFolderForBank(Bank bank) async {
    final data = await _folders();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: Text(tr('未分类')),
              trailing: data.assign[bank.id] == null
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () => Navigator.of(context).pop(''),
            ),
            for (final folder in data.folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                trailing: data.assign[bank.id] == folder.id
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => Navigator.of(context).pop(folder.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _moveBank(bank, picked.isEmpty ? null : picked);
  }

  Widget _bankTile(Bank bank) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _BankCard(
          bank: bank,
          selected: _selected.contains(bank.id),
          selecting: _selecting,
          onOpen: () {
            if (_selecting) {
              _toggleSelected(bank.id);
            } else {
              _openBank(bank);
            }
          },
          onLongPress: () => _toggleSelected(bank.id),
          onExport: () => _exportBank(bank),
          onExportExcel: () => _exportBankExcel(bank),
          onRename: () => _rename(bank),
          onDelete: () => _confirmDelete(bank),
          onMoveToFolder: () => _pickFolderForBank(bank),
        ),
      );

  Future<void> _confirmDelete(Bank bank) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除题库')),
        content: Text('${trf('确认删除「{n}」？', {
              'n': bank.name
            })}\n${tr('删除后该题库的错题、收藏与考试记录都会一并删除')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.repo.deleteBank(bank.id);
    if (mounted) showToast(context, tr('已删除'));
    await _refresh();
  }

  Future<void> _rename(Bank bank) async {
    final input = TextEditingController(text: bank.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('重命名题库')),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('题库名称'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input.text),
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
    input.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == bank.name) return;
    await widget.repo.renameBank(bank.id, trimmed);
    await _refresh();
  }

  /// 把该题库导出成 JSON，存到「存储空间 › 存储文件」。
  Future<void> _exportBank(Bank bank) async {
    try {
      // questionsOfBank 默认 limit=50 是给详情页分页用的；导出必须全量。
      final questions =
          await widget.repo.questionsOfBank(bank.id, limit: 100000);
      if (questions.isEmpty) {
        if (mounted) showToast(context, tr('该题库还没有题目'));
        return;
      }
      final file = await AppStore.saveText(
        category: AppStoreCategory.quiz,
        name: QuizExporter.fileNameOf(bank, DateTime.now()),
        content: QuizExporter.encode(bank, questions),
      );
      if (!mounted) return;
      showToast(context, trf('题库已导出到存储空间：{n}', {'n': file.name}));
    } catch (e) {
      if (mounted) showToast(context, '${tr('导出失败')}：$e');
    }
  }

  /// 把该题库导出成 Excel（xlsx），按 JSON 规范转成表格，存到「存储空间 › 存储文件」。
  Future<void> _exportBankExcel(Bank bank) async {
    try {
      final questions =
          await widget.repo.questionsOfBank(bank.id, limit: 100000);
      if (questions.isEmpty) {
        if (mounted) showToast(context, tr('该题库还没有题目'));
        return;
      }
      final file = await AppStore.saveBytes(
        category: AppStoreCategory.quiz,
        name: QuizExcelExporter.fileNameOf(bank, DateTime.now()),
        bytes: QuizExcelExporter.build(bank, questions),
      );
      if (!mounted) return;
      showToast(context, trf('题库已导出到存储空间：{n}', {'n': file.name}));
    } catch (e) {
      if (mounted) showToast(context, '${tr('导出失败')}：$e');
    }
  }

  /// 多选：把选中题库的题目合并进「保留题库」，其余题库删除。
  Future<void> _mergeSelected(List<Bank> banks) async {
    if (_selected.length < 2) return;
    final ordered = banks.where((b) => _selected.contains(b.id)).toList();
    final target = await showModalBottomSheet<Bank>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr('选择保留的题库'),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final bank in ordered)
              ListTile(
                key: ValueKey('quiz-merge-target-${bank.id}'),
                title: Text(bank.name),
                subtitle: Text(trf('共 {n} 题', {'n': bank.questionCount})),
                onTap: () => Navigator.of(sheetContext).pop(bank),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    try {
      final moved = await widget.repo.mergeBanks(
        target.id,
        ordered.map((b) => b.id).toList(),
      );
      if (!mounted) return;
      _exitSelection();
      showToast(context, trf('已合并，新增 {n} 题', {'n': moved}));
      await _refresh();
    } catch (e) {
      if (mounted) showToast(context, '${tr('合并失败')}：$e');
    }
  }

  /// 多选：每个选中题库各自导出一个文件，避免混在一起难以使用。
  Future<void> _exportSelected(List<Bank> banks) async {
    final chosen = banks.where((b) => _selected.contains(b.id)).toList();
    if (chosen.isEmpty) return;
    var exported = 0;
    try {
      for (final bank in chosen) {
        // questionsOfBank 默认 limit=50 是详情页分页口径；导出必须全量。
        final questions =
            await widget.repo.questionsOfBank(bank.id, limit: 100000);
        if (questions.isEmpty) continue;
        await AppStore.saveText(
          category: AppStoreCategory.quiz,
          name: QuizExporter.fileNameOf(bank, DateTime.now()),
          content: QuizExporter.encode(bank, questions),
        );
        exported++;
      }
      if (!mounted) return;
      _exitSelection();
      showToast(context, trf('已导出 {n} 个题库文件', {'n': exported}));
    } catch (e) {
      if (mounted) showToast(context, '${tr('导出失败')}：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selecting ? trf('已选 {n}', {'n': _selected.length}) : tr('刷题助手'),
        ),
        leading: _selecting
            ? IconButton(
                key: const ValueKey('quiz-selection-exit'),
                tooltip: tr('取消'),
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        actions: <Widget>[
          if (!_selecting) ...<Widget>[
            IconButton(
              key: const ValueKey('quiz-search'),
              tooltip: tr('全局搜索'),
              icon: const Icon(Icons.search),
              onPressed: () async {
                await Navigator.of(context).push(quizRoute<void>(
                    builder: (_) => QuizSearchPage(repo: widget.repo)));
                if (mounted) await _refresh();
              },
            ),
            IconButton(
              tooltip: tr('设置'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: () async {
                await Navigator.of(context).push(quizRoute<void>(
                    builder: (_) => QuizBackupPage(repo: widget.repo)));
                if (mounted) await _refresh();
              },
            ),
          ],
        ],
      ),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<_HomeData>(
                future: _future,
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  if (data == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (data.banks.isEmpty) {
                    return EmptyState(
                      icon: Icons.library_books_outlined,
                      text: tr('还没有题库，点下方按钮导入 JSON 题库'),
                      action: FilledButton.icon(
                        onPressed: _import,
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(tr('导入题库')),
                      ),
                    );
                  }
                  return ListView(
                    padding:
                        EdgeInsets.fromLTRB(16, 8, 16, _selecting ? 84 : 24),
                    children: <Widget>[
                      if (data.active != null && !_selecting) ...<Widget>[
                        _ResumeCard(
                          session: data.active!,
                          bankName: data.bankNameOf(data.active!.bankId),
                          repo: widget.repo,
                          onReturn: _refresh,
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: <Widget>[
                          Text(
                            tr('题库'),
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${data.banks.length}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                          const Spacer(),
                          if (!_selecting) ...<Widget>[
                            IconButton(
                              key: const ValueKey('quiz-folder-create'),
                              tooltip: tr('新建文件夹'),
                              icon: const Icon(Icons.create_new_folder_outlined,
                                  size: 20),
                              onPressed: _createFolder,
                            ),
                            TextButton.icon(
                              onPressed: _import,
                              icon: const Icon(Icons.add, size: 18),
                              label: Text(tr('导入')),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      for (final folder in data.folders.folders) ...<Widget>[
                        _FolderHeader(
                          key: ValueKey('quiz-folder-${folder.id}'),
                          folder: folder,
                          count: data.folders
                              .banksOf(folder.id, data.banks)
                              .length,
                          selecting: _selecting,
                          onToggle: () => _toggleFolder(folder),
                          onRename: () => _renameFolder(folder),
                          onDelete: () => _deleteFolder(folder),
                        ),
                        if (folder.expanded)
                          for (final bank
                              in data.folders.banksOf(folder.id, data.banks))
                            _bankTile(bank),
                      ],
                      // 未分类：既有无文件夹的题库，或文件夹全被删掉时的兜底。
                      if (data.folders
                          .banksOf(null, data.banks)
                          .isNotEmpty) ...<Widget>[
                        _FolderHeader(
                          key: const ValueKey('quiz-folder-uncategorized'),
                          folder: QuizFolder(
                              id: '',
                              name: tr('未分类'),
                              expanded: data.folders.uncategorizedExpanded),
                          count: data.folders.banksOf(null, data.banks).length,
                          selecting: _selecting,
                          onToggle: _toggleUncategorized,
                        ),
                        if (data.folders.uncategorizedExpanded)
                          for (final bank
                              in data.folders.banksOf(null, data.banks))
                            _bankTile(bank),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
          if (_selecting)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _SelectionBar(
                count: _selected.length,
                canMerge: _selected.length >= 2,
                onMerge: () async {
                  final data = await _future;
                  if (mounted) await _mergeSelected(data.banks);
                },
                onExport: () async {
                  final data = await _future;
                  if (mounted) await _exportSelected(data.banks);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _HomeData {
  _HomeData({
    required this.banks,
    required this.folders,
    this.active,
  });

  final List<Bank> banks;
  final QuizFoldersData folders;
  final QuizSession? active;

  String bankNameOf(String? bankId) {
    if (bankId == null) return '';
    for (final bank in banks) {
      if (bank.id == bankId) return bank.name;
    }
    return '';
  }

  static Future<_HomeData> load(QuizRepository repo) async {
    final results = await Future.wait(<Future<Object>>[
      repo.listBanks(),
      QuizFoldersData.load(repo),
      repo.sessions(status: SessionStatus.active, limit: 1),
    ]);
    final active = results[2] as List<QuizSession>;
    return _HomeData(
      banks: results[0] as List<Bank>,
      folders: results[1] as QuizFoldersData,
      active: active.isEmpty ? null : active.first,
    );
  }
}

/// 文件夹名称输入框：controller 由独立 State 持有，避免 await 后立刻 dispose。
class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({required this.title, this.initial});

  final String title;
  final String? initial;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: 1,
          decoration: InputDecoration(
            labelText: tr('文件夹名称'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
            child: Text(tr('保存')),
          ),
        ],
      );
}

/// 文件夹分组头：点标题折叠/展开，未分类不显示重命名与删除。
class _FolderHeader extends StatelessWidget {
  const _FolderHeader({
    super.key,
    required this.folder,
    required this.count,
    required this.selecting,
    required this.onToggle,
    this.onRename,
    this.onDelete,
  });

  final QuizFolder folder;
  final int count;
  final bool selecting;
  final VoidCallback onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final named = folder.id.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 0, 4),
      child: Row(
        children: <Widget>[
          InkWell(
            key: ValueKey('quiz-folder-toggle-${folder.id}'),
            onTap: selecting ? null : onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    folder.expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                      named ? Icons.folder_outlined : Icons.folder_off_outlined,
                      size: 18,
                      color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(folder.name,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Text('$count',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.outline)),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (named && !selecting)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 18),
              tooltip: tr('更多'),
              onSelected: (value) {
                if (value == 'rename') onRename?.call();
                if (value == 'delete') onDelete?.call();
              },
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  key: ValueKey('quiz-folder-rename-${folder.id}'),
                  value: 'rename',
                  child: Text(tr('重命名文件夹')),
                ),
                PopupMenuItem<String>(
                  key: ValueKey('quiz-folder-delete-${folder.id}'),
                  value: 'delete',
                  child: Text(tr('删除文件夹')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 题库卡片：题目数 / 错题 / 收藏一眼可见，点进详情再分「题目、错题、收藏、记录」。
class _BankCard extends StatelessWidget {
  const _BankCard({
    required this.bank,
    required this.onOpen,
    required this.onExport,
    required this.onExportExcel,
    required this.onRename,
    required this.onDelete,
    required this.onMoveToFolder,
    this.selected = false,
    this.selecting = false,
    this.onLongPress,
  });

  final Bank bank;
  final VoidCallback onOpen;
  final VoidCallback onExport;
  final VoidCallback onExportExcel;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onMoveToFolder;
  final bool selected;
  final bool selecting;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: selected ? scheme.primaryContainer : null,
      child: InkWell(
        key: ValueKey('quiz-bank-card-${bank.id}'),
        onTap: onOpen,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 12, 8, 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: selecting
                    ? Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 22,
                        color: scheme.primary,
                      )
                    : Icon(Icons.library_books_outlined,
                        size: 22, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bank.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      trf('共 {n} 题 · 错题 {w} · 收藏 {f}', {
                        'n': bank.questionCount,
                        'w': bank.wrongCount,
                        'f': bank.favoriteCount,
                      }),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (!selecting)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: tr('更多'),
                  onSelected: (value) {
                    if (value == 'export') onExport();
                    if (value == 'export-excel') onExportExcel();
                    if (value == 'rename') onRename();
                    if (value == 'delete') onDelete();
                    if (value == 'folder') onMoveToFolder();
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      key: const ValueKey('bank-move-folder'),
                      value: 'folder',
                      child: Text(tr('移到文件夹')),
                    ),
                    PopupMenuItem<String>(
                      key: const ValueKey('bank-export'),
                      value: 'export',
                      child: Text(tr('导出题库')),
                    ),
                    PopupMenuItem<String>(
                      key: const ValueKey('bank-export-excel'),
                      value: 'export-excel',
                      child: Text(tr('导出 Excel')),
                    ),
                    PopupMenuItem<String>(
                      value: 'rename',
                      child: Text(tr('重命名题库')),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text(tr('删除题库')),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多选模式底部操作栏：合并 / 分文件导出 / 全选入口由上方标题显示数量。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.canMerge,
    required this.onMerge,
    required this.onExport,
  });

  final int count;
  final bool canMerge;
  final VoidCallback onMerge;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withOpacity(0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Text(
            trf('已选 {n}', {'n': count}),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const Spacer(),
          OutlinedButton.icon(
            key: const ValueKey('quiz-selection-merge'),
            onPressed: canMerge ? onMerge : null,
            icon: const Icon(Icons.merge_type, size: 18),
            label: Text(tr('合并')),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const ValueKey('quiz-selection-export'),
            onPressed: onExport,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: Text(tr('分文件导出')),
          ),
        ],
      ),
    );
  }
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({
    required this.session,
    required this.bankName,
    required this.repo,
    required this.onReturn,
  });

  final QuizSession session;
  final String bankName;
  final QuizRepository repo;
  final Future<void> Function() onReturn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (session.mode) {
      QuizMode.exam => tr('模拟考试'),
      QuizMode.wrong => tr('错题练习'),
      QuizMode.favorite => tr('收藏练习'),
      QuizMode.random => tr('随机练习'),
      QuizMode.all => tr('顺序练习'),
    };
    // 主题色卡片在深色主题下偏深，前景色按背景亮度取，避免文字看不清。
    final onCard = AppTheme.readableOn(theme.colorScheme.primaryContainer);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: ListTile(
        leading: Icon(Icons.play_circle_outline, color: onCard),
        title: Text(
          trf('继续上次：{m}', {'m': label}),
          style: theme.textTheme.bodyLarge?.copyWith(color: onCard),
        ),
        subtitle: Text(
          [if (bankName.isNotEmpty) bankName, clockText(session.elapsedMs)]
              .join(' · '),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: onCard.withOpacity(0.78),
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: onCard),
        onTap: () async {
          await Navigator.of(context).push(quizRoute<void>(
              builder: (_) => QuizAnswerPage(
                    repo: repo,
                    sessionId: session.id,
                  )));
          await onReturn();
        },
      ),
    );
  }
}
