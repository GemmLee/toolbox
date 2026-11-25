import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/app_files.dart';
import '../../core/storage/local_store.dart';
import 'profile_model.dart';

/// 个人信息的本地读写。
///
/// 运行时数据存在 SharedPreferences（读取快、页面到处都在用），同时把同一份
/// JSON 同步成「存储空间 › 个人信息 › 个人信息.json」，这样用户在用户页的
/// 存储空间里能直接看到、预览、导出或删除自己的档案。
class ProfileRepository {
  ProfileRepository._();

  static const String storageKey = 'user_profile';

  /// 在「存储空间 › 个人信息」里的文件名。
  static const String fileName = '个人信息.json';

  static final ValueNotifier<UserProfile?> notifier =
      ValueNotifier<UserProfile?>(null);

  static Future<UserProfile> load() async {
    final json = await LocalStore.readMap(storageKey);
    final profile = UserProfile(json);
    notifier.value = profile;
    return profile;
  }

  /// 读存储空间里的「个人信息.json」（结构化 v2，兼容 v1 扁平格式）。
  ///
  /// 文件不存在或解析失败返回 null，调用方回退到运行时数据。
  static Future<UserProfile?> loadFromFile() async {
    try {
      for (final file in await AppStore.listOf(AppStoreCategory.profile)) {
        if (file.name != fileName) continue;
        final decoded = jsonDecode(await AppStore.readText(file));
        if (decoded is Map<String, dynamic>) {
          return UserProfile.fromStorageJson(decoded);
        }
        if (decoded is Map) {
          return UserProfile.fromStorageJson(
              Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {
      // 文件损坏 / 存储空间不可用时忽略。
    }
    return null;
  }

  static Future<void> save(UserProfile profile) async {
    await LocalStore.writeMap(storageKey, profile.toJson());
    notifier.value = profile;
    unawaited(_syncFile(profile));
  }

  /// 局部更新：读取现有数据 → 应用 [mutate] → 保存。
  ///
  /// 基本信息页与五险一金比例页各自保存时互不覆盖对方的字段。
  static Future<UserProfile> update(
    void Function(Map<String, dynamic> data) mutate,
  ) async {
    final current = await load();
    final data = Map<String, dynamic>.from(current.toJson())
      ..remove('schemaVersion');
    mutate(data);
    final profile = UserProfile(data);
    await save(profile);
    return profile;
  }

  static Future<void> clear() async {
    await LocalStore.remove(storageKey);
    notifier.value = UserProfile();
    unawaited(_deleteFile());
  }

  /// 把已有档案补写进存储空间（老用户升级后第一次打开个人信息时调用）。
  ///
  /// 存储空间不可用时静默跳过，不影响页面。
  static Future<void> syncMirror() async {
    final json = await LocalStore.readMap(storageKey);
    if (json == null || json.isEmpty) return;
    await _syncFile(UserProfile(json));
  }

  /// 让存储空间里的文件与内存数据保持一致：没内容就删文件。
  static Future<void> _syncFile(UserProfile profile) async {
    try {
      if (profile.isEmpty) {
        await _deleteFile();
        return;
      }
      await AppStore.saveText(
        category: AppStoreCategory.profile,
        name: fileName,
        content:
            const JsonEncoder.withIndent('  ').convert(profile.toStorageJson()),
        overwrite: true,
      );
    } catch (_) {
      // 存储空间不可用（如插件未初始化）时忽略：数据已经在 SharedPreferences 里。
    }
  }

  static Future<void> _deleteFile() async {
    try {
      for (final file in await AppStore.listOf(AppStoreCategory.profile)) {
        if (file.name == fileName) await AppStore.delete(file);
      }
    } catch (_) {
      // 忽略：文件不存在时无需处理。
    }
  }
}
