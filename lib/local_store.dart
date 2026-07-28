import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_models.dart';

class LocalStore {
  static const _labelsKey = 'record_horus.labels.v1';
  static const _recordingsKey = 'record_horus.recordings.v1';

  Future<List<LabelItem>> loadLabels() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_labelsKey);
    if (raw == null || raw.isEmpty) {
      return const [LabelItem(id: 'default', name: 'Chung')];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [LabelItem(id: 'default', name: 'Chung')];
    }

    final labels = decoded
        .whereType<Map>()
        .map((json) => LabelItem.fromJson(Map<String, Object?>.from(json)))
        .where((label) => label.id.isNotEmpty && label.name.trim().isNotEmpty)
        .toList();

    if (labels.isEmpty) {
      return const [LabelItem(id: 'default', name: 'Chung')];
    }
    return labels;
  }

  Future<void> saveLabels(List<LabelItem> labels) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(labels.map((label) => label.toJson()).toList());
    await prefs.setString(_labelsKey, raw);
  }

  Future<List<RecordingItem>> loadRecordings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recordingsKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }

    return decoded
        .whereType<Map>()
        .map((json) => RecordingItem.fromJson(Map<String, Object?>.from(json)))
        .where((item) => item.id.isNotEmpty && item.filePath.isNotEmpty)
        .toList();
  }

  Future<void> saveRecordings(List<RecordingItem> recordings) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(recordings.map((item) => item.toJson()).toList());
    await prefs.setString(_recordingsKey, raw);
  }
}

class HorusSettingsStore {
  HorusSettingsStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secureStorage = secureStorage;

  static const _settingsKey = 'record_horus.horus_settings.v1';
  static const _passwordKey = 'record_horus.horus_password.v1';

  final FlutterSecureStorage _secureStorage;

  Future<HorusSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    final saved = raw == null || raw.isEmpty
        ? HorusSettings.defaults()
        : HorusSettings.fromJson(Map<String, Object?>.from(jsonDecode(raw)));

    String password = defaultHorusPassword;
    try {
      password = await _secureStorage.read(key: _passwordKey) ?? password;
    } catch (_) {
      password = defaultHorusPassword;
    }

    return saved.copyWith(password: password);
  }

  Future<void> save(HorusSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));

    try {
      final password = settings.password.trim();
      if (password.isEmpty) {
        await _secureStorage.delete(key: _passwordKey);
      } else {
        await _secureStorage.write(key: _passwordKey, value: password);
      }
    } catch (_) {
      // The app can still run locally when secure storage is unavailable.
    }
  }
}
