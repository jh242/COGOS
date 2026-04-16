# Bitmap Glance Dashboard

## Context

The glance HUD currently sends plain text to the G1 glasses via 0x4E packets — 5 lines of monospaced text at 488px wide. This wastes the 640x200 display and prevents any visual hierarchy, alignment, or layout control. The goal is to render the glance dashboard as a 1-bit bitmap using Core Graphics, giving us full control over typography, layout, and future graphical elements (icons, charts).

## Display Constraints

- **Canvas:** 640 x 200 pixels
- **Color depth:** 1-bit monochrome (white on black — matches green waveguide)
- **Format:** Windows BMP (raw header + pixel data)
- **Transfer:** via `BmpTransfer` protocol (0x15 chunked upload, 0x20 finalize, 0x16 CRC32)
- **Transfer time:** ~660ms for 1-bit 640x200 (~16KB)
- **Dismiss:** 0x18 exit command (same as current text glance)

## Layout: Two-Column Split (1/4 + 3/4)

```
┌──────────────┬──────────────────────────────────────────┐
│              │                                          │
│  10:45       │  11:00  Team Standup                     │
│  Tue Apr 15  │  12:30  Lunch with Sara                  │
│              │  14:00  Design Review                    │
│  8°C Cloudy  │  16:00  1:1 with Manager                 │
│              │                                          │
└──────────────┴──────────────────────────────────────────┘
 ← ~160px →     ← ~~~~~~~~~~~~ ~480px ~~~~~~~~~~~~~ →
```

**Left column (fixed, ~160px):**
- Time: bold, large (~32px SF Pro)
- Date: regular, smaller (~16px)
- Weather: regular (~16px), temp + condition

**Right column (contextual, ~480px):**
- Owned by the winning contextual source via `drawContent(in:context:)`
- Each source controls its own layout within this rect
- Fallback: plain text rendering of `fetch()` string output

## Architecture

### New Files

| File | Purpose |
|------|---------|
| `COGOS/Glance/GlanceRenderer.swift` | Core Graphics rendering engine. Draws left column, divider, delegates right column to source. Produces `CGImage`. |
| `COGOS/Glance/BmpEncoder.swift` | Converts `CGImage` (1-bit) to Windows BMP `Data`. |

### Modified Files

| File | Change |
|------|--------|
| `COGOS/Glance/GlanceSource.swift` | Add `drawContent(in:context:) -> Bool` to protocol with default `false` implementation. |
| `COGOS/Glance/GlanceService.swift` | Replace `sendToGlasses` text pipeline with `GlanceRenderer` + `BmpTransfer`. Hold reference to `BmpTransfer`. |
| `COGOS/Glance/Sources/CalendarSource.swift` | Cache structured event data. Implement `drawContent` with time-aligned rows. |
| `COGOS/Glance/Sources/TransitSource.swift` | Cache structured arrival data. Implement `drawContent` with route + countdown layout. |
| `COGOS/Glance/Sources/NotificationSource.swift` | Cache structured notification data. Implement `drawContent`. |
| `COGOS/Glance/Sources/NewsSource.swift` | Cache structured headlines. Implement `drawContent` with headline list. |
| `COGOS/Glance/Sources/WeatherSource.swift` | Expose structured `WeatherData` (temp, condition) for left column rendering. |
| `COGOS/Glance/Sources/TimeSource.swift` | No change needed — `GlanceRenderer` reads `Date()` directly. |
| `COGOS/App/AppState.swift` | Pass `BmpTransfer` dependency to `GlanceService`. |

### GlanceSource Protocol (Updated)

```swift
protocol GlanceSource {
    var name: String { get }
    var tier: GlanceTier { get }
    var enabled: Bool { get }
    var cacheDuration: TimeInterval { get }

    func relevance(_ ctx: GlanceContext) async -> Int?
    func fetch(context: GlanceContext) async -> String?

    /// Draw source content into the given rect. Return true if drawn,
    /// false to fall back to plain text rendering of fetch() output.
    func drawContent(in rect: CGRect, context: CGContext) -> Bool
}

extension GlanceSource {
    func drawContent(in rect: CGRect, context: CGContext) -> Bool { false }
}
```

Sources cache their last-fetched structured data internally (e.g., `CalendarSource` keeps `[EKEvent]`, `TransitSource` keeps `[Arrival]`). `drawContent` uses this cached data to render. `fetch()` continues to return a string for logging/debugging.

### GlanceRenderer

```swift
@MainActor
final class GlanceRenderer {
    static let width = 640
    static let height = 200
    static let leftColumnWidth = 160
    static let dividerX = 160

    /// Render the glance dashboard to a 1-bit BMP.
    func render(
        time: Date,
        weather: (temp: String, condition: String)?,
        contextualSource: GlanceSource?,
        contextualText: String?
    ) -> Data? {
        // 1. Create 640x200 CGContext (8-bit grayscale for antialiased drawing)
        // 2. Fill black background
        // 3. Draw left column: time (bold 32px), date (16px), weather (16px)
        // 4. Draw vertical divider line at x=160
        // 5. Let contextual source draw right column, or fall back to text
        // 6. Convert CGImage to 1-bit BMP via BmpEncoder
    }
}
```

### BmpEncoder

Converts a `CGImage` to Windows BMP format:
- BMP file header (14 bytes)
- DIB header (40 bytes, BITMAPINFOHEADER)
- Color table (8 bytes for 1-bit: black + white entries)
- Pixel data (1-bit packed, rows padded to 4-byte boundary, bottom-up row order)

Total for 640x200 at 1-bit: 14 + 40 + 8 + (80 bytes/row * 200 rows) = 16,062 bytes.

### GlanceService Changes

```swift
// Current:
private func sendToGlasses(_ lines: [String]) async {
    // TextPaginator → 0x4E packets
}

// New:
private func sendToGlasses() async {
    let renderer = GlanceRenderer()
    let weatherData = (sources.first { $0 is WeatherSource } as? WeatherSource)?.lastWeather
    guard let bmp = renderer.render(
        time: Date(),
        weather: weatherData,
        contextualSource: winningSource,
        contextualText: winningSourceText
    ) else { return }
    let transfer = BmpTransfer(queue: requestQueue, bluetooth: bluetooth)
    _ = await transfer.sendToBoth(bmp)
}
```

`GlanceService` needs references to `BleRequestQueue` and `BluetoothManager` (or a pre-built `BmpTransfer`). These get wired in via `AppState`.

## Data Flow

```
HEAD_UP gesture (0xF5 0x02)
  → GestureRouter → glance.showGlance()
  → refresh() — fetch all sources, score relevance, pick winner
  → GlanceRenderer.render(time, weather, winningSource)
      ├─ Draw left column (time/date/weather)
      ├─ Draw divider
      └─ winningSource.drawContent(rightRect, cgContext)
           └─ (or fallback: draw fetch() text)
  → BmpEncoder.encode(cgImage) → Data (BMP)
  → BmpTransfer.sendToBoth(bmpData)
      ├─ 0x15 chunks (194 bytes, 8ms apart) to L and R
      ├─ 0x20 finalize
      └─ 0x16 CRC32 verify
  → isShowing = true
```

## Font Strategy

- Use `CTFont` (Core Text) for text drawing into `CGContext`
- System font: SF Pro (available on iOS)
- Time: SF Pro Bold, ~32px
- Date: SF Pro Regular, ~16px
- Weather: SF Pro Regular, ~16px
- Right column: source-controlled, but helper utilities provided for common patterns (draw text row, draw aligned columns)

### Drawing Helpers

Small utility functions sources can use in their `drawContent`:

```swift
enum GlanceDrawing {
    /// Draw a single line of text, returns the Y position after drawing.
    static func drawText(_ text: String, at point: CGPoint,
                         font: CTFont, color: CGColor,
                         in context: CGContext) -> CGFloat

    /// Draw a two-column row (e.g., "11:00" | "Team Standup").
    static func drawAlignedRow(left: String, right: String,
                               at y: CGFloat, in rect: CGRect,
                               leftWidth: CGFloat,
                               font: CTFont, color: CGColor,
                               context: CGContext) -> CGFloat
}
```

## Verification

1. **Unit test GlanceRenderer:** Feed known data, verify output is valid BMP with correct dimensions
2. **Unit test BmpEncoder:** Feed a known CGImage, verify BMP header fields and pixel data
3. **On-device test:** Trigger head-up gesture, verify bitmap appears on glasses with correct layout
4. **Timing test:** Measure render + transfer time, confirm under ~1 second total
5. **Edge cases:** Empty weather, no contextual source, very long event names (truncation), dismiss/re-show cycle
