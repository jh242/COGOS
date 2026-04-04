import 'package:demo_ai_even/services/glance_source.dart';
import 'package:device_calendar/device_calendar.dart';

class CalendarSource implements GlanceSource {
  @override
  String get name => 'calendar';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => const Duration(minutes: 5);

  @override
  Future<String?> fetch() async {
    final plugin = DeviceCalendarPlugin();

    final permResult = await plugin.hasPermissions();
    if (permResult.data != true) {
      final reqResult = await plugin.requestPermissions();
      if (reqResult.data != true) return null;
    }

    final calendarsResult = await plugin.retrieveCalendars();
    final calendars = calendarsResult.data;
    if (calendars == null || calendars.isEmpty) return null;

    final now = DateTime.now();
    final endOfTomorrow =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 2));

    final events = <Event>[];
    for (final cal in calendars) {
      final result = await plugin.retrieveEvents(
        cal.id,
        RetrieveEventsParams(startDate: now, endDate: endOfTomorrow),
      );
      if (result.data != null) {
        events.addAll(result.data!);
      }
    }

    // Sort by start time, take next 3.
    events.sort((a, b) =>
        (a.start ?? DateTime(0)).compareTo(b.start ?? DateTime(0)));
    final upcoming = events.take(3).toList();

    if (upcoming.isEmpty) return null;

    final lines = upcoming.map((e) {
      final time = e.start != null
          ? '${e.start!.hour}:${e.start!.minute.toString().padLeft(2, '0')}'
          : '?';
      final title = (e.title ?? 'Untitled');
      return '- $time $title';
    });

    return 'Calendar:\n${lines.join('\n')}';
  }
}
