import 'dart:io';

import 'package:demo_ai_even/services/glance_source.dart';
import 'package:flutter/services.dart';

/// Transit departures via Apple MapKit (iOS only).
/// Returns `null` on Android.
class TransitSource implements GlanceSource {
  static const _channel = MethodChannel('method.transit');

  @override
  String get name => 'transit';

  @override
  bool get enabled => Platform.isIOS;

  @override
  Duration get cacheDuration => const Duration(minutes: 2);

  @override
  Future<String?> fetch() async {
    if (!Platform.isIOS) return null;

    try {
      final result = await _channel.invokeMethod<String>('getNearbyDepartures');
      if (result == null || result.isEmpty) return null;
      return 'Transit: $result';
    } on MissingPluginException {
      // Native side not registered yet.
      return null;
    } catch (e) {
      print('TransitSource error: $e');
      return null;
    }
  }
}
