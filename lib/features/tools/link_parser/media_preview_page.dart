import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/settings/tool_texts.dart';

/// 预览用的媒体：解析结果里的直链 + 防盗链请求头。
class PreviewMedia {
  const PreviewMedia({
    required this.url,
    required this.isVideo,
    this.name = '',
    this.referer = '',
    this.userAgent = '',
    this.thumbnail = '',
  });

  final String url;
  final bool isVideo;
  final String name;
  final String referer;
  final String userAgent;

  /// 视频格子在网格里的封面；没有就画一个纯色占位。
  final String thumbnail;

  Map<String, String> get headers => <String, String>{
        if (referer.isNotEmpty) 'Referer': referer,
        if (userAgent.isNotEmpty) 'User-Agent': userAgent,
      };
}

/// 全屏媒体预览：左右翻页看下一张 / 下一个视频，图片可双指放大。
///
/// 对应 YunX 的 `MediaPreviewScreen`：图集的价值就是「看」，
/// 不能只有「下载」一个入口。
class MediaPreviewPage extends StatefulWidget {
  const MediaPreviewPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onDownload,
    this.caption = '',
  });

  final List<PreviewMedia> items;
  final int initialIndex;

  /// 顶栏的下载按钮：交给解析页复用同一套下载队列。
  final ValueChanged<PreviewMedia>? onDownload;

  /// 底部说明（作品的文案 / 文件名）。
  final String caption;

  @override
  State<MediaPreviewPage> createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage> {
  late final PageController _page =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final current = items[_index.clamp(0, items.length - 1)];
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.35),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_index + 1} / ${items.length}',
          key: const ValueKey('preview-index'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: <Widget>[
          if (widget.onDownload != null)
            IconButton(
              key: const ValueKey('preview-download'),
              tooltip: tr('下载'),
              icon: const Icon(Icons.download_outlined),
              onPressed: () => widget.onDownload!(current),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: PageView.builder(
              controller: _page,
              itemCount: items.length,
              onPageChanged: (value) => setState(() => _index = value),
              itemBuilder: (context, i) {
                final item = items[i];
                return item.isVideo
                    ? _VideoPane(item: item, active: i == _index)
                    : _ImagePane(item: item);
              },
            ),
          ),
          if (widget.caption.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.black.withOpacity(0.45),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Text(
                widget.caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单张图片：双指缩放 + 拖拽。
class _ImagePane extends StatelessWidget {
  const _ImagePane({required this.item});

  final PreviewMedia item;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Center(
        child: Image.network(
          item.url,
          headers: item.headers,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            final total = progress.expectedTotalBytes;
            return Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                  value: total == null || total <= 0
                      ? null
                      : progress.cumulativeBytesLoaded / total,
                ),
              ),
            );
          },
          errorBuilder: (context, error, stack) => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '这张图没能加载出来，可能是直链已过期（回到解析页重新解析一次即可）。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个视频：进来就播，点一下暂停 / 继续，底部可拖动进度。
///
/// 只在「当前页」初始化播放器：翻页时把邻居页的实例放掉，
/// 免得一次开好几个 ExoPlayer 各自拉流。
class _VideoPane extends StatefulWidget {
  const _VideoPane({required this.item, required this.active});

  final PreviewMedia item;
  final bool active;

  @override
  State<_VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<_VideoPane> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(_VideoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _start();
    } else {
      _controller?.pause();
    }
  }

  Future<void> _start() async {
    final existing = _controller;
    if (existing != null) {
      await existing.play();
      return;
    }
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.item.url),
      httpHeaders: widget.item.headers,
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      await controller.play();
      setState(() => _failed = false);
    } catch (_) {
      if (!mounted || _controller != controller) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '这个视频没能播放，可能是直链已过期（回到解析页重新解析一次即可），或该平台要求登录。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white70),
        ),
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return Stack(
          alignment: Alignment.center,
          children: <Widget>[
            GestureDetector(
              onTap: () => value.isPlaying ? controller.pause() : controller.play(),
              child: Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            if (!value.isPlaying)
              IgnorePointer(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.white,
                      bufferedColor: Colors.white30,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Text(
                        '${_clock(value.position)} / ${_clock(value.duration)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _clock(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
