import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 分片下载结果。
class DownloadedFile {
  const DownloadedFile({required this.file, required this.bytes});

  /// 临时文件：调用方用 AppStore.adopt 归档后可删掉。
  final File file;
  final int bytes;
}

/// 用户暂停 / 取消下载：由 [LinkDownloader.isCanceled] 在写入循环里抛出，
/// 用来把已经打开的文件句柄关掉再退出，不是真的错误。
class DownloadCanceledException implements Exception {
  const DownloadCanceledException();

  @override
  String toString() => '下载已取消';
}

/// 一次 HEAD 探测的结果。
class _Probe {
  const _Probe(this.length, this.supportsRange);

  final int? length;
  final bool supportsRange;
}

/// 分片多线程下载 + 断点续传 + 全局限速。
///
/// 临时文件统一用 `xmt_` 前缀，存储空间页的缓存明细能识别并在必要时清理；
/// 下载中断后再次调用会用已有长度作为起点，只补齐剩余区间。
/// 服务端不支持 Range 时自动退回单流下载，不会写出半截文件。
class LinkDownloader {
  LinkDownloader({
    http.Client? client,
    this.threads = 4,
    this.speedLimitBytesPerSecond = 0,
    this.headers = const <String, String>{},
    Future<Directory> Function()? tempDirLoader,
    this.timeout = const Duration(seconds: 30),
  })  : _client = client,
        _tempDirLoader = tempDirLoader;

  final http.Client? _client;
  final Future<Directory> Function()? _tempDirLoader;

  /// 登录后的 Cookie 等请求头。
  final Map<String, String> headers;
  final int threads;
  final Duration timeout;

  /// 0 表示不限速；>0 时按字节/秒在每次写入后补齐等待时间。
  final int speedLimitBytesPerSecond;

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  Future<DownloadedFile> download(
    String url, {
    String? name,
    void Function(int done, int total)? onProgress,
    String? tempKey,
    bool Function()? isCanceled,
  }) async {
    final client = _client ?? http.Client();
    final uri = Uri.parse(url);
    // 调用方传入的 Referer / UA 优先：B站、Pixiv 的 CDN 只认平台自己的来源，
    // 用 CDN 域名做 Referer 会直接 403。
    final headers = <String, String>{
      'User-Agent': _ua,
      'Referer': uri.origin,
      ...this.headers,
    };
    try {
      final dir = await (_tempDirLoader ?? _systemTemp)();
      final safe = _safeName(name ?? uri.pathSegments.lastOrNull ?? 'download');
      // 固定 tempKey 让「暂停 → 继续」能落在同一个临时文件上，从而续传而不是重下。
      final stamp = tempKey == null || tempKey.isEmpty
          ? '${DateTime.now().microsecondsSinceEpoch}'
          : tempKey;
      final file = File(p.join(dir.path, 'xmt_${stamp}_$safe'));

      final probe = await _probe(client, uri, headers);
      final total = probe.length;
      if (total == null || total <= 0 || !probe.supportsRange) {
        final written = await _singleStream(
          client,
          uri,
          headers,
          file,
          onProgress,
          isCanceled,
        );
        return DownloadedFile(file: file, bytes: written);
      }

      final existing = await file.exists() ? await file.length() : 0;
      if (existing >= total) {
        onProgress?.call(total, total);
        return DownloadedFile(file: file, bytes: total);
      }

      var done = existing;
      onProgress?.call(done, total);
      final ranges = _split(existing, total, threads);
      final results = await Future.wait<bool>(
        ranges.map(
          (range) => _fillRange(
            client,
            uri,
            headers,
            file.path,
            range,
            (chunk) {
              done += chunk;
              onProgress?.call(done, total);
            },
            isCanceled,
          ),
        ),
      );
      if (results.any((ok) => !ok)) {
        // 有分片拿到 200（服务端忽略 Range）：整文件重下，避免拼接出坏文件。
        if (await file.exists()) await file.delete();
        final written = await _singleStream(
          client,
          uri,
          headers,
          file,
          onProgress,
          isCanceled,
        );
        return DownloadedFile(file: file, bytes: written);
      }
      return DownloadedFile(file: file, bytes: await file.length());
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<_Probe> _probe(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      final response =
          await client.head(uri, headers: headers).timeout(timeout);
      return _Probe(
        int.tryParse(response.headers['content-length'] ?? ''),
        (response.headers['accept-ranges'] ?? '').toLowerCase().contains('bytes'),
      );
    } catch (_) {
      return const _Probe(null, false);
    }
  }

  static List<_ByteRange> _split(int start, int total, int requested) {
    final count = requested.clamp(1, 16);
    final remaining = total - start;
    final chunk = (remaining / count).ceil();
    final out = <_ByteRange>[];
    for (var offset = start; offset < total; offset += chunk) {
      out.add(_ByteRange(offset, (offset + chunk - 1).clamp(0, total - 1)));
    }
    return out;
  }

  /// 返回 false 表示服务端忽略了 Range，需要整文件重下。
  Future<bool> _fillRange(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
    String path,
    _ByteRange range,
    void Function(int chunk) report,
    bool Function()? isCanceled,
  ) async {
    final raf = await File(path).open(mode: FileMode.writeOnly);
    try {
      await raf.setPosition(range.start);
      final request = http.Request('GET', uri)
        ..headers.addAll(<String, String>{
          ...headers,
          'Range': 'bytes=${range.start}-${range.end}',
        });
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode != 206) {
        await response.stream.drain<void>();
        return false;
      }
      final watch = Stopwatch()..start();
      await for (final chunk in response.stream) {
        await raf.writeFrom(chunk);
        report(chunk.length);
        if (isCanceled?.call() ?? false) {
          throw const DownloadCanceledException();
        }
        await _throttle(chunk.length, watch);
      }
      return true;
    } finally {
      await raf.close();
    }
  }

  Future<int> _singleStream(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
    File file,
    void Function(int done, int total)? onProgress,
    bool Function()? isCanceled,
  ) async {
    final raf = await file.open(mode: FileMode.writeOnly);
    var written = 0;
    final watch = Stopwatch()..start();
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode >= 400) {
        await response.stream.drain<void>();
        throw StateError('HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? -1;
      await for (final chunk in response.stream) {
        await raf.writeFrom(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
        if (isCanceled?.call() ?? false) {
          throw const DownloadCanceledException();
        }
        await _throttle(chunk.length, watch);
      }
      return written;
    } finally {
      await raf.close();
    }
  }

  Future<void> _throttle(int bytes, Stopwatch watch) async {
    final limit = speedLimitBytesPerSecond;
    if (limit <= 0 || bytes <= 0) return;
    final expected =
        Duration(microseconds: (bytes * 1000000 / limit).round());
    final elapsed = watch.elapsed;
    if (expected > elapsed) {
      await Future<void>.delayed(expected - elapsed);
    }
    watch
      ..reset()
      ..start();
  }

  static String _safeName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
    if (cleaned.isEmpty) return 'download';
    return cleaned.substring(0, cleaned.length.clamp(0, 80));
  }

  static Future<Directory> _systemTemp() async => Directory.systemTemp;
}

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;
}
