import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 的薄封装：统一以 JSON 文本存取，避免各处重复解析逻辑。
class LocalStore {
  LocalStore._();

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<Map<String, dynamic>?> readMap(String key) async {
    final prefs = await _prefs;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> writeMap(String key, Map<String, dynamic> value) async {
    final prefs = await _prefs;
    await prefs.setString(key, jsonEncode(value));
  }

  static Future<void> remove(String key) async {
    final prefs = await _prefs;
    await prefs.remove(key);
  }
}
