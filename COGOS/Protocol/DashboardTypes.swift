import Foundation

/// Types for the firmware dashboard command family (`0x06`).
/// Byte values come from Gadgetbridge's `G1Constants.java`; see
/// `docs/G1_PROTOCOL_REFERENCE.md` for per-packet byte layouts.

/// Top-level dashboard layout (`0x06 0x06` secondary-pane selector).
enum DashboardMode: UInt8 {
    case full = 0x00
    case dual = 0x01
    case minimal = 0x02
}

/// Which pane occupies the right half of DUAL mode. Always written by
/// `setDashboardMode` even in FULL/MINIMAL — pass `.empty` as a no-op.
enum DashboardPaneMode: UInt8 {
    case quickNotes = 0x00
    case stocks = 0x01
    case news = 0x02
    case calendar = 0x03
    case map = 0x04
    case empty = 0x05
}

/// Weather icon byte used by `0x06 0x01 TIME_AND_WEATHER`.
enum WeatherId: UInt8 {
    case none = 0x00
    case night = 0x01
    case clouds = 0x02
    case drizzle = 0x03
    case heavyDrizzle = 0x04
    case rain = 0x05
    case heavyRain = 0x06
    case thunder = 0x07
    case thunderstorm = 0x08
    case snow = 0x09
    case mist = 0x0A
    case fog = 0x0B
    case sand = 0x0C
    case squalls = 0x0D
    case tornado = 0x0E
    case freezingRain = 0x0F
    case sunny = 0x10
}

/// Snapshot of the weather we want the firmware time-and-weather pane to render.
struct WeatherInfo {
    /// Weather condition icon.
    var icon: WeatherId
    /// Temperature in °C. Firmware displays the value as-is after unit
    /// conversion for display — storage is always Celsius.
    var temperatureCelsius: Int8
    /// Display unit. Does not change storage; firmware converts for render.
    var displayFahrenheit: Bool
    /// 24-hour time format. `false` = 12-hour.
    var hour24: Bool
}

/// One entry in the firmware calendar pane (`0x06 0x03`). Firmware renders
/// `timeString` verbatim — it does not parse timestamps itself, so the app
/// is responsible for formatting ("9:30am", "HH:mm", etc).
struct CalendarEvent {
    var title: String
    var timeString: String
    var location: String
}
