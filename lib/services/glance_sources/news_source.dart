import 'package:demo_ai_even/services/glance_source.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NewsSource implements GlanceSource {
  @override
  String get name => 'news';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => const Duration(minutes: 30);

  @override
  Future<String?> fetch() async {
    const envKey = String.fromEnvironment('NEWS_API_KEY');
    final apiKey = envKey.isNotEmpty
        ? envKey
        : (await SharedPreferences.getInstance())
                .getString('news_api_key') ??
            '';

    if (apiKey.isEmpty) return null;

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ));

    final response = await dio.get<Map<String, dynamic>>(
      'https://newsapi.org/v2/top-headlines',
      queryParameters: {
        'country': 'us',
        'pageSize': 3,
        'apiKey': apiKey,
      },
    );

    final data = response.data;
    if (data == null) return null;

    final articles = data['articles'] as List<dynamic>?;
    if (articles == null || articles.isEmpty) return null;

    final headlines = articles
        .take(3)
        .map((a) => '- ${a['title'] ?? 'Untitled'}');

    return 'News:\n${headlines.join('\n')}';
  }
}
