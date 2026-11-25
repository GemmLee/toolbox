import 'package:flutter/material.dart';

import '../../core/platform/browser_opener.dart';
import '../../core/settings/app_version.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/app_widgets.dart';
import '../tools/quiz/logic/quiz_remote_index.dart';
import 'app_update_service.dart';

/// 下载站：与网页 xmhome 同源的公开 R2 资源列表（安装包 + 题库）。
///
/// 只读取公开直链，不含任何密钥或私有域名；下载统一交给系统浏览器。
/// [updateService] / [indexService] / [opener] 均可注入以便测试。
class DownloadStationPage extends StatefulWidget {
  const DownloadStationPage({
    super.key,
    this.updateService,
    this.indexService,
    this.opener,
  });

  final AppUpdateService? updateService;
  final QuizIndexService? indexService;
  final BrowserOpener? opener;

  @override
  State<DownloadStationPage> createState() => _DownloadStationPageState();
}

class _DownloadStationPageState extends State<DownloadStationPage> {
  late AppUpdateService _updateService;
  late QuizIndexService _indexService;
  BrowserOpener? _opener;
  AppUpdateInfo? _apk;
  List<QuizRemoteFile> _banks = const <QuizRemoteFile>[];
  bool _loading = true;
  String? _bankError;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _updateService = widget.updateService ?? AppUpdateService();
    _indexService = widget.indexService ?? QuizIndexService();
    _opener = widget.opener;
    _load();
  }

  @override
  void dispose() {
    if (widget.updateService == null) _updateService.dispose();
    if (widget.indexService == null) _indexService.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _bankError = null;
    });
    final results = await Future.wait<Object?>(<Future<Object?>>[
      _updateService
          .fetch()
          .then<Object?>((value) => value, onError: (Object error) => error),
      _indexService
          .fetch()
          .then<Object?>((value) => value, onError: (Object error) => error),
    ]);
    if (!mounted) return;
    setState(() {
      _apk = results[0] is AppUpdateInfo ? results[0] as AppUpdateInfo : null;
      if (results[1] is List<QuizRemoteFile>) {
        _banks = results[1] as List<QuizRemoteFile>;
      } else {
        _bankError = '${results[1]}';
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

  /// 安装包：主内容，版本来自 R2 的 version.json，回退到本地版本。
  Widget _apkCard(ThemeData theme) {
    final version = _apk?.version ?? kAppVersion;
    final url = _apk != null
        ? _apk!.apkUrl(_updateService.baseUrl)
        : AppUpdateInfo(version: version)
            .apkUrl(AppUpdateService.kPublicResourceBaseUrl);
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
                      const SizedBox(height: 2),
                      Text(
                        '${tr('安装包')} · $version',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_apk != null && _apk!.notes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _apk!.notes,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const ValueKey('download-station-apk'),
                onPressed: _opening ? null : () => _open(url),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(tr('下载新版本')),
              ),
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
                _bankError ?? tr('暂无在线资源，请稍后重试'),
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
                : () => _open(file.downloadUrl(_indexService.baseUrl)),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(tr('下载')),
          ),
        ],
      ),
    );
  }
}
