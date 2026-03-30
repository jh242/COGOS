import 'dart:convert';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/notify_model.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the ANCS notification whitelist for iOS.
///
/// On iOS, notification forwarding to the glasses is handled automatically by
/// the glasses firmware via the Apple Notification Center Service (ANCS) BLE
/// profile — no Flutter-side listener is needed. This service only manages the
/// whitelist that tells the glasses which apps to show notifications from.
class NotificationService {
  static NotificationService? _instance;
  static NotificationService get get => _instance ??= NotificationService._();
  NotificationService._();

  static const _prefsKey = 'notification_whitelist';

  List<String> _whitelist = [];

  /// Load persisted whitelist from prefs. Call once at app startup.
  Future<void> init() async {
    await _loadWhitelist();
  }

  /// Update the app whitelist. Empty list = allow all apps.
  Future<void> setWhitelist(List<String> appIds) async {
    _whitelist = List.from(appIds);
    await _saveWhitelist();
    await pushWhitelistToGlasses();
  }

  /// Push current whitelist to glasses. Call on connect and after setWhitelist.
  Future<void> pushWhitelistToGlasses() async {
    if (!BleManager.get().isConnected) return;
    final apps = _whitelist.map((id) => NotifyAppModel(id, id)).toList();
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
