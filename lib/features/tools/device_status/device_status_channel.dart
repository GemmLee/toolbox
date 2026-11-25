import 'package:flutter/services.dart';

/// MethodChannel 侧的数据模型与解析。
///
/// 全部字段做了防御式解析：任何类型不符都回退默认值，避免原生端
/// 个别机型字段缺失导致崩溃。

class DeviceStaticInfo {
  const DeviceStaticInfo({
    required this.model,
    required this.manufacturer,
    required this.brand,
    required this.device,
    required this.product,
    required this.hardware,
    required this.board,
    required this.sdkInt,
    required this.release,
    required this.kernel,
    required this.uptimeMs,
    required this.refreshRate,
  });

  final String model;
  final String manufacturer;
  final String brand;
  final String device;
  final String product;
  final String hardware;
  final String board;
  final int sdkInt;
  final String release;
  final String kernel;
  final int uptimeMs;
  final double refreshRate;

  factory DeviceStaticInfo.fromMap(Map<dynamic, dynamic> map) {
    String str(String key) => (map[key] as String?) ?? '';
    return DeviceStaticInfo(
      model: str('model'),
      manufacturer: str('manufacturer'),
      brand: str('brand'),
      device: str('device'),
      product: str('product'),
      hardware: str('hardware'),
      board: str('board'),
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      release: str('release'),
      kernel: str('kernel'),
      uptimeMs: (map['uptimeMs'] as num?)?.toInt() ?? 0,
      refreshRate: (map['refreshRate'] as num?)?.toDouble() ?? 60,
    );
  }
}

/// 单核快照：ticks 来自 /proc/stat，顺序为
/// user nice system idle iowait irq softirq steal。
class CoreSnapshot {
  const CoreSnapshot({
    required this.index,
    required this.curFreq,
    required this.minFreq,
    required this.maxFreq,
    required this.ticks,
  });

  final int index;
  final int curFreq;
  final int minFreq;
  final int maxFreq;
  final List<int> ticks;

  factory CoreSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final ticks = (map['ticks'] as List?)
            ?.map((e) => (e as num?)?.toInt() ?? 0)
            .toList() ??
        List<int>.filled(8, 0);
    return CoreSnapshot(
      index: (map['index'] as num?)?.toInt() ?? 0,
      curFreq: (map['curFreq'] as num?)?.toInt() ?? 0,
      minFreq: (map['minFreq'] as num?)?.toInt() ?? 0,
      maxFreq: (map['maxFreq'] as num?)?.toInt() ?? 0,
      ticks: ticks.length == 8 ? ticks : List<int>.filled(8, 0),
    );
  }
}

class DeviceSnapshot {
  const DeviceSnapshot({
    required this.ramTotal,
    required this.ramAvail,
    required this.swapTotal,
    required this.swapFree,
    required this.storageTotal,
    required this.storageFree,
    required this.batteryLevel,
    required this.batteryTemp,
    required this.batteryVoltageMv,
    required this.batteryStatus,
    required this.batteryPlugged,
    required this.batteryCurrentUa,
    required this.cpuTemp,
    required this.cores,
    required this.framesDelta,
    required this.framesElapsedMs,
  });

  final int ramTotal;
  final int ramAvail;
  final int swapTotal;
  final int swapFree;
  final int storageTotal;
  final int storageFree;
  final double batteryLevel;
  final double batteryTemp;
  final int batteryVoltageMv;
  final int batteryStatus;
  final int batteryPlugged;
  final int batteryCurrentUa;

  /// CPU/SoC 温区最高温度（℃），读不到为 0。
  final double cpuTemp;
  final List<CoreSnapshot> cores;
  final int framesDelta;
  final int framesElapsedMs;

  factory DeviceSnapshot.fromMap(Map<dynamic, dynamic> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return DeviceSnapshot(
      ramTotal: intOf('ramTotal'),
      ramAvail: intOf('ramAvail'),
      swapTotal: intOf('swapTotal'),
      swapFree: intOf('swapFree'),
      storageTotal: intOf('storageTotal'),
      storageFree: intOf('storageFree'),
      batteryLevel: (map['batteryLevel'] as num?)?.toDouble() ?? -1,
      batteryTemp: (map['batteryTemp'] as num?)?.toDouble() ?? 0,
      batteryVoltageMv: intOf('batteryVoltageMv'),
      batteryStatus: intOf('batteryStatus'),
      batteryPlugged: intOf('batteryPlugged'),
      batteryCurrentUa: intOf('batteryCurrentUa'),
      cpuTemp: (map['cpuTemp'] as num?)?.toDouble() ?? 0,
      cores: (map['cores'] as List? ?? const [])
          .whereType<Map>()
          .map(CoreSnapshot.fromMap)
          .toList(growable: false),
      framesDelta: intOf('framesDelta'),
      framesElapsedMs: intOf('framesElapsedMs'),
    );
  }
}

/// 相邻两次采样之间的单核占用率（0~1）；无法计算时返回 -1。
double coreUsage(CoreSnapshot? previous, CoreSnapshot current) {
  if (previous == null) return -1;
  int totalOf(List<int> t) => t.fold(0, (sum, v) => sum + v);
  final deltaTotal = totalOf(current.ticks) - totalOf(previous.ticks);
  if (deltaTotal <= 0) return -1;
  final deltaIdle = (current.ticks[3] + current.ticks[4]) -
      (previous.ticks[3] + previous.ticks[4]);
  final usage = (deltaTotal - deltaIdle) / deltaTotal;
  return usage.clamp(0.0, 1.0).toDouble();
}

class DeviceStatusChannel {
  DeviceStatusChannel._();

  static const MethodChannel _channel = MethodChannel('toolbox/device_status');

  static Future<DeviceStaticInfo?> staticInfo() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('staticInfo');
      if (raw is Map) return DeviceStaticInfo.fromMap(raw);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<DeviceSnapshot?> snapshot() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('snapshot');
      if (raw is Map) return DeviceSnapshot.fromMap(raw);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<BatteryDetail?> batteryDetail() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('batteryDetail');
      if (raw is Map) return BatteryDetail.fromMap(raw);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<CpuDetail?> cpuDetail() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('cpuDetail');
      if (raw is Map) return CpuDetail.fromMap(raw);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<MemoryDetail?> memoryDetail() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('memoryDetail');
      if (raw is Map) return MemoryDetail.fromMap(raw);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<List<StoragePartition>?> storageDetail() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('storageDetail');
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(StoragePartition.fromMap)
            .toList(growable: false);
      }
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// 电池详情（部分字段依赖厂商 sysfs，读不到为 0 / -1）。
class BatteryDetail {
  const BatteryDetail({
    required this.level,
    required this.temperature,
    required this.voltageMv,
    required this.status,
    required this.plugged,
    required this.health,
    required this.technology,
    required this.chargeCounterUah,
    required this.capacityPercent,
    required this.currentNowUa,
    required this.currentAvgUa,
    required this.chargeFullUah,
    required this.chargeFullDesignUah,
    required this.cycleCount,
    this.chargeType = '',
    this.powerNowMw = 0,
    this.energyCounterNwh = 0,
  });

  final double level;
  final double temperature;
  final int voltageMv;
  final int status;
  final int plugged;
  final int health;
  final String technology;
  final int chargeCounterUah;
  final int capacityPercent;
  final int currentNowUa;
  final int currentAvgUa;
  final int chargeFullUah;
  final int chargeFullDesignUah;
  final int cycleCount;

  /// 厂商充电协议名（如 PD/PPS/QC3），读不到为空。
  final String chargeType;

  /// sysfs power_now（mW），读不到为 0。
  final int powerNowMw;

  /// 系统能量计数（nWh），读不到为 0。
  final int energyCounterNwh;

  factory BatteryDetail.fromMap(Map<dynamic, dynamic> map) {
    // 私有接口 / sysfs 返回值可能是数字字符串，宽松解析避免脏数据打挂详情页。
    num? numOf(String key) {
      final raw = map[key];
      if (raw is num) return raw;
      if (raw is String) return num.tryParse(raw.trim());
      return null;
    }

    int intOf(String key) => numOf(key)?.toInt() ?? 0;
    double doubleOf(String key, [double fallback = 0]) =>
        numOf(key)?.toDouble() ?? fallback;
    return BatteryDetail(
      level: doubleOf('level', -1),
      temperature: doubleOf('temperature'),
      voltageMv: intOf('voltageMv'),
      status: intOf('status'),
      plugged: intOf('plugged'),
      health: intOf('health'),
      technology: map['technology']?.toString() ?? '',
      chargeCounterUah: intOf('chargeCounterUah'),
      capacityPercent: intOf('capacityPercent'),
      currentNowUa: intOf('currentNowUa'),
      currentAvgUa: intOf('currentAvgUa'),
      chargeFullUah: intOf('chargeFullUah'),
      chargeFullDesignUah: intOf('chargeFullDesignUah'),
      cycleCount: intOf('cycleCount'),
      chargeType: map['chargeType']?.toString() ?? '',
      powerNowMw: intOf('powerNowMw'),
      energyCounterNwh: intOf('energyCounterNwh'),
    );
  }
}

/// 单个 CPU 核心的静态与当前状态。
class CpuCoreDetail {
  const CpuCoreDetail({
    required this.index,
    required this.curFreq,
    required this.minFreq,
    required this.maxFreq,
    required this.governor,
    required this.online,
    required this.freqs,
  });

  final int index;
  final int curFreq;
  final int minFreq;
  final int maxFreq;
  final String governor;
  final bool online;

  /// 可用频率档（Hz，升序）；部分机型不暴露，为空表示未知。
  final List<int> freqs;

  factory CpuCoreDetail.fromMap(Map<dynamic, dynamic> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return CpuCoreDetail(
      index: intOf('index'),
      curFreq: intOf('curFreq'),
      minFreq: intOf('minFreq'),
      maxFreq: intOf('maxFreq'),
      governor: (map['governor'] as String?) ?? '',
      online: (map['online'] as bool?) ?? true,
      freqs: (map['freqs'] as List? ?? const [])
          .map((e) => (e as num?)?.toInt() ?? 0)
          .where((e) => e > 0)
          .toList(growable: false),
    );
  }
}

/// 一个温度传感器。
class ThermalZone {
  const ThermalZone({required this.name, required this.temp});

  final String name;
  final double temp;

  factory ThermalZone.fromMap(Map<dynamic, dynamic> map) => ThermalZone(
        name: (map['name'] as String?) ?? '',
        temp: (map['temp'] as num?)?.toDouble() ?? 0,
      );
}

/// CPU 详情（核心状态 + 温度 + SoC 信息）。
class CpuDetail {
  const CpuDetail({
    required this.cores,
    required this.thermal,
    required this.abi,
    required this.soc,
    required this.socManufacturer,
  });

  final List<CpuCoreDetail> cores;
  final List<ThermalZone> thermal;
  final String abi;
  final String soc;
  final String socManufacturer;

  /// 最高温度（℃）；无传感器时为 0。
  double get maxTemp {
    if (thermal.isEmpty) return 0;
    return thermal.map((t) => t.temp).reduce((a, b) => a > b ? a : b);
  }

  factory CpuDetail.fromMap(Map<dynamic, dynamic> map) => CpuDetail(
        cores: (map['cores'] as List? ?? const [])
            .whereType<Map>()
            .map(CpuCoreDetail.fromMap)
            .toList(growable: false),
        thermal: (map['thermal'] as List? ?? const [])
            .whereType<Map>()
            .map(ThermalZone.fromMap)
            .toList(growable: false),
        abi: (map['abi'] as String?) ?? '',
        soc: (map['soc'] as String?) ?? '',
        socManufacturer: (map['socManufacturer'] as String?) ?? '',
      );
}

/// /proc/meminfo 关键字段（单位：字节，缺失为 0）。
class MemoryDetail {
  const MemoryDetail({
    required this.memTotal,
    required this.memFree,
    required this.memAvailable,
    required this.buffers,
    required this.cached,
    required this.swapTotal,
    required this.swapFree,
    required this.swapCached,
    required this.slab,
    required this.sReclaimable,
    required this.shmem,
    required this.zramDisksize,
    required this.zramUsed,
  });

  final int memTotal;
  final int memFree;
  final int memAvailable;
  final int buffers;
  final int cached;
  final int swapTotal;
  final int swapFree;
  final int swapCached;
  final int slab;
  final int sReclaimable;
  final int shmem;
  final int zramDisksize;
  final int zramUsed;

  factory MemoryDetail.fromMap(Map<dynamic, dynamic> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return MemoryDetail(
      memTotal: intOf('MemTotal'),
      memFree: intOf('MemFree'),
      memAvailable: intOf('MemAvailable'),
      buffers: intOf('Buffers'),
      cached: intOf('Cached'),
      swapTotal: intOf('SwapTotal'),
      swapFree: intOf('SwapFree'),
      swapCached: intOf('SwapCached'),
      slab: intOf('Slab'),
      sReclaimable: intOf('SReclaimable'),
      shmem: intOf('Shmem'),
      zramDisksize: intOf('zramDisksize'),
      zramUsed: intOf('zramUsed'),
    );
  }
}

/// 单个存储分区/挂载点。
class StoragePartition {
  const StoragePartition({
    required this.id,
    required this.path,
    required this.total,
    required this.free,
  });

  final String id;
  final String path;
  final int total;
  final int free;

  factory StoragePartition.fromMap(Map<dynamic, dynamic> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return StoragePartition(
      id: (map['id'] as String?) ?? '',
      path: (map['path'] as String?) ?? '',
      total: intOf('total'),
      free: intOf('free'),
    );
  }
}
