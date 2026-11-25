import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatters.dart';
import '../../../core/platform/file_share.dart';
import '../../../core/settings/tool_texts.dart';
import '../../../core/storage/app_files.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/collapse_card.dart';
import 'download_manager.dart';
import 'download_page.dart';
import 'download_task.dart';
import 'douyin_webview.dart';
import 'link_credentials.dart';
import 'link_parser.dart';
import 'media_preview_page.dart';
import 'link_settings.dart';
import 'link_settings_page.dart';
import 'share_models.dart';
import 'xunlei_auth.dart';

/// 链接解析：粘贴分享文本 → 解析标题 / 封面 / 公开直链 → 下载到存储空间。
///
/// 不保存任何平台账号：网盘、需要登录签名的视频流只给出说明，
/// 不做「看起来能下、点了失败」的假按钮。
class LinkParserPage extends StatefulWidget {
  const LinkParserPage({
    super.key,
    this.parser,
    this.downloader,
    this.saver,
    this.loginBridge,
    this.credentialLoader,
    this.downloadManager,
    this.douyinBridge,
  });

  /// 注入点（测试用）：避免真实网络与文件 I/O。
  final LinkParser? parser;
  final Future<Uint8List> Function(String url)? downloader;
  final Future<StoredFile> Function(String name, List<int> bytes)? saver;

  /// 网盘登录 / 凭证读取的注入点。
  final LinkLoginBridge? loginBridge;
  final Future<List<LinkCredential>> Function()? credentialLoader;

  /// 下载队列（测试用）；不传则用全局单例。
  final DownloadManager? downloadManager;

  /// 抖音的隐藏 WebView 解析通道（测试用）。
  final DouyinWebViewBridge? douyinBridge;

  @override
  State<LinkParserPage> createState() => _LinkParserPageState();
}

class _LinkParserPageState extends State<LinkParserPage> {
  final TextEditingController _input = TextEditingController();

  /// 可选手填提取码：分享文案里常把提取码拆成另一条消息发，
  /// 只粘链接时自动识别不到，这里让用户补一个，填了优先用。
  final TextEditingController _pwd = TextEditingController();

  LinkParseResult? _result;

  /// 解析器要跨「列目录 → 取直链」复用会话，不能每次解析都新建。
  LinkParser? _activeParser;
  bool _busy = false;
  bool _loginBusy = false;
  String _progress = '';
  LinkSettings _settings = LinkSettingsStore.current.value;

  /// 当前页面发起的下载任务：进度从这里读，和下载页共享同一份队列。
  DownloadTask? _activeTask;
  DownloadManager? _manager;

  /// 登录面板单独选平台，不再依赖输入框里是否粘贴了链接——
  /// 否则直接点「打开官方登录页」只会弹一句一闪而过的提示，看起来像按钮坏了。
  String _loginPlatform = loginPlatforms.first;
  List<LinkCredential> _credentials = const <LinkCredential>[];

  /// 本次会话已下载的文件（可预览 / 分享）。
  final List<StoredFile> _saved = <StoredFile>[];

  @override
  void initState() {
    super.initState();
    _loadCredentials();
    _manager = widget.downloadManager ?? DownloadManager.instance;
    _manager!.addListener(_onManagerTick);
    _manager!.ensureLoaded();
    _loadSettings();
  }

  @override
  void dispose() {
    _manager?.removeListener(_onManagerTick);
    _input.dispose();
    _pwd.dispose();
    if (widget.parser == null) _activeParser?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final loaded = await LinkSettingsStore.load();
    if (!mounted) return;
    setState(() => _settings = loaded);
  }

  /// 下载队列有变化时同步页面上的进度文字。
  void _onManagerTick() {
    final task = _activeTask;
    if (task == null || !mounted) return;
    if (task.status == DownloadStatus.running) {
      setState(() {
        _progress = task.total > 0
            ? trf('已下载 {a} / {b}', {
                'a': formatBytes(task.done),
                'b': formatBytes(task.total),
              })
            : trf('已下载 {a}', {'a': formatBytes(task.done)});
      });
    }
  }

  Future<void> _loadCredentials() async {
    final all = await (widget.credentialLoader ?? LinkCredentialStore.load)();
    if (!mounted) return;
    setState(() => _credentials = all);
  }

  Future<void> _parse() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      showToast(context, tr('请先粘贴链接'));
      return;
    }
    final url = LinkParser.extractUrl(text) ?? text;
    setState(() {
      _busy = true;
      // 抖音要在 WebView 里跑完页面的风控挑战，冷启动十几秒很正常，先说清楚在等什么。
      _progress = url.contains('douyin.com') || url.contains('iesdouyin.com')
          ? tr('正在打开抖音页面取数据，首次通常要 10-30 秒')
          : '';
    });
    final parser = widget.parser ?? (_activeParser ??= LinkParser());
    final result = await parser.parse(
      text,
      headers: LinkCredentialStore.headersFor(url, _credentials),
      pwd: _pwd.text.trim(),
      credentialStorage: LinkCredentialStore.find(url, _credentials)?.storage ??
          const <String, String>{},
      douyinBridge: widget.douyinBridge,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) showToast(context, tr('剪贴板里没有文本'));
      return;
    }
    setState(() => _input.text = text);
    await _parse();
  }

  /// 复用网盘官方登录页：Cookie 与 localStorage 由原生 WebView 提取。
  /// 平台由登录面板里的下拉框决定，点按钮即可打开，不依赖输入框。
  ///
  /// 迅雷是例外：它的直链要由登录态账号转存后换取，网页 Cookie 走不通，
  /// 所以直接弹账号密码表单（对应 YunX 的 XunleiLoginScreen）。
  Future<void> _login() async {
    final platform = _loginPlatform;
    if (passwordLoginFor(platform)) {
      await _loginWithXunlei(platform);
      return;
    }
    final loginUrl = loginUrlFor(platform);
    if (loginUrl == null || loginUrl.isEmpty) {
      if (mounted) showToast(context, tr('请先粘贴该平台的链接'));
      return;
    }
    setState(() => _loginBusy = true);
    try {
      final credential = await (widget.loginBridge ?? LinkLoginBridge()).open(
        platform,
        loginUrl,
        cookieDomains: cookieDomainsFor(platform),
        desktop: desktopLoginFor(platform),
      );
      if (credential != null && !credential.isEmpty) {
        await LinkCredentialStore.save(credential);
        await _loadCredentials();
        if (mounted) {
          showToast(
            context,
            trf('已保存 {p} 登录凭证', {'p': platform}),
          );
        }
      }
    } catch (e) {
      if (mounted) showToast(context, trf('登录失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _loginBusy = false);
    }
  }

  /// 迅雷账号密码 / 短信登录：成功后把 access_token 存进本机凭证。
  Future<void> _loginWithXunlei(String platform) async {
    final account = await showModalBottomSheet<XunleiAccount>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _XunleiLoginSheet(),
    );
    if (account == null || !mounted) return;
    setState(() => _loginBusy = true);
    try {
      await LinkCredentialStore.save(
        LinkCredential(
          platform: platform,
          loginUrl: loginUrlFor(platform) ?? '',
          finalUrl: 'https://pan.xunlei.com/',
          cookies: '',
          storage: account.toStorage(),
          savedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _loadCredentials();
      if (mounted) {
        showToast(
          context,
          trf('已保存 {p} 登录凭证', {'p': account.label}),
        );
      }
    } finally {
      if (mounted) setState(() => _loginBusy = false);
    }
  }

  Future<void> _exportCredentials() async {
    if (_credentials.isEmpty) {
      showToast(context, tr('还没有登录凭证'));
      return;
    }
    final target = await FilePicker.platform.saveFile(
      fileName: 'link_credentials.json',
      bytes: utf8.encode(LinkCredentialStore.exportJson(_credentials)),
    );
    if (target != null && mounted) {
      showToast(context, tr('凭证已导出'));
    }
  }

  Future<void> _importCredentials() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final text = await File(path).readAsString();
      final count = await LinkCredentialStore.importJson(text);
      await _loadCredentials();
      if (mounted) {
        showToast(context, trf('已导入 {n} 份凭证', {'n': '$count'}));
      }
    } catch (e) {
      if (mounted) showToast(context, trf('导入失败：{e}', {'e': '$e'}));
    }
  }

  Future<void> _removeCredential(String platform) async {
    await LinkCredentialStore.remove(platform);
    await _loadCredentials();
  }

  Future<void> _downloadMedia(MediaItem item) async {
    await _saveLink(
      DownloadLink(
        url: item.url,
        filename: item.filename.isNotEmpty ? item.filename : _fileNameOf(item),
        size: 0,
        referer: item.referer.isNotEmpty
            ? item.referer
            : (Uri.tryParse(item.url)?.origin ?? ''),
        userAgent: item.userAgent,
      ),
    );
  }

  /// 打开网盘分享里的子目录，复用同一个会话。
  Future<void> _openDirectory(ShareFile directory) async {
    final parser = widget.parser ?? _activeParser;
    final result = _result;
    if (parser == null || result == null) return;
    setState(() => _busy = true);
    final next = await parser.openDirectory(result, directory);
    if (!mounted) return;
    setState(() {
      _result = next;
      _busy = false;
    });
  }

  /// 网盘文件 → 服务端协议换直链 → 下载；完成后清理云端临时转存。
  Future<void> _downloadShare(ShareFile file) async {
    final parser = widget.parser ?? _activeParser;
    final result = _result;
    if (parser == null || result == null) return;
    setState(() {
      _busy = true;
      _progress = tr('正在获取直链…');
    });
    DownloadLink? link;
    try {
      link = await parser.resolveDownload(result, file);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = '';
      });
      await _saveLink(link, fallbackName: file.name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = '';
      });
      showToast(context, trf('取链失败：{e}', {'e': '$e'}));
    } finally {
      if (link != null) {
        await parser.cleanup(result, link);
      }
    }
  }

  Future<void> _saveLink(DownloadLink link, {String? fallbackName}) async {
    final name = link.filename.isNotEmpty
        ? link.filename
        : (fallbackName ?? link.url.split('/').last);
    setState(() {
      _busy = true;
      _progress = tr('准备下载');
    });
    final manager = _manager ?? DownloadManager.instance;
    final headers = <String, String>{
      ...LinkCredentialStore.headersFor(link.url, _credentials),
      ...link.headers(),
    };
    try {
      final injected = widget.downloader;
      StoredFile stored;
      if (injected != null) {
        final bytes = await injected(link.url);
        stored = widget.saver != null
            ? await widget.saver!(name, bytes)
            : await AppStore.saveBytes(
                category: AppStoreCategory.other,
                name: name,
                bytes: bytes,
              );
      } else {
        // 真实下载统一进队列：解析页和下载页看到的是同一份进度，
        // 退出页面也不会中断，还能在下载页暂停 / 续传。
        final task = manager.enqueue(
          url: link.url,
          name: name,
          platform: _result?.platform ?? '',
          size: link.size,
          referer: link.referer,
          userAgent: link.userAgent,
          headers: headers,
        );
        _activeTask = task;
        final finished = await task.completer.future;
        _activeTask = null;
        if (finished.status != DownloadStatus.done) {
          throw StateError(
            finished.status == DownloadStatus.canceled
                ? tr('下载已取消')
                : (finished.error.isEmpty ? tr('下载失败') : finished.error),
          );
        }
        final path = finished.localPath.isNotEmpty
            ? finished.localPath
            : finished.savedPath;
        if (path.isEmpty) {
          throw StateError(tr('系统没有返回保存位置'));
        }
        stored = StoredFile(
          category: AppStoreCategory.other,
          file: File(path),
          size: finished.done,
          modified: DateTime.now(),
        );
      }
      if (!mounted) return;
      setState(() {
        _saved.insert(0, stored);
        _busy = false;
        _progress = '';
      });
      showToast(context, trf('已保存：{name}', {'name': stored.name}));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = '';
      });
      showToast(context, trf('下载失败：{e}', {'e': '$e'}));
    }
  }

  static String _fileNameOf(MediaItem item) {
    final path = Uri.tryParse(item.url)?.path ?? '';
    var name = path.split('/').last;
    if (name.isEmpty || !name.contains('.')) {
      name = '${item.kind.name}_${DateTime.now().millisecondsSinceEpoch}'
          '${_extensionFor(item.kind)}';
    }
    return name;
  }

  static String _extensionFor(MediaKind kind) => switch (kind) {
        MediaKind.image => '.jpg',
        MediaKind.video => '.mp4',
        MediaKind.audio => '.m4a',
        MediaKind.file => '.bin',
      };

  Future<void> _share(StoredFile file) async {
    final ok = await FileShare.share(<File>[file.file]);
    if (!ok && mounted) showToast(context, tr('没有可分享的应用'));
  }

  /// 打开下载管理页；解析页和它共用同一个队列。
  Future<void> _openDownloads() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadPage(
          manager: _manager,
          onOpenSettings: _openSettings,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LinkSettingsPage(manager: _manager),
      ),
    );
    await _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manager = _manager;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('链接解析')),
        actions: <Widget>[
          if (manager != null)
            ListenableBuilder(
              listenable: manager,
              builder: (context, _) {
                final active =
                    manager.tasks.where((task) => task.status.isActive).length;
                return IconButton(
                  key: const ValueKey('link-downloads'),
                  tooltip: tr('下载管理'),
                  onPressed: _openDownloads,
                  icon: Badge(
                    isLabelVisible: active > 0,
                    label: Text('$active'),
                    child: const Icon(Icons.download_outlined),
                  ),
                );
              },
            ),
          IconButton(
            key: const ValueKey('link-settings'),
            tooltip: tr('设置'),
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: <Widget>[
          _inputCard(theme),
          const SizedBox(height: 10),
          _credentialCard(theme),
          if (_busy) ...<Widget>[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Column(
                  children: <Widget>[
                    const CircularProgressIndicator(strokeWidth: 2),
                    if (_progress.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        _progress,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_result != null && !_busy) _resultCard(_result!),
          if (_saved.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _savedCard(theme),
          ],
          const SizedBox(height: 10),
          SmallHint(
            text: tr(
                '夸克 / UC / 百度 / 139 / 123 / 115 / 迅雷 / 光鸭 / 蓝奏云 / 蓝奏优享 分享可列目录并取临时直链；视频支持 B 站 / AcFun / 快手 / 微博 / 小红书 / Pixiv / 抖音。'),
          ),
        ],
      ),
    );
  }

  /// 登录凭证 + 下载设置：默认折叠，不干扰「粘贴 → 解析」的主流程。
  Widget _credentialCard(ThemeData theme) {
    return CollapseCard(
      title: tr('网盘登录与下载'),
      dense: true,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(tr('登录平台'), style: theme.textTheme.bodySmall),
            const SizedBox(width: 10),
            // 限宽：isExpanded 会让下拉菜单撑满整行，平台选择窗铺满屏幕太笨重。
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('link-login-platform'),
                value: _loginPlatform,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final platform in loginPlatforms)
                    DropdownMenuItem<String>(
                      value: platform,
                      child: Text(platform, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _loginBusy || _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _loginPlatform = value);
                        }
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            key: const ValueKey('link-login'),
            onPressed: _loginBusy || _busy ? null : _login,
            icon: Icon(
              passwordLoginFor(_loginPlatform)
                  ? Icons.password_outlined
                  : Icons.login_outlined,
              size: 18,
            ),
            label: Text(
              _loginBusy
                  ? (passwordLoginFor(_loginPlatform)
                      ? tr('正在登录…')
                      : tr('正在打开登录页…'))
                  : (passwordLoginFor(_loginPlatform)
                      ? tr('账号密码登录')
                      : tr('打开官方登录页')),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_credentials.isEmpty)
          SmallHint(text: tr('登录后凭证只保存在本机，可导出到 JSON 备份。'))
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              for (final credential in _credentials)
                Chip(
                  key: ValueKey<String>(
                      'link-credential-${credential.platform}'),
                  label: Text(credential.platform),
                  visualDensity: VisualDensity.compact,
                  labelStyle: theme.textTheme.labelSmall,
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () => _removeCredential(credential.platform),
                ),
            ],
          ),
        Row(
          children: <Widget>[
            TextButton.icon(
              onPressed: _exportCredentials,
              icon: const Icon(Icons.ios_share_outlined, size: 16),
              label: Text(tr('导出凭证')),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: _importCredentials,
              icon: const Icon(Icons.file_open_outlined, size: 16),
              label: Text(tr('导入凭证')),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _settings.toPhone
                    ? trf('保存到：{p}', {
                        'p': phoneRelativeDir(_settings.phoneDir),
                      })
                    : trf('保存到：{p}', {'p': tr('应用存储空间')}),
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: const ValueKey('link-open-settings'),
              onPressed: _openSettings,
              child: Text(tr('下载设置')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _inputCard(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              tr('分享链接'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('link-input'),
              controller: _input,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: tr('粘贴分享文本或 http(s) 链接'),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('link-extract-code'),
              controller: _pwd,
              maxLines: 1,
              decoration: InputDecoration(
                hintText: tr('提取码（可选）'),
                helperText: tr('只粘了链接、分享文案里的提取码丢了时填这里'),
                isDense: true,
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                TextButton.icon(
                  key: const ValueKey('link-paste'),
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: Text(tr('粘贴并解析')),
                ),
                const Spacer(),
                FilledButton.icon(
                  key: const ValueKey('link-parse'),
                  onPressed: _busy ? null : _parse,
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: Text(tr('解析')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(LinkParseResult result) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (!result.success) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: scheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.error!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Chip(
                  label: Text(result.platform),
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(fontSize: 11),
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.title.isEmpty ? tr('未取到标题') : result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (result.coverUrl != null) ...<Widget>[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  result.coverUrl!,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 160,
                    alignment: Alignment.center,
                    color: scheme.onSurface.withOpacity(0.06),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.image_not_supported_outlined,
                            size: 28, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 6),
                        Text(tr('封面加载失败'),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            if (result.canBrowse && result.files.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              for (final file in result.files)
                ListTile(
                  key: ValueKey<String>('link-file-${file.fid}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    file.isDir
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  title: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    file.isDir ? tr('目录') : formatBytes(file.size),
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: TextButton(
                    key: ValueKey<String>('link-file-action-${file.fid}'),
                    onPressed: _busy
                        ? null
                        : () => file.isDir
                            ? _openDirectory(file)
                            : _downloadShare(file),
                    child: Text(file.isDir ? tr('打开') : tr('下载')),
                  ),
                ),
            ],
            if (!result.canBrowse && result.media.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              _mediaGrid(result),
            ],
            if (result.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                result.note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 媒体双列网格：图集的价值就是「看」，所以先铺缩略图，点开即预览。
  ///
  /// 与 YunX 的 `VideoResultSection` 同构：方格 + 左上角 `n/总数` + 右下角下载球，
  /// 视频格中间压一个播放图标（点开就是全屏播放器）。
  Widget _mediaGrid(LinkParseResult result) {
    // 单条视频不给方格：一个 16:9 的宽格更像「播放器」，也不会只占半行。
    if (result.media.length == 1 &&
        result.media.single.kind == MediaKind.video) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: _mediaTile(result, 0),
      );
    }
    return GridView.builder(
      key: const ValueKey('link-media-grid'),
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: result.media.length,
      itemBuilder: (context, index) => _mediaTile(result, index),
    );
  }

  Widget _mediaTile(LinkParseResult result, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = result.media[index];
    final isVideo = item.kind == MediaKind.video;
    // 视频直链是 mp4，画不成图片：用解析结果的封面当缩略图。
    final thumb = isVideo ? (result.coverUrl ?? '') : item.url;
    final headers = <String, String>{
      if (item.referer.isNotEmpty) 'Referer': item.referer,
      if (item.userAgent.isNotEmpty) 'User-Agent': item.userAgent,
    };
    return Material(
      color: scheme.onSurface.withOpacity(0.06),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('link-media-$index'),
        onTap: () => _openPreview(result, index),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (thumb.isNotEmpty)
              Image.network(
                thumb,
                headers: headers,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _mediaPlaceholder(item, scheme),
              )
            else
              _mediaPlaceholder(item, scheme),
            if (isVideo)
              Center(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.42),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${index + 1}/${result.media.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 4,
              bottom: 4,
              child: SizedBox(
                width: 32,
                height: 32,
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    key: ValueKey('link-media-download-$index'),
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    tooltip: tr('下载'),
                    icon: Icon(Icons.download_outlined, color: scheme.primary),
                    onPressed: _busy ? null : () => _downloadMedia(item),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaPlaceholder(MediaItem item, ColorScheme scheme) {
    return ColoredBox(
      color: scheme.onSurface.withOpacity(0.06),
      child: Center(
        child: Icon(
          switch (item.kind) {
            MediaKind.image => Icons.image_outlined,
            MediaKind.video => Icons.movie_outlined,
            MediaKind.audio => Icons.audiotrack_outlined,
            MediaKind.file => Icons.insert_drive_file_outlined,
          },
          size: 26,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 全屏预览：左右翻页看下一张 / 下一个视频，图片支持双指放大。
  Future<void> _openPreview(LinkParseResult result, int index) async {
    final items = <PreviewMedia>[
      for (final item in result.media)
        PreviewMedia(
          url: item.url,
          isVideo: item.kind == MediaKind.video,
          name: item.filename,
          referer: item.referer,
          userAgent: item.userAgent,
          thumbnail: result.coverUrl ?? '',
        ),
    ];
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaPreviewPage(
          items: items,
          initialIndex: index,
          caption: result.title.isEmpty ? result.platform : result.title,
          onDownload: (media) => _downloadMedia(
            MediaItem(
              url: media.url,
              kind: media.isVideo ? MediaKind.video : MediaKind.image,
              filename: media.name,
              referer: media.referer,
              userAgent: media.userAgent,
            ),
          ),
        ),
      ),
    );
  }

  Widget _savedCard(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    tr('已下载'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('link-open-downloads'),
                  onPressed: _openDownloads,
                  child: Text(tr('全部下载')),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final file in _saved)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                title: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(formatBytes(file.size)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: tr('预览'),
                      constraints:
                          const BoxConstraints.tightFor(width: 40, height: 40),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      onPressed: () => _preview(file),
                    ),
                    IconButton(
                      tooltip: tr('分享'),
                      constraints:
                          const BoxConstraints.tightFor(width: 40, height: 40),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.share_outlined, size: 18),
                      onPressed: () => _share(file),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图片直接全屏看；其他类型交给系统分享面板里的播放器。
  void _preview(StoredFile file) {
    final isImage = RegExp(r'\.(jpe?g|png|gif|webp|bmp)$', caseSensitive: false)
        .hasMatch(file.name);
    if (!isImage) {
      _share(file);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: InteractiveViewer(
          maxScale: 4,
          child: Image.file(file.file, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// 迅雷账号密码 / 短信登录（对齐 YunX `XunleiLoginScreen` 的主流程）。
///
/// 迅雷对新设备会返回 review_panel：账号密码只能验到这一步，接着必须补一次
/// 短信验证码才真正登录，所以这里把两种方式串在同一个面板里。
class _XunleiLoginSheet extends StatefulWidget {
  const _XunleiLoginSheet();

  @override
  State<_XunleiLoginSheet> createState() => _XunleiLoginSheetState();
}

class _XunleiLoginSheetState extends State<_XunleiLoginSheet> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _code = TextEditingController();

  XunleiDevice? _device;
  XunleiAuth? _auth;
  XunleiLoginStep? _smsStep;
  bool _busy = false;
  bool _needCode = false;
  bool _codeSent = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final device = await XunleiDevice.load();
    if (!mounted) return;
    setState(() {
      _device = device;
      _auth = XunleiAuth();
    });
  }

  void _say(String message) {
    if (mounted) setState(() => _status = message);
  }

  Future<void> _submitPassword() async {
    final user = _user.text.trim();
    final password = _pass.text;
    if (user.isEmpty || password.isEmpty) {
      _say(tr('请填写迅雷账号和密码'));
      return;
    }
    final auth = _auth;
    final device = _device;
    if (auth == null || device == null) {
      _say(tr('设备指纹还在准备，请稍后重试'));
      return;
    }
    setState(() {
      _busy = true;
      _status = tr('正在登录…');
    });
    try {
      final step = await auth.loginWithPassword(
        device: device,
        username: user,
        password: password,
      );
      if (!mounted) return;
      if (step.ok) {
        await _exchange(step, user);
        return;
      }
      if (step.needSms) {
        setState(() {
          _needCode = true;
          _busy = false;
          _status = step.message.isEmpty ? tr('该账号需要短信验证') : step.message;
        });
        await _sendCode();
        return;
      }
      setState(() {
        _busy = false;
        _status = step.message;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = trf('登录失败：{e}', {'e': '$e'});
        });
      }
    }
  }

  Future<void> _sendCode() async {
    final auth = _auth;
    final device = _device;
    if (auth == null || device == null) return;
    final user = _user.text.trim();
    if (user.isEmpty) {
      _say(tr('请先填写手机号'));
      return;
    }
    setState(() {
      _busy = true;
      _status = tr('正在发送验证码…');
    });
    try {
      final step = await auth.sendSms(device: device, mobile: user);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _codeSent = true;
        _smsStep = step;
        _status = step.message;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = trf('验证码发送失败：{e}', {'e': '$e'});
        });
      }
    }
  }

  Future<void> _submitCode() async {
    final auth = _auth;
    final device = _device;
    final step = _smsStep;
    if (auth == null || device == null) return;
    final code = _code.text.trim();
    if (code.isEmpty) {
      _say(tr('请填写短信验证码'));
      return;
    }
    setState(() {
      _busy = true;
      _status = tr('正在验证…');
    });
    try {
      final result = await auth.loginWithSms(
        device: device,
        mobile: _user.text.trim(),
        code: code,
        creditKey: step?.smsCreditKey ?? '',
        smsToken: step?.smsToken ?? '',
      );
      if (!mounted) return;
      if (result.ok) {
        await _exchange(result, _user.text.trim());
        return;
      }
      setState(() {
        _busy = false;
        _status = result.message;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = trf('验证失败：{e}', {'e': '$e'});
        });
      }
    }
  }

  /// 用登录返回的 sessionID 换 access_token，成功后把账号交回给页面保存。
  Future<void> _exchange(XunleiLoginStep step, String user) async {
    final auth = _auth;
    final device = _device;
    if (auth == null || device == null) return;
    if (step.sessionId.isEmpty) {
      setState(() {
        _busy = false;
        _status = tr('登录成功但没有拿到会话，请重试');
      });
      return;
    }
    setState(() => _status = tr('正在换取访问令牌…'));
    try {
      final pair = await auth.exchangeToken(
        device: device,
        sessionId: step.sessionId,
        userId: step.userId,
        username: user,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        XunleiAccount(
          device: device,
          accessToken: pair.accessToken,
          refreshToken: pair.refreshToken,
          userId: step.userId,
          nickname: step.nickname,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = trf('换取访问令牌失败：{e}', {'e': '$e'});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              tr('迅雷账号登录'),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              tr('账号密码直接登录，不走网页；新设备会被要求短信验证码'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('xunlei-account'),
              controller: _user,
              enabled: !_busy && !_needCode,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: tr('手机号 / 邮箱'),
                isDense: true,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person_outline, size: 18),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('xunlei-password'),
              controller: _pass,
              enabled: !_busy && !_needCode,
              obscureText: true,
              decoration: InputDecoration(
                labelText: tr('密码'),
                isDense: true,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline, size: 18),
              ),
              onSubmitted: (_) => _submitPassword(),
            ),
            if (_needCode) ...<Widget>[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('xunlei-sms-code'),
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('短信验证码'),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.shield_outlined, size: 18),
                  suffixIcon: TextButton(
                    key: const ValueKey('xunlei-send-code'),
                    onPressed: _busy ? null : _sendCode,
                    child: Text(_codeSent ? tr('重新发送') : tr('发送验证码')),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('xunlei-login'),
              onPressed:
                  _busy ? null : (_needCode ? _submitCode : _submitPassword),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
              child: Text(_needCode ? tr('验证并登录') : tr('登录')),
            ),
            if (_status.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
