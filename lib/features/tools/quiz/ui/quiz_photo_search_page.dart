import 'package:flutter/material.dart';

import '../../../../core/platform/ocr.dart';
import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';
import '../logic/quiz_photo_match.dart';
import 'quiz_common.dart';
import 'quiz_question_detail.dart';

/// 拍照搜题：拍一张题目照片 → OCR 取文字 → 在题库里找最像的一道。
///
/// 复用 OCR 工具的选图与识别（注入点同样可替换），匹配交给 [bestMatchForText]。
class QuizPhotoSearchPage extends StatefulWidget {
  const QuizPhotoSearchPage({
    super.key,
    this.repo,
    this.picker = defaultOcrImagePicker,
    this.recognizer = OcrScanner.recognize,
    this.matcher,
  });

  final QuizRepository? repo;
  final OcrImagePicker picker;
  final OcrRecognizer recognizer;

  /// 测试注入；默认走 [bestMatchForText]。
  final Future<PhotoMatch?> Function(QuizRepository repo, String text)? matcher;

  @override
  State<QuizPhotoSearchPage> createState() => _QuizPhotoSearchPageState();
}

class _QuizPhotoSearchPageState extends State<QuizPhotoSearchPage> {
  bool _busy = false;
  String? _error;
  String? _ocrText;
  PhotoMatch? _match;
  bool _searched = false;

  Future<void> _scan(OcrImageSource source) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _searched = false;
      _match = null;
    });
    try {
      final path = await widget.picker(source);
      if (path == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final result = await widget.recognizer(path);
      final text = result.lines.isEmpty
          ? result.text
          : assembleOcrText(result.lines);
      if (!mounted) return;
      if (text.trim().isEmpty) {
        setState(() {
          _busy = false;
          _ocrText = null;
          _error = tr('没有识别到文字，试试更清晰的图片');
        });
        return;
      }
      final repo = widget.repo ?? await QuizServices.repo();
      final matcher = widget.matcher ?? bestMatchForText;
      final match = await matcher(repo, text);
      if (!mounted) return;
      setState(() {
        _ocrText = text;
        _match = match;
        _searched = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = trf('识别失败：{e}', {'e': '$e'});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('拍照搜题'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    tr('拍下题目，自动匹配题库里最接近的一道'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('photo-search-camera'),
                          onPressed: _busy
                              ? null
                              : () => _scan(OcrImageSource.camera),
                          icon: const Icon(Icons.photo_camera_outlined,
                              size: 18),
                          label: Text(tr('拍照识别')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('photo-search-gallery'),
                          onPressed: _busy
                              ? null
                              : () => _scan(OcrImageSource.gallery),
                          icon: const Icon(Icons.photo_library_outlined,
                              size: 18),
                          label: Text(tr('从相册选图')),
                        ),
                      ),
                    ],
                  ),
                  if (_busy) ...<Widget>[
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    SmallHint(text: tr('识别并匹配中'), maxLines: 1),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: SmallHint(text: _error!, color: scheme.error),
            ),
          if (!_busy && _searched && _match != null) ...<Widget>[
            const SizedBox(height: 12),
            _MatchCard(
              match: _match!,
              onOpenDetail: () => _openDetail(_match!),
            ),
          ],
          if (!_busy && _searched && _match == null) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      tr('题库里没有找到这道题'),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SmallHint(
                      text: tr('可能是题库未导入，或照片只拍到部分文字；可换个角度再试'),
                    ),
                    if (_ocrText != null) ...<Widget>[
                      const SizedBox(height: 10),
                      Text(
                        _ocrText!,
                        key: const ValueKey('photo-search-ocr-text'),
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openDetail(PhotoMatch match) async {
    final repo = widget.repo ?? await QuizServices.repo();
    if (!mounted) return;
    await showQuestionDetail(context, repo, match.question);
  }
}

/// 匹配结果：题干 + 选项（正确项标绿）+ 答案。
class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.onOpenDetail});

  final PhotoMatch match;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final correctBg = dark ? const Color(0x3834C759) : const Color(0x1F34C759);
    final correctFg = dark ? const Color(0xFF7BE8A6) : const Color(0xFF1B7F3B);
    final question = match.question;
    final answers = question.answer.map((a) => a.toLowerCase()).toSet();

    return Card(
      key: const ValueKey('photo-search-result'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Chip(
                  label: Text(typeLabel(question.type)),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                if (match.bankName.isNotEmpty)
                  Expanded(
                    child: Text(
                      match.bankName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              question.stem,
              key: const ValueKey('photo-search-stem'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            for (final option in question.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  key: ValueKey<String>('photo-option-${option.key}'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: answers.contains(option.key.toLowerCase())
                        ? correctBg
                        : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${option.key}.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: answers.contains(option.key.toLowerCase())
                              ? correctFg
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          option.text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.4,
                            color: answers.contains(option.key.toLowerCase())
                                ? correctFg
                                : null,
                          ),
                        ),
                      ),
                      if (answers.contains(option.key.toLowerCase()))
                        Icon(Icons.check_circle_outline,
                            size: 17, color: correctFg),
                    ],
                  ),
                ),
              ),
            Row(
              children: <Widget>[
                Text(
                  tr('答案'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    answerLabelOf(question),
                    key: const ValueKey('photo-search-answer'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: correctFg,
                    ),
                  ),
                ),
              ],
            ),
            if ((question.analysis ?? '').trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              SmallHint(text: question.analysis!, maxLines: 3),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('photo-search-open'),
                onPressed: onOpenDetail,
                child: Text(tr('在题库中查看')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
