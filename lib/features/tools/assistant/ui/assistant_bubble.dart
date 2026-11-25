import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/ai_status_indicator.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/assistant_api.dart';
import '../logic/quiz_result.dart';

// —— 气泡数据 ——

class AssistantBubbleData {
  const AssistantBubbleData({
    required this.text,
    required this.isUser,
    required this.error,
    this.display,
    this.quiz,
    this.tokens,
    this.raw,
    this.streaming = false,
    this.waiting = false,
  });

  factory AssistantBubbleData.of(ChatMessage message) {
    final isUser = message.role == 'user';
    final quiz =
        !isUser && !message.error ? extractQuizBankJson(message.content) : null;
    // JSON 写到一半被长度上限截断：不再把半截 JSON 铺满屏幕，只给提示 + 复制原文。
    final incomplete = !isUser &&
        !message.error &&
        quiz == null &&
        looksLikeIncompleteJson(message.content);
    return AssistantBubbleData(
      text: isUser
          ? (message.display ?? message.content)
          : incomplete
              ? trf('输出未完成（可能达到模型长度上限，已接收 {n} 字符），可复制原文或重新发送',
                  {'n': message.content.length})
              : message.content,
      isUser: isUser,
      error: message.error,
      display: message.display,
      quiz: quiz,
      raw: incomplete ? message.content : null,
      tokens: (!isUser && message.promptTokens + message.completionTokens > 0)
          ? '${tr('输入')} ${message.promptTokens} · ${tr('输出')} ${message.completionTokens}'
          : null,
    );
  }

  factory AssistantBubbleData.streaming(String partial) {
    final trimmed = partial.trimLeft();
    // 题库 JSON 生成过程中不要刷屏：只显示进度，完成后自动变成文件卡片。
    final looksJson = trimmed.startsWith('{') && partial.length > 300;
    final waiting = partial.isEmpty;
    return AssistantBubbleData(
      text: waiting
          ? ''
          : looksJson
              ? trf('正在生成题库 JSON…（已接收 {n} 字符，完成后会转成文件）', {'n': partial.length})
              : partial,
      isUser: false,
      error: false,
      streaming: true,
      waiting: waiting,
    );
  }

  final String text;
  final bool isUser;
  final bool error;
  final String? display;
  final QuizBankExtract? quiz;
  final String? tokens;

  /// 未能解析的原始输出（截断时用于复制）。
  final String? raw;

  /// 正在流式输出（此时不提供复制按钮）。
  final bool streaming;

  /// 已发起请求但还没收到首字（显示思考动画）。
  final bool waiting;
}
// —— 消息气泡 ——

class AssistantBubble extends StatelessWidget {
  const AssistantBubble({super.key, required this.data});

  final AssistantBubbleData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 复制按钮放在气泡**下方**（主流 AI 工具的做法），不挤在气泡里：
    // 长回答时气泡边缘不会因为按钮而变宽，按钮位置也稳定。
    final copyText = data.raw ?? data.text;
    final canCopy = !data.isUser &&
        !data.error &&
        !data.streaming &&
        data.quiz == null &&
        copyText.trim().isNotEmpty;
    return Align(
      alignment: data.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            data.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.84),
            decoration: BoxDecoration(
              color: data.error
                  ? theme.colorScheme.errorContainer
                  : data.isUser
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(data.isUser ? 16 : 4),
                bottomRight: Radius.circular(data.isUser ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 识别到题库时不再把整段 JSON 当聊天文本铺开，改为文件卡片。
                if (data.quiz != null)
                  AssistantQuizResultCard(extract: data.quiz!)
                else if (data.waiting)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: AiStatusIndicator.waiting(
                      label: tr('AI 正在思考…'),
                    ),
                  )
                else
                  Stack(
                    children: [
                      AssistantCollapsibleText(
                        text: data.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: data.error
                              ? theme.colorScheme.onErrorContainer
                              : null,
                        ),
                      ),
                      if (data.streaming)
                        const Positioned(
                          right: 0,
                          bottom: 2,
                          child: AiTypingCursor(height: 13),
                        ),
                    ],
                  ),
                if (data.tokens != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      data.tokens!,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
              ],
            ),
          ),
          if (canCopy)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 2),
              child: TextButton.icon(
                onPressed: () => copyWithToast(context, copyText),
                icon: const Icon(Icons.copy_outlined, size: 15),
                label: Text(tr('复制')),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  textStyle: theme.textTheme.labelMedium,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// —— 长文本气泡：默认折叠，避免大段原文刷屏 ——

class AssistantCollapsibleText extends StatefulWidget {
  const AssistantCollapsibleText(
      {super.key, required this.text, required this.style});

  final String text;
  final TextStyle? style;

  /// 超过该长度默认只显示前 [previewLength] 个字符。
  static const int previewLength = 600;

  @override
  State<AssistantCollapsibleText> createState() =>
      AssistantCollapsibleTextState();
}

class AssistantCollapsibleTextState extends State<AssistantCollapsibleText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final collapsible = text.length > AssistantCollapsibleText.previewLength;
    final shown = collapsible && !_expanded
        ? '${text.substring(0, AssistantCollapsibleText.previewLength)}…'
        : text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(shown, style: widget.style),
        if (collapsible)
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded
                ? tr('收起')
                : trf('展开全文（共 {n} 字符）', {'n': text.length})),
          ),
      ],
    );
  }
}

// —— 题库结果卡（以文件形式呈现，长 JSON 默认折叠） ——
class AssistantQuizResultCard extends StatefulWidget {
  const AssistantQuizResultCard({super.key, required this.extract});

  final QuizBankExtract extract;

  @override
  State<AssistantQuizResultCard> createState() =>
      AssistantQuizResultCardState();
}

class AssistantQuizResultCardState extends State<AssistantQuizResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final extract = widget.extract;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.description_outlined,
                  size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      extract.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tr('题库文件')} · ${trf('{n} 题', {'n': extract.count})}'
                      ' · ${extract.sizeLabel}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => importQuizJson(context, extract),
                icon: const Icon(Icons.upload_outlined, size: 16),
                label: Text(tr('导入题库')),
              ),
              ActionChip(
                avatar: const Icon(Icons.save_outlined, size: 16),
                label: Text(tr('保存文件')),
                onPressed: () => saveQuizJson(context, extract),
              ),
              ActionChip(
                avatar: const Icon(Icons.copy_outlined, size: 16),
                label: Text(tr('复制')),
                onPressed: () => copyWithToast(context, extract.raw),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(_expanded ? Icons.unfold_less : Icons.unfold_more,
                    size: 16),
                label: Text(_expanded ? tr('收起 JSON') : tr('查看 JSON')),
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  extract.raw,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace', height: 1.35),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}
