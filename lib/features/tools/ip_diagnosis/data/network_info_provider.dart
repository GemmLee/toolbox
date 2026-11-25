import 'dart:io';

import 'package:flutter/services.dart';

import 'ip_models.dart';

/// 读取系统网络信息。
///
/// 优先走原生 MethodChannel `toolbox/device_status` 的 `networkInfo`；
/// 在非 Android / 测试环境（抛 `MissingPluginException` / `PlatformException`）
/// 回退到 `dart:io` 的 `NetworkInterface.list`，只保留本机地址与接口名，
/// 其余字段保持未知，并标记 `systemAvailable = false`。
///
/// [invoke] 可注入，widget 测试可直接给一份假数据。
class NetworkInfoProvider {
  NetworkInfoProvider({Future<Map<String, dynamic>> Function()? invoke})
      : _invoke = invoke ?? _invokeChannel;

  final Future<Map<String, dynamic>> Function() _invoke;

  static const MethodChannel _channel =
      MethodChannel('toolbox/device_status');

  static Future<Map<String, dynamic>> _invokeChannel() async {
    final raw = await _channel.invokeMethod<dynamic>('networkInfo');
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw PlatformException(code: 'BAD_FORMAT', message: '返回格式异常');
  }

  Future<NetworkInfo> fetch() async {
    try {
      return NetworkInfo.fromMap(await _invoke());
    } on MissingPluginException {
      return _fallback();
    } on PlatformException {
      return _fallback();
    } catch (_) {
      return _fallback();
    }
  }

  Future<NetworkInfo> _fallback() async {
    final addresses = <String>[];
    final interfaces = <String>[];
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.any,
      );
      for (final interface in list) {
        interfaces.add(interface.name);
        for (final address in interface.addresses) {
          addresses.add(address.address);
        }
      }
    } catch (_) {
      // 读不到就保持空列表，由 UI 显示不可用，不让页面崩掉。
    }
    return NetworkInfo(
      systemAvailable: false,
      localAddresses: List<String>.unmodifiable(addresses),
      interfaceNames: List<String>.unmodifiable(interfaces),
    );
  }
}
