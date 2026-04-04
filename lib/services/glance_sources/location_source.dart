import 'package:demo_ai_even/services/glance_source.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

class LocationSource implements GlanceSource {
  @override
  String get name => 'location';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => const Duration(seconds: 60);

  @override
  Future<String?> fetch() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      final requested = await Geolocator.requestPermission();
      if (requested == LocationPermission.denied ||
          requested == LocationPermission.deniedForever) {
        return null;
      }
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
    );

    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final parts = [p.subLocality, p.locality, p.administrativeArea]
            .where((s) => s != null && s.isNotEmpty);
        return 'Location: ${parts.join(', ')}';
      }
    } catch (_) {
      // Reverse geocode failed — fall back to coordinates.
    }

    return 'Location: ${position.latitude.toStringAsFixed(2)}, '
        '${position.longitude.toStringAsFixed(2)}';
  }
}
