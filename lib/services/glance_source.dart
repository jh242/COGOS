/// Interface for pluggable glance screen data sources.
///
/// Each source fetches a specific type of contextual information
/// (location, calendar, weather, etc.) and returns a formatted snippet
/// for the Haiku summarizer.
abstract class GlanceSource {
  /// Human-readable name, e.g. "calendar", "weather".
  String get name;

  /// Whether this source is currently enabled.
  bool get enabled;

  /// How long fetched data stays valid before re-fetching.
  Duration get cacheDuration;

  /// Fetch contextual data. Return a short formatted string, or `null`
  /// if nothing relevant is available right now.
  Future<String?> fetch();
}
