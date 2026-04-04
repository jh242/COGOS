import 'dart:async';

import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/glance_source.dart';
import 'package:demo_ai_even/services/glance_sources/calendar_source.dart';
import 'package:demo_ai_even/services/glance_sources/location_source.dart';
import 'package:demo_ai_even/services/glance_sources/news_source.dart';
import 'package:demo_ai_even/services/glance_sources/notification_source.dart';
import 'package:demo_ai_even/services/glance_sources/transit_source.dart';
import 'package:demo_ai_even/services/glance_sources/weather_source.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Orchestrates the context-aware glance screen.
///
/// On head-up, instantly displays cached contextual info on the glasses.
/// A 60 s background timer refreshes the cache by gathering data from
/// pluggable [GlanceSource]s and asking Claude Haiku to pick the most
/// relevant 5 lines.
class GlanceService {
  static GlanceService? _instance;
  static GlanceService get get => _instance ??= GlanceService._();

  GlanceService._();

  final List<GlanceSource> _sources = [];
  List<String> _cachedLines = [];
  Timer? _refreshTimer;
  Timer? _dismissTimer;
  bool isShowing = false;
  bool _isRefreshing = false;

  /// Per-source cache: name → (data, fetchedAt).
  final Map<String, (String, DateTime)> _sourceCache = {};

  /// Register all data sources. Call once at app startup.
  void init() {
    _sources.clear();
    _sources.addAll([
      LocationSource(),
      CalendarSource(),
      WeatherSource(),
      TransitSource(),
      NotificationSource(),
      NewsSource(),
    ]);
  }

  // ── Timer lifecycle ────────────────────────────────────────────────

  /// Start the 60 s periodic refresh. Fires immediately on first tick.
  void startTimer() {
    stopTimer();
    refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      refresh();
    });
  }

  /// Stop the background refresh timer.
  void stopTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  // ── Refresh ────────────────────────────────────────────────────────

  /// Gather data from all enabled sources, call Haiku, cache result.
  Future<void> refresh() async {
    if (_isRefreshing) return;
    _isRefreshing = true;

    try {
      final snippets = <String>[];
      final now = DateTime.now();

      for (final source in _sources) {
        if (!source.enabled) continue;

        // Check per-source cache.
        final cached = _sourceCache[source.name];
        if (cached != null &&
            source.cacheDuration > Duration.zero &&
            now.difference(cached.$2) < source.cacheDuration) {
          snippets.add(cached.$1);
          continue;
        }

        try {
          final data = await source.fetch();
          if (data != null && data.isNotEmpty) {
            _sourceCache[source.name] = (data, now);
            snippets.add(data);
          }
        } catch (e) {
          print('GlanceSource "${source.name}" fetch error: $e');
        }
      }

      if (snippets.isEmpty) {
        _cachedLines = ['No data available'];
        return;
      }

      _cachedLines = await _callHaiku(snippets.join('\n'));
    } catch (e) {
      print('GlanceService refresh error: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  // ── Display ────────────────────────────────────────────────────────

  /// Show cached glance on the glasses. Instant — no network call.
  Future<void> showGlance() async {
    if (EvenAI.isRunning) return;

    final lines =
        _cachedLines.isNotEmpty ? _cachedLines : ['Glance loading...'];
    await _sendToGlasses(lines);
    isShowing = true;

    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 5), () {
      dismiss();
    });
  }

  /// Force refresh then show (for double-tap).
  Future<void> forceRefreshAndShow() async {
    if (EvenAI.isRunning) return;

    await _sendToGlasses(['Refreshing...']);
    isShowing = true;

    _sourceCache.clear();
    await refresh();
    await _sendToGlasses(
        _cachedLines.isNotEmpty ? _cachedLines : ['No data available']);

    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 5), () {
      dismiss();
    });
  }

  /// Dismiss the glance display.
  void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    isShowing = false;
    Proto.exit();
  }

  /// Send up to 5 lines to the glasses using the 0x4E / 0x70 text-show
  /// protocol. Bypasses EvenAI.isRunning by calling Proto directly.
  Future<void> _sendToGlasses(List<String> lines) async {
    final measured = <String>[];
    for (final line in lines) {
      measured.addAll(EvenAIDataMethod.measureStringList(line));
    }
    final first5 = measured.length > 5 ? measured.sublist(0, 5) : measured;

    final padCount = 5 - first5.length;
    final padLines = List.filled(padCount, ' \n');
    final contentLines = first5.map((l) => '$l\n');
    final screen = [...padLines, ...contentLines].join();

    await Proto.sendEvenAIData(
      screen,
      newScreen: EvenAIDataMethod.transferToNewScreen(0x01, 0x70),
      pos: 0,
      current_page_num: 1,
      max_page_num: 1,
    );
  }

  // ── Haiku API ──────────────────────────────────────────────────────

  Future<List<String>> _callHaiku(String contextData) async {
    const envKey = String.fromEnvironment('ANTHROPIC_API_KEY');
    final apiKey = envKey.isNotEmpty
        ? envKey
        : (await SharedPreferences.getInstance())
                .getString('anthropic_api_key') ??
            '';

    if (apiKey.isEmpty) {
      return ['No API key set', 'Add key in Settings'];
    }

    const systemPrompt =
        'You are a smart glasses HUD. Output exactly 5 lines, max 23 chars '
        'each. Show the most relevant info right now. Prioritize '
        'urgent/time-sensitive items, then contextual info, then '
        'notifications. Be terse. No markdown.';

    final body = {
      'model': 'claude-haiku-4-5-20251001',
      'max_tokens': 100,
      'system': systemPrompt,
      'messages': [
        {'role': 'user', 'content': contextData},
      ],
    };

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
    ));

    try {
      final response = await dio.post<Map<String, dynamic>>(
        'https://api.anthropic.com/v1/messages',
        data: body,
      );

      final content = response.data?['content'] as List<dynamic>?;
      if (content == null || content.isEmpty) {
        return ['No response'];
      }

      final text = content[0]['text'] as String? ?? '';
      final lines = text
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .take(5)
          .toList();

      return lines.isNotEmpty ? lines : ['No response'];
    } on DioException catch (e) {
      print('Haiku API error: ${e.message}');
      return ['Glance unavailable'];
    }
  }
}
