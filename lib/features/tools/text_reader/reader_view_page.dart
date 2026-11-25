import 'package:flutter/material.dart';

import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import 'document_view.dart';

/// 单个文档的阅读 / 简单编辑页。
///
/// md 默认渲染、可切源码；json 默认格式化着色、可切原文；txt 直接阅读。
/// 编辑保存会覆盖应用存储空间里的原文件，「用户 → 存储空间」同步可见。
class ReaderViewPage extends StatefulWidget {
  const ReaderViewPage({
    super.key,
    required this.file,
    this.contentLoader,
    this.contentSaver,
  });

  final StoredFile file;

  /// 测试注入：替换文件内容来源。
  final Future<String> Function(StoredFile file)? contentLoader;

  /// 测试注入：替换保存实现，避免 widget 测试里跑真实文件 I/O。
  final Future<void> Function(String content)? contentSaver;

  @override
  State<ReaderViewPage> createState() => _ReaderViewPageState();
}

class _ReaderViewPageState extends State<ReaderViewPage> {
  final TextEditingController _controller = TextEditingController();
  String? _content;
  String? _error;
  bool _editing = false;
  bool _dirty = false;
  bool _showSource = false;
  bool _truncated = false;

  String get _ext => widget.file.extension.toLowerCase();

  bool get _hasAlternateView =>
      _ext == 'md' ||
      _ext == 'markdown' ||
      _ext == 'json' ||
      _ext == 'html' ||
      _ext == 'htm';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = widget.contentLoader != null
          ? await widget.contentLoader!(widget.file)
          : await AppStore.readText(
              widget.file,
              maxBytes: kMaxDocumentBytes,
            );
      if (!mounted) return;
      setState(() {
        _content = text;
        _truncated = widget.file.size > kMaxDocumentBytes;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _startEdit() {
    _controller.text = _content ?? '';
    setState(() {
      _editing = true;
      _dirty = false;
    });
  }

  void _exitEdit() {
    setState(() {
      _editing = false;
      _dirty = false;
      _controller.text = _content ?? '';
    });
  }

  Future<void> _save() async {
    try {
      final text = _controller.text;
      if (widget.contentSaver != null) {
        await widget.contentSaver!(text);
      } else {
        // 直接写回原文件：阅读器可以打开存储空间里任意分类的文档，
        // 按分类重新保存会另存一份，原文件反而不变。
        await widget.file.file.writeAsString(text, flush: true);
      }
      if (!mounted) return;
      setState(() {
        _content = text;
        _editing = false;
        _dirty = false;
      });
      showToast(context, tr('已保存'));
    } catch (e) {
      if (mounted) showToast(context, trf('保存失败：{e}', {'e': '$e'}));
    }
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('放弃未保存的修改？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('放弃')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _cancelEdit() async {
    if (_dirty && !await _confirmDiscard()) return;
    if (mounted) _exitEdit();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await _confirmDiscard();
        if (!discard || !mounted) return;
        _exitEdit();
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.file.name, overflow: TextOverflow.ellipsis),
          actions: _editing
              ? <Widget>[
                  TextButton(
                    key: const ValueKey('reader-cancel'),
                    onPressed: _cancelEdit,
                    child: Text(tr('取消')),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton(
                      key: const ValueKey('reader-save'),
                      onPressed: _save,
                      child: Text(tr('保存')),
                    ),
                  ),
                ]
              : <Widget>[
                  IconButton(
                    key: const ValueKey('reader-copy'),
                    tooltip: tr('复制'),
                    icon: const Icon(Icons.copy_all_outlined),
                    onPressed: () => copyWithToast(context, _content ?? ''),
                  ),
                  if (_hasAlternateView)
                    IconButton(
                      key: const ValueKey('reader-mode'),
                      tooltip: _showSource ? tr('渲染') : tr('源码'),
                      icon: Icon(
                          _showSource ? Icons.article_outlined : Icons.code),
                      onPressed: () =>
                          setState(() => _showSource = !_showSource),
                    ),
                  IconButton(
                    key: const ValueKey('reader-edit'),
                    tooltip: tr('编辑'),
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _startEdit,
                  ),
                ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    final error = _error;
    if (error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        text: trf('读取失败：{e}', {'e': error}),
      );
    }
    final content = _content;
    if (content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_editing) {
      final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.45,
              ) ??
          const TextStyle(fontFamily: 'monospace');
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          key: const ValueKey('reader-editor'),
          controller: _controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: style,
          onChanged: (_) {
            if (!_dirty) setState(() => _dirty = true);
          },
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.all(12),
          ),
        ),
      );
    }
    // 正文自身就是滚动区域（长文档分块懒加载），这里不再套 ScrollView。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SmallHint(
              text: trf('文件超过 {n} MB，仅显示前一部分', {
                'n': kMaxDocumentBytes ~/ (1024 * 1024),
              }),
            ),
          ),
        Expanded(
          child: DocumentBody(
            content: content,
            extension: _ext,
            showSource: _showSource,
          ),
        ),
      ],
    );
  }
}
