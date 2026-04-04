import 'package:demo_ai_even/services/glance_source.dart';
import 'package:flutter/services.dart';

/// Recent notification snippets from the native notification buffer.
class NotificationSource implements GlanceSource {
  static const _channel = MethodChannel('method.notifications');

  @override
  String get name => 'notifications';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => Duration.zero; // always fresh

  @override
  Future<String?> fetch() async {
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('getRecentNotifications');
      if (result == null || result.isEmpty) return null;

      final snippets = result
          .cast<String>()
          .take(3)
          .map((s) => '- $s');

      return 'Notifications:\n${snippets.join('\n')}';
    } on MissingPluginException {
      // Native side not registered yet.
      return null;
    } catch (e) {
      print('NotificationSource error: $e');
      return null;
    }
  }
}
