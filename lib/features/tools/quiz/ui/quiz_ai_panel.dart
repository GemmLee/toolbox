import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/ai_status_indicator.dart';
import '../../assistant/data/assistant_api.dart';
import '../data/quiz_models.dart';
import '../logic/quiz_ai_explainer.dart';

/// 题目页的「AI 解析」小按钮：点一下按题面 / 选项 / 正确答案 + 我的作答
/// 让大模型生成简短解析，流式显示并标注「仅供参考」。
///
/// 生成结果按题目缓存：同一道题再次查看直接读取，不重复消耗 token。
class QuizAiExplanation extends StatefulWidget {
  const QuizAiExplanation({
    super.key,
    required this.question,
    this.myAnswer,
    this.onSaveAnalysis,
  });

  final Question question;

  /// 当前作答（可选）：带上后模型能顺带说明错在哪里。
  final String? myAnswer;

  /// 生成完成后把解析写回题目；为空时只展示 AI 结果，不提供覆盖入口。
  final Future<void> Function(String text)? onSaveAnalysis;

  @override
  State<QuizAiExplanation> createState() => _QuizAiExplanationState();
}

class _QuizAiExplanationState extends State<QuizAiExplanation> {
  String _text = '';
  String? _error;
  bool _loading = false;
  bool _expanded = false;
  StreamSubscription<String>? _sub;

  QuizAiService get _service => QuizAiService.instance;

  @override
  void initState() {
    super.initState();
    _loadCache();
  }

  @override
  void didUpdateWidget(QuizAiExplanation oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 翻到下一题时列表位置不变，State 会被复用：必须清掉上一题的解析。
    if (oldWidget.question.id != widget.question.id) {
      _sub?.cancel();
      _sub = null;
      _text = '';
      _error = null;
      _loading = false;
      _expanded = false;
      _loadCache();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadCache() async {
    final id = widget.question.id;
    final cached = await _service.cached(widget.question);
    // 读盘期间可能已翻题或已开始生成：只接受仍然对得上的结果。
    if (!mounted || cached == null || _loading || _text.isNotEmpty) return;
    if (id != widget.question.id) return;
    setState(() {
      _text = cached;
      _expanded = true;
    });
  }

  Future<void> _run() async {
    final service = _service;
    if (!service.configured) {
      _showHint(service.unconfiguredHint);
      return;
    }
    final question = widget.question;
    _sub?.cancel();
    setState(() {
      _expanded = true;
      _loading = true;
      _error = null;
      _text = '';
    });

    final buffer = StringBuffer();
    _sub = service.explain(question, myAnswer: widget.myAnswer).listen(
      (delta) {
        buffer.write(delta);
        if (!mounted || question.id != widget.question.id) return;
        setState(() => _text = cleanAiAnalysis(buffer.toString()));
      },
      onError: (Object e) {
        if (!mounted || question.id != widget.question.id) return;
        setState(() {
          _loading = false;
          _error = describeNetworkError(e);
        });
      },
      onDone: () {
        if (!mounted || question.id != widget.question.id) return;
        setState(() {
          _loading = false;
          _text = cleanAiAnalysis(buffer.toString());
        });
      },
      cancelOnError: true,
    );
  }

  void _showHint(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _applyAnalysis() async {
    final save = widget.onSaveAnalysis;
    if (save == null || _loading || _text.isEmpty) return;
    if (widget.question.hasAnalysis) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('覆盖解析')),
          content: Text(tr('AI 解析将覆盖原有解析，确定吗？')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('覆盖')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      await save(_text);
      if (!mounted) return;
      _showHint(tr('已写入解析'));
    } catch (e) {
      if (mounted) _showHint(trf('写入解析失败：{e}', {'e': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_expanded) return _trigger(context);
    return _card(context);
  }

  Widget _trigger(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('ai-explain'),
        onPressed: _run,
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: scheme.primaryContainer.withOpacity(0.32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusXs + 8),
          ),
        ),
        icon: const Icon(Icons.auto_awesome, size: 15),
        label: Text(tr('AI 解析'), style: Theme.of(context).textTheme.labelLarge),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      key: const ValueKey('ai-explain-panel'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(isDark ? 0.20 : 0.34),
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        border: Border.all(color: scheme.primary.withOpacity(0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                tr('AI 解析'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('仅供参考'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!_loading && (_text.isNotEmpty || _error != null))
                IconButton(
                  key: const ValueKey('ai-explain-retry'),
                  onPressed: _run,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 32, height: 32),
                  tooltip: tr('重新解析'),
                  icon: Icon(Icons.refresh,
                      size: 16, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 2, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 14, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${tr('解析失败')}：$_error',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ),
                ],
              ),
            )
          else if (_text.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(0, 4, 8, 2),
              child: AiStatusIndicator.waiting(label: 'AI 正在解析…'),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 4, 0),
              child: Stack(
                children: [
                  SelectableText(
                    _text,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                  if (_loading)
                    const Positioned(
                      right: 0,
                      bottom: 2,
                      child: AiTypingCursor(height: 13),
                    ),
                ],
              ),
            ),
          if (widget.onSaveAnalysis != null && _text.isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('ai-explain-save'),
                  onPressed: _applyAnalysis,
                  icon: const Icon(Icons.save_outlined, size: 15),
                  label: Text(
                      widget.question.hasAnalysis ? tr('覆盖解析') : tr('添加解析')),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
