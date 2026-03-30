import 'dart:convert';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/notify_model.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static NotificationService? _instance;
  static NotificationService get get => _instance ??= NotificationService._();
  NotificationService._();

  static const _eventChannel = EventChannel('eventNotificationReceive');
  static const _prefsKey = 'notification_whitelist';

  List<String> _whitelist = [];
  int _notifyId = 0;

  /// Start listening for phone notifications and forwarding them to glasses.
  /// Call once at app startup.
  Future<void> startListening() async {
    await _loadWhitelist();
    _eventChannel.receiveBroadcastStream().listen((event) {
      final notify = NotifyModel.fromJson(jsonEncode(event));
      if (notify == null) return;
      if (_whitelist.isEmpty || _whitelist.contains(notify.appIdentifier)) {
        _forwardToGlasses(notify);
      }
    }, onError: (error) {
      print('NotificationService: EventChannel error: $error');
    });
  }

  Future<void> _forwardToGlasses(NotifyModel notify) async {
    if (!BleManager.get().isConnected) return;
    final id = _notifyId & 0xFF;
    _notifyId++;
    await Proto.sendNotify(notify.toMap(), id);
  }

  /// Update the app whitelist. Empty list = allow all apps.
  Future<void> setWhitelist(List<String> appIds) async {
    _whitelist = List.from(appIds);
    await _saveWhitelist();
    await pushWhitelistToGlasses();
  }

  /// Push current whitelist to glasses (call on connect and after setWhitelist).
  Future<void> pushWhitelistToGlasses() async {
    if (!BleManager.get().isConnected) return;
    final apps = _whitelist
        .map((id) => NotifyAppModel(id, id))
        .toList();
    final model = NotifyWhitelistModel(apps);
    await Proto.sendNewAppWhiteListJson(model.toJson());
  }

  List<String> get whitelist => List.unmodifiable(_whitelist);

  Future<void> _loadWhitelist() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored) as List;
        _whitelist = decoded.cast<String>();
      } catch (_) {
        _whitelist = [];
      }
    }
  }

  Future<void> _saveWhitelist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_whitelist));
  }
}
