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

  late SharedPreferences _prefs;
  List<String> _whitelist = [];

  /// Load persisted whitelist from prefs. Call once at app startup.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = _prefs.getString(_prefsKey);
    if (stored != null) {
      try {
        _whitelist = (jsonDecode(stored) as List).cast<String>();
      } catch (_) {
        _whitelist = [];
      }
    }
  }

  /// Update the app whitelist. Empty list = allow all apps.
  /// Saves to prefs immediately; pushes to glasses in the background.
  Future<void> setWhitelist(List<String> appIds) async {
    _whitelist = List.from(appIds);
    await _prefs.setString(_prefsKey, jsonEncode(_whitelist));
    pushWhitelistToGlasses(); // fire-and-forget — doesn't block UI
  }

  /// Push current whitelist to glasses. Called on connect and after setWhitelist.
  Future<void> pushWhitelistToGlasses() async {
    if (!BleManager.get().isConnected) return;
    final model = NotifyWhitelistModel(
      _whitelist.map((id) => NotifyAppModel(id, id)).toList(),
    );
    await Proto.sendNewAppWhiteListJson(model.toJson());
  }

  List<String> get whitelist => List.unmodifiable(_whitelist);
}
