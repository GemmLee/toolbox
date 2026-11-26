import 'package:flutter/material.dart';

import '../../core/platform/browser_opener.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/app_widgets.dart';
import '../tools/quiz/logic/quiz_remote_index.dart';
import 'app_update_service.dart' show AppUpdateInfo, AppUpdateService, kReleasePageUrl;

/// 下载站：题库读线上索引，安装包走 GitHub Release。
class DownloadStationPage extends StatefulWidget {
  const DownloadStationPage({
    super.key,
    this.indexService,
    this.updateService,
    this.opener,
  });

  final QuizIndexService? indexService;
  final AppUpdateService? updateService;
  final BrowserOpener? opener;

  @override
  State<DownloadStationPage> createState() => _DownloadStationPageState();
}

class _DownloadStationPageState extends State<DownloadStationPage> {
  late QuizIndexService _indexService;
  late AppUpdateService _updateService;
  BrowserOpener? _opener;
  List<QuizRemoteFile> _banks = const <QuizRemoteFile>[];
  late String _apkUrl;
  bool _loading = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _indexService = widget.indexService ??
        QuizIndexService(
          baseUrl: QuizIndexService.kPagesResourceBaseUrl,
          fallbackBaseUrl: QuizIndexService.kDefaultQuizResourceBaseUrl,
        );
    _updateService = widget.updateService ?? AppUpdateService();
    _apkUrl = kReleasePageUrl;
    _opener = widget.opener;
    _load();
  }

  @override
  void dispose() {
    if (widget.indexService == null) _indexService.dispose();
    if (widget.updateService == null) _updateService.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait<Object?>(<Future<Object?>>[
      _indexService.fetch().then<Object?>(
            (value) => value,
            onError: (Object error) => error,
          ),
      _updateService.fetch().then<Object?>(
            (value) => value,
            onError: (Object error) => error,
          ),
    ]);
    if (!mounted) return;
    setState(() {
      _banks = results[0] is List<QuizRemoteFile>
          ? results[0] as List<QuizRemoteFile>
          : const <QuizRemoteFile>[];
      if (results[1] is AppUpdateInfo &&
          (results[1] as AppUpdateInfo).downloadUrl.isNotEmpty) {
        _apkUrl = (results[1] as AppUpdateInfo).downloadUrl;
      }
      _loading = false;
    });
  }

  Future<void> _open(String url) async {
    if (_opening) return;
    setState(() => _opening = true);
    final opener = _opener ?? BrowserOpener();
    final ok = await opener.open(url);
    if (!mounted) return;
    setState(() => _opening = false);
    if (!ok) showToast(context, tr('无法打开浏览器，请检查系统设置'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('下载站')),
        actions: [
          IconButton(
            key: const ValueKey('download-station-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: tr('刷新'),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  _apkCard(theme),
                  const SizedBox(height: 12),
                  _bankSection(theme),
                ],
              ),
            ),
    );
  }

  Widget _apkCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.android, size: 26, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'XMtools',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('download-station-apk'),
              onPressed: _opening ? null : () => _open(_apkUrl),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(tr('下载安装包')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bankSection(ThemeData theme) {
    return SectionCard(
      title: tr('题库资源'),
      subtitle: tr('在线资源'),
      children: _banks.isEmpty
          ? <Widget>[
              Text(
                tr('暂无在线资源，请稍后重试'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ]
          : <Widget>[
              for (final file in _banks) _bankRow(theme, file),
            ],
    );
  }

  Widget _bankRow(ThemeData theme, QuizRemoteFile file) {
    return Padding(
      key: ValueKey('download-station-${file.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          const Icon(Icons.description_outlined, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(file.title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  <String>[file.metaLabel, file.sizeLabel]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: ValueKey('download-station-bank-${file.id}'),
            onPressed: _opening
                ? null
                : () => _open(file.downloadUrl(_indexService.usedBaseUrl)),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(tr('下载')),
          ),
        ],
      ),
    );
  }
}
