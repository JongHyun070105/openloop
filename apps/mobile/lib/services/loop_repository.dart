import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/open_loop.dart';

abstract interface class LoopRepository {
  Future<List<OpenLoop>> load();
  Future<void> save(List<OpenLoop> loops);
  Future<String?> loadBaseUrl();
  Future<void> saveBaseUrl(String value);
  Future<RetentionPolicy> loadRetention();
  Future<void> saveRetention(RetentionPolicy value);
}

class SharedPreferencesLoopRepository implements LoopRepository {
  static const _loopsKey = 'open_loops_v1';
  static const _baseUrlKey = 'api_base_url';
  static const _retentionKey = 'retention_policy';

  @override
  Future<List<OpenLoop>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_loopsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((item) => OpenLoop.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<OpenLoop> loops) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _loopsKey,
      jsonEncode(loops.map((loop) => loop.toJson()).toList()),
    );
  }

  @override
  Future<String?> loadBaseUrl() async =>
      (await SharedPreferences.getInstance()).getString(_baseUrlKey);

  @override
  Future<void> saveBaseUrl(String value) async =>
      (await SharedPreferences.getInstance()).setString(
        _baseUrlKey,
        value.trim(),
      );

  @override
  Future<RetentionPolicy> loadRetention() async {
    final value = (await SharedPreferences.getInstance()).getString(
      _retentionKey,
    );
    return RetentionPolicy.values
            .where((item) => item.name == value)
            .firstOrNull ??
        RetentionPolicy.sevenDays;
  }

  @override
  Future<void> saveRetention(RetentionPolicy value) async =>
      (await SharedPreferences.getInstance()).setString(
        _retentionKey,
        value.name,
      );
}

class MemoryLoopRepository implements LoopRepository {
  List<OpenLoop> loops = [];
  String? baseUrl;
  RetentionPolicy retention = RetentionPolicy.sevenDays;

  @override
  Future<List<OpenLoop>> load() async => List.of(loops);
  @override
  Future<void> save(List<OpenLoop> value) async => loops = List.of(value);
  @override
  Future<String?> loadBaseUrl() async => baseUrl;
  @override
  Future<void> saveBaseUrl(String value) async => baseUrl = value;
  @override
  Future<RetentionPolicy> loadRetention() async => retention;
  @override
  Future<void> saveRetention(RetentionPolicy value) async => retention = value;
}
