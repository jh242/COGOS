import 'package:demo_ai_even/services/glance_source.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WeatherSource implements GlanceSource {
  @override
  String get name => 'weather';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => const Duration(minutes: 15);

  @override
  Future<String?> fetch() async {
    const envKey = String.fromEnvironment('OPENWEATHER_API_KEY');
    final apiKey = envKey.isNotEmpty
        ? envKey
        : (await SharedPreferences.getInstance())
                .getString('openweather_api_key') ??
            '';

    if (apiKey.isEmpty) return null;

    // Use last known position to avoid a fresh GPS fix.
    final position = await Geolocator.getLastKnownPosition() ??
        await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.low);

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ));

    final response = await dio.get<Map<String, dynamic>>(
      'https://api.openweathermap.org/data/2.5/weather',
      queryParameters: {
        'lat': position.latitude,
        'lon': position.longitude,
        'appid': apiKey,
        'units': 'imperial',
      },
    );

    final data = response.data;
    if (data == null) return null;

    final temp = (data['main']?['temp'] as num?)?.round();
    final desc = (data['weather'] as List?)?.firstOrNull;
    final condition = desc?['main'] as String? ?? '';

    return 'Weather: ${temp}F $condition';
  }
}
