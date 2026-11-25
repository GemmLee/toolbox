import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import 'quiz_common.dart';

/// 题库笔记：一条一条记录，按题库隔离，删除题库时一并删除。
class QuizNotesPage extends StatefulWidget {
  const QuizNotesPage({
    super.key,
    required this.repo,
    required this.bankId,
  });

  final QuizRepository repo;
  final String bankId;

  @override
  State<QuizNotesPage> createState() => _QuizNotesPageState();
}

class _QuizNotesPageState extends State<QuizNotesPage> {
  late Future<List<QuizNote>> _future = _load();

  Future<List<QuizNote>> _load() => widget.repo.listNotes(widget.bankId);

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
    await _future;
  }

  /// 新增 / 编辑都走同一个输入框；空白内容直接忽略。
  Future<void> _edit([QuizNote? note]) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _NoteEditorDialog(
        title: note == null ? tr('新增笔记') : tr('编辑笔记'),
        initial: note?.content ?? '',
      ),
    );
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (note == null) {
      await widget.repo.insertNote(QuizNote(
        id: newId(),
        bankId: widget.bankId,
        content: trimmed,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await widget.repo
          .updateNote(note.copyWith(content: trimmed, updatedAt: now));
    }
    if (mounted) await _refresh();
  }

  Future<void> _confirmDelete(QuizNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('删除笔记')),
        content: Text(tr('确定删除这条笔记吗？删除后不可恢复')),
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
    await widget.repo.deleteNote(note.id);
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('笔记'))),
      body: FutureBuilder<List<QuizNote>>(
        future: _future,
        builder: (context, snapshot) {
          final items = snapshot.data;
          if (items == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return QuizEmpty(
              tr('还没有笔记，点右下角按钮记一条'),
              icon: Icons.sticky_note_2_outlined,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final note = items[index];
              return Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  key: ValueKey<String>('note-${note.id}'),
                  title: Text(
                    note.content,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      dateLabelOf(note.updatedAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  trailing: IconButton(
                    key: ValueKey<String>('note-delete-${note.id}'),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: tr('删除笔记'),
                    onPressed: () => _confirmDelete(note),
                  ),
                  onTap: () => _edit(note),
                  onLongPress: () => _confirmDelete(note),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('note-add'),
        onPressed: () => _edit(),
        tooltip: tr('新增笔记'),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 笔记输入弹窗：controller 的生命周期绑在弹窗自身，
/// 避免退出动画还没播完就在外层 dispose，导致 TextField 继续使用它。
class _NoteEditorDialog extends StatefulWidget {
  const _NoteEditorDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends State<_NoteEditorDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _input,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: tr('记点什么…'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            key: const ValueKey('note-save'),
            onPressed: () => Navigator.of(context).pop(_input.text),
            child: Text(tr('保存')),
          ),
        ],
      );
}
