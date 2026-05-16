# CommuteSource Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `CommuteSource` glance provider that shows transit directions (line + boarding station per leg, max 1 transfer) from the user's current location to up to 5 saved destinations, and centralize provider priority into a single ordered array in `GlanceService`.

**Architecture:** Three layers added to the existing `Glance` provider system. (1) Two pure value types (`CommuteLeg`, `RawStep`) plus a free-function parser and formatter so route-instruction parsing and body composition are testable without MapKit. (2) `CommuteSource: ContextProvider` orchestrates `MKDirections` `.transit` requests concurrently via `withThrowingTaskGroup`, filters routes for ≤1 transfer, and produces a `QuickNote`. (3) Settings UI (`ContextProvidersSettingsView` + `LocationSearchCompleter` wrapper around `MKLocalSearchCompleter`) lets the user manage destinations. Priority is centralized: `let priority` is removed from the protocol; the array order in `GlanceService.init` *is* the priority order.

**Tech Stack:** Swift / SwiftUI (iOS 26+), MapKit (`MKDirections`, `MKLocalSearchCompleter`, `MKMapItem`), CoreLocation, XCTest (added via XcodeGen), `withThrowingTaskGroup`, `withCheckedThrowingContinuation`.

---

## Product shape

- `CommuteSource` is a compact dashboard note, not a route-planning screen: one line per eligible saved destination, showing travel time plus line + boarding station for each transit leg.
- Destinations are managed under a new “Context Providers” settings surface. Users can add up to 5 saved locations, rename them, and remove them later.
- Location entry uses an `MKLocalSearchCompleter`-backed picker, biased to the user’s current location, with debounced search input to avoid hammering the completer.
- Trips with more than 1 transfer are omitted. Destinations within 200 m are omitted as “already here.” Failed destinations do not poison the rest of the note; cached rows survive transient failures until the destination is removed or refreshed successfully.
- The note is intentionally terse:

```text
Home 35m: E @ 23 St → D @ W4 St
Work 22m: 1 @ 14 St
Gym 15m: L @ 8 Av
```

This section folds in the original design brief; the task list below is the canonical implementation plan.

---

## Execution split: cloud vs. local

**Cloud-runnable (Tasks 1–10):** All compilation, unit tests, and PR creation. Runs in a remote agent without the user's Mac. Verification command for every task is `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 16'` which works in any macOS CI environment with Xcode 16. Cloud agent stops after Task 10 and opens a PR.

**Local-only (Task 11):** On-device manual verification — requires the user's iPhone tethered to their Mac with the G1 glasses paired over BLE. Cannot be cloud-executed because: (a) BLE cannot be simulated, (b) `MKDirections` `.transit` is region-gated by Apple and only meaningful from a real device location, (c) console-tail of `[provider:commute]` log lines requires the device. The user picks this up after the cloud PR lands.

**Cloud-agent stop condition:** After Task 10's commit succeeds and the PR is opened, stop. Do not attempt Task 11. Leave Task 11's checkboxes unchecked in the PR description and call out in the PR body that the user must run them.

---

## File Structure

**New files (production):**
- `COGOS/Glance/Sources/CommuteTypes.swift` — `CommuteLeg`, `RawStep`, `CommuteParser`, `CommuteFormatter` (pure value types + free functions; no MapKit imports)
- `COGOS/Glance/Sources/CommuteSource.swift` — `ContextProvider` conformance + MKDirections orchestration
- `COGOS/Glance/Sources/LocationSearchCompleter.swift` — `MKLocalSearchCompleter` wrapper (`ObservableObject`)
- `COGOS/Views/ContextProvidersSettingsView.swift` — list + add/edit/delete UI
- `COGOS/Views/LocationPickerView.swift` — autocomplete sheet

**New files (test):**
- `COGOSTests/CommuteParserTests.swift`
- `COGOSTests/CommuteFormatterTests.swift`
- `COGOSTests/SettingsCommuteLocationsTests.swift`

**Modified files:**
- `project.yml` — add `COGOSTests` target
- `COGOS/Glance/ContextProvider.swift` — remove `priority` from protocol; rewrite doc-comment
- `COGOS/Glance/GlanceService.swift` — add `settings` init param; replace providers array; remove `.sorted`; drop `session` stored property; rewrite doc-comment
- `COGOS/Glance/Sources/CalendarSource.swift` — remove `let priority = 0`
- `COGOS/Glance/Sources/TransitSource.swift` — remove `let priority = 1`
- `COGOS/Glance/Sources/NotificationSource.swift` — remove `let priority = 2`
- `COGOS/Glance/Sources/NewsSource.swift` — remove `let priority = 3`
- `COGOS/App/AppState.swift` — `GlanceService(proto:location:session:)` → `GlanceService(proto:location:settings:)`
- `COGOS/Platform/Settings.swift` — add `CommuteLocation` + `commuteLocations` array
- `COGOS/Views/SettingsView.swift` — add `NavigationLink` to `ContextProvidersSettingsView`

---

## Task 1: Add COGOSTests target via XcodeGen

The repo has no test target today. We need one before we can do TDD. We'll keep it minimal and pure-Swift (no host-app dependency) so tests run fast and don't drag MapKit/EventKit in.

**Files:**
- Modify: `project.yml`
- Create: `COGOSTests/Smoke.swift`

- [ ] **Step 1: Add test target to `project.yml`**

Append to `project.yml`:

```yaml
  COGOSTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: COGOSTests
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.jackhu.cogos.tests
        GENERATE_INFOPLIST_FILE: true
        SWIFT_VERSION: "5.0"
    dependencies:
      - target: COGOS
```

- [ ] **Step 2: Add a smoke test**

Create `COGOSTests/Smoke.swift`:

```swift
import XCTest

final class Smoke: XCTestCase {
    func testTrue() { XCTAssertTrue(true) }
}
```

- [ ] **Step 3: Regenerate Xcode project**

Run: `xcodegen generate`
Expected: `Generated project successfully` and `COGOS.xcodeproj` mtime updates.

- [ ] **Step 4: Run the smoke test**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/Smoke/testTrue`
Expected: `** TEST SUCCEEDED **`. If the scheme doesn't include the test target yet, also pass `-scheme COGOSTests` or edit scheme to add `COGOSTests` under Test action.

- [ ] **Step 5: Commit**

```bash
git add project.yml COGOS.xcodeproj COGOSTests/Smoke.swift
git commit -m "test: add COGOSTests target with smoke test"
```

---

## Task 2: Centralize priority — remove from protocol

**Files:**
- Modify: `COGOS/Glance/ContextProvider.swift`
- Modify: `COGOS/Glance/Sources/CalendarSource.swift:8`
- Modify: `COGOS/Glance/Sources/TransitSource.swift:8`
- Modify: `COGOS/Glance/Sources/NotificationSource.swift:9`
- Modify: `COGOS/Glance/Sources/NewsSource.swift:9`
- Modify: `COGOS/Glance/GlanceService.swift:34-39`

- [ ] **Step 1: Update `ContextProvider` protocol and doc-comment**

Replace the entire `ContextProvider.swift` body with:

```swift
import Foundation

/// A pluggable context source that refreshes on every dashboard tick and
/// exposes a single Quick Notes payload when it has something to show.
///
/// `GlanceService` drives the loop:
///   - Calls `refresh(ctx)` on every provider every tick (~5 s).
///   - Each provider decides internally whether to do I/O or early-return
///     based on its own cadence.
///   - `currentNote` is the sole signal of "show me this". `nil` means
///     "don't show me" — display eligibility (transit distance, calendar
///     window, notification age, etc.) lives inside the provider.
///   - Providers are populated into the 4 Quick Notes slots in array
///     order — the first provider in `GlanceService.providers` is
///     priority 0; overflow is dropped.
///
/// `WeatherSource` does **not** conform. It has the same `refresh(ctx)`
/// lifecycle but produces `WeatherInfo` for the firmware's dedicated
/// time+weather pane, not a `QuickNote`.
protocol ContextProvider: AnyObject {
    var name: String { get }
    func refresh(_ ctx: GlanceContext) async
    var currentNote: QuickNote? { get }
}

extension ContextProvider {
    func trace(_ msg: String) { print("[provider:\(name)] \(msg)") }
}
```

- [ ] **Step 2: Remove `priority` from each provider**

In `COGOS/Glance/Sources/CalendarSource.swift`, delete line:
```swift
    let priority = 0
```

In `COGOS/Glance/Sources/TransitSource.swift`, delete line:
```swift
    let priority = 1
```

In `COGOS/Glance/Sources/NotificationSource.swift`, delete line:
```swift
    let priority = 2
```

In `COGOS/Glance/Sources/NewsSource.swift`, delete line:
```swift
    let priority = 3
```

- [ ] **Step 3: Drop `.sorted` and rewrite `GlanceService` doc-comment**

In `COGOS/Glance/GlanceService.swift`, replace the doc-comment block (lines 3–13) with:

```swift
/// Drives the firmware-dashboard tick loop.
///
/// Every ~5 s:
///   1. Build a `GlanceContext`.
///   2. Refresh weather + every provider (each decides internally whether
///      to do I/O or early-return based on its own cadence).
///   3. Push time+weather always; push Quick Notes slots only when they
///      change; always commit.
///
/// The service is dumb: it loops, walks providers in array order, and
/// pushes. All eligibility/display logic lives inside each provider's
/// `currentNote`. Array order = priority order.
```

Replace the providers array assignment in `init` (currently lines 34–39) with:

```swift
        self.providers = [
            CalendarSource(),
            TransitSource(location: location),
            NotificationSource(),
            NewsSource()
        ]
```

(Note: this task does not yet add `CommuteSource` or change the init signature — that lands in Task 8 with the wiring.)

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`. No references to `priority` should remain — confirm with `grep -rn "priority" COGOS/Glance/`. Expected: zero matches.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Glance/
git commit -m "refactor(glance): centralize provider priority into GlanceService array order"
```

---

## Task 3: Add `CommuteLocation` model and `Settings.commuteLocations`

**Files:**
- Modify: `COGOS/Platform/Settings.swift`
- Create: `COGOSTests/SettingsCommuteLocationsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `COGOSTests/SettingsCommuteLocationsTests.swift`:

```swift
import XCTest
@testable import COGOS

@MainActor
final class SettingsCommuteLocationsTests: XCTestCase {
    private let key = "commute_locations"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testDefaultIsEmpty() {
        let s = Settings()
        XCTAssertEqual(s.commuteLocations, [])
    }

    func testRoundTripsThroughUserDefaults() {
        let s1 = Settings()
        s1.commuteLocations = [
            CommuteLocation(label: "Home", latitude: 40.7, longitude: -74.0),
            CommuteLocation(label: "Work", latitude: 40.75, longitude: -73.99)
        ]
        let s2 = Settings()
        XCTAssertEqual(s2.commuteLocations.map(\.label), ["Home", "Work"])
    }

    func testSetterTruncatesPastFive() {
        let s = Settings()
        s.commuteLocations = (0..<8).map {
            CommuteLocation(label: "L\($0)", latitude: 0, longitude: 0)
        }
        XCTAssertEqual(s.commuteLocations.count, 5)
        XCTAssertEqual(s.commuteLocations.map(\.label), ["L0", "L1", "L2", "L3", "L4"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/SettingsCommuteLocationsTests`
Expected: compile error — `CommuteLocation` and `commuteLocations` undefined.

- [ ] **Step 3: Add `CommuteLocation` and the property**

In `COGOS/Platform/Settings.swift`, add after the `import Combine` line:

```swift
struct CommuteLocation: Codable, Equatable {
    var label: String
    var latitude: Double
    var longitude: Double
}
```

Add this `@Published` property next to the others (after `autoBrightness`):

```swift
    @Published var commuteLocations: [CommuteLocation] {
        didSet {
            let trimmed = Array(commuteLocations.prefix(5))
            if trimmed.count != commuteLocations.count {
                commuteLocations = trimmed
                return
            }
            if let data = try? JSONEncoder().encode(trimmed) {
                defaults.set(data, forKey: "commute_locations")
            }
        }
    }
```

In `init()`, after the `autoBrightness` initializer, add:

```swift
        if let data = defaults.data(forKey: "commute_locations"),
           let decoded = try? JSONDecoder().decode([CommuteLocation].self, from: data) {
            self.commuteLocations = Array(decoded.prefix(5))
        } else {
            self.commuteLocations = []
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/SettingsCommuteLocationsTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Platform/Settings.swift COGOSTests/SettingsCommuteLocationsTests.swift
git commit -m "feat(settings): add CommuteLocation model and commuteLocations array"
```

---

## Task 4: Pure transit-instruction parser

**Files:**
- Create: `COGOS/Glance/Sources/CommuteTypes.swift`
- Create: `COGOSTests/CommuteParserTests.swift`

The parser is a free function over `[RawStep]`. `RawStep` mirrors what we'll extract from `MKRoute.Step` (transportType + instructions). This keeps tests independent of MapKit.

- [ ] **Step 1: Write the failing test**

Create `COGOSTests/CommuteParserTests.swift`:

```swift
import XCTest
@testable import COGOS

final class CommuteParserTests: XCTestCase {
    func testDirectTrip() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to 14 St Station"),
            RawStep(kind: .transit, instructions: "Take the 1 train toward South Ferry"),
            RawStep(kind: .walking, instructions: "Walk to destination")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "1", station: "14 St")]
        )
    }

    func testOneTransfer() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to 23 St Station"),
            RawStep(kind: .transit, instructions: "Take the E train toward Jamaica Center"),
            RawStep(kind: .walking, instructions: "Walk to W 4 St Station"),
            RawStep(kind: .transit, instructions: "Take the D train toward Coney Island"),
            RawStep(kind: .walking, instructions: "Walk to destination")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [
                CommuteLeg(line: "E", station: "23 St"),
                CommuteLeg(line: "D", station: "W 4 St")
            ]
        )
    }

    func testTransferCount() {
        let zero: [RawStep] = []
        XCTAssertEqual(CommuteParser.transferCount(in: zero), 0)
        let one = [RawStep(kind: .transit, instructions: "Take the 1 train")]
        XCTAssertEqual(CommuteParser.transferCount(in: one), 0)
        let two = [
            RawStep(kind: .transit, instructions: "Take the 1 train"),
            RawStep(kind: .walking, instructions: "Walk to X Station"),
            RawStep(kind: .transit, instructions: "Take the 2 train")
        ]
        XCTAssertEqual(CommuteParser.transferCount(in: two), 1)
        let three = [
            RawStep(kind: .transit, instructions: "Take the 1 train"),
            RawStep(kind: .transit, instructions: "Take the 2 train"),
            RawStep(kind: .transit, instructions: "Take the 3 train")
        ]
        XCTAssertEqual(CommuteParser.transferCount(in: three), 2)
    }

    func testStationSuffixStripped() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to Times Sq-42 St Station"),
            RawStep(kind: .transit, instructions: "Take the 7 train toward Flushing")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "7", station: "Times Sq-42 St")]
        )
    }

    func testMissingWalkStepFallsBackToUnknown() {
        let steps = [
            RawStep(kind: .transit, instructions: "Take the L train toward Canarsie")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "L", station: "?")]
        )
    }

    func testUnparseableTransitStepIsSkipped() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to X Station"),
            RawStep(kind: .transit, instructions: "Board the express coach"),
            RawStep(kind: .walking, instructions: "Walk to Y Station"),
            RawStep(kind: .transit, instructions: "Take the 6 train toward Pelham Bay")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "6", station: "Y")]
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/CommuteParserTests`
Expected: compile error — `RawStep`, `CommuteLeg`, `CommuteParser` undefined.

- [ ] **Step 3: Create `CommuteTypes.swift` with the parser**

Create `COGOS/Glance/Sources/CommuteTypes.swift`:

```swift
import Foundation

/// One leg of a transit trip after parsing.
struct CommuteLeg: Equatable {
    var line: String
    var station: String
}

/// MapKit-independent mirror of `MKRoute.Step` — only the fields we read.
struct RawStep: Equatable {
    enum Kind { case walking, transit, other }
    var kind: Kind
    var instructions: String
}

/// Pure parser over `[RawStep]`. English-only by design — `MKRoute.Step.instructions`
/// is localized; we lock to en-US at the call site (see `CommuteSource`).
enum CommuteParser {
    private static let takeRegex = try! NSRegularExpression(
        pattern: #"Take the (\S+) train"#
    )
    private static let walkRegex = try! NSRegularExpression(
        pattern: #"Walk to (.+?)(?: Station)?$"#
    )

    static func transferCount(in steps: [RawStep]) -> Int {
        let transit = steps.filter { $0.kind == .transit }.count
        return max(0, transit - 1)
    }

    static func legs(from steps: [RawStep]) -> [CommuteLeg] {
        var out: [CommuteLeg] = []
        for (i, step) in steps.enumerated() where step.kind == .transit {
            guard let line = firstCapture(in: step.instructions, regex: takeRegex) else {
                continue
            }
            let station: String
            if i > 0, steps[i - 1].kind == .walking,
               let s = firstCapture(in: steps[i - 1].instructions, regex: walkRegex) {
                station = s
            } else {
                station = "?"
            }
            out.append(CommuteLeg(line: line, station: station))
        }
        return out
    }

    private static func firstCapture(in s: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: s) else {
            return nil
        }
        return String(s[r])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/CommuteParserTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Glance/Sources/CommuteTypes.swift COGOSTests/CommuteParserTests.swift
git commit -m "feat(glance): add CommuteParser for transit-step instructions"
```

---

## Task 5: Body-line formatter

**Files:**
- Modify: `COGOS/Glance/Sources/CommuteTypes.swift`
- Create: `COGOSTests/CommuteFormatterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `COGOSTests/CommuteFormatterTests.swift`:

```swift
import XCTest
@testable import COGOS

final class CommuteFormatterTests: XCTestCase {
    func testDirect() {
        let row = CommuteFormatter.row(
            label: "Work",
            minutes: 22,
            legs: [CommuteLeg(line: "1", station: "14 St")]
        )
        XCTAssertEqual(row, "Work 22m: 1 @ 14 St")
    }

    func testOneTransfer() {
        let row = CommuteFormatter.row(
            label: "Home",
            minutes: 35,
            legs: [
                CommuteLeg(line: "E", station: "23 St"),
                CommuteLeg(line: "D", station: "W4 St")
            ]
        )
        XCTAssertEqual(row, "Home 35m: E @ 23 St → D @ W4 St")
    }

    func testBodyJoinsAndSortsByMinutes() {
        let body = CommuteFormatter.body(rows: [
            (label: "Home", minutes: 35, legs: [CommuteLeg(line: "E", station: "23 St")]),
            (label: "Work", minutes: 22, legs: [CommuteLeg(line: "1", station: "14 St")]),
            (label: "Gym",  minutes: 15, legs: [CommuteLeg(line: "L", station: "8 Av")])
        ])
        XCTAssertEqual(body, """
        Gym 15m: L @ 8 Av
        Work 22m: 1 @ 14 St
        Home 35m: E @ 23 St
        """)
    }

    func testEmptyBodyIsEmptyString() {
        XCTAssertEqual(CommuteFormatter.body(rows: []), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/CommuteFormatterTests`
Expected: compile error — `CommuteFormatter` undefined.

- [ ] **Step 3: Add formatter to `CommuteTypes.swift`**

Append to `COGOS/Glance/Sources/CommuteTypes.swift`:

```swift
enum CommuteFormatter {
    typealias Row = (label: String, minutes: Int, legs: [CommuteLeg])

    static func row(label: String, minutes: Int, legs: [CommuteLeg]) -> String {
        let path = legs.map { "\($0.line) @ \($0.station)" }.joined(separator: " → ")
        return "\(label) \(minutes)m: \(path)"
    }

    static func body(rows: [Row]) -> String {
        rows
            .sorted { $0.minutes < $1.minutes }
            .map { row(label: $0.label, minutes: $0.minutes, legs: $0.legs) }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:COGOSTests/CommuteFormatterTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Glance/Sources/CommuteTypes.swift COGOSTests/CommuteFormatterTests.swift
git commit -m "feat(glance): add CommuteFormatter for body composition"
```

---

## Task 6: Scaffold `CommuteSource`

Conformance only — refresh is a no-op for now. Establishes the type, settings reference, refresh-cadence guard, and the empty-locations early-return.

**Files:**
- Create: `COGOS/Glance/Sources/CommuteSource.swift`

- [ ] **Step 1: Create the file**

Create `COGOS/Glance/Sources/CommuteSource.swift`:

```swift
import Foundation
import CoreLocation
import MapKit

/// Transit directions to up to 5 saved locations. Eligible when at least one
/// saved location has a parseable transit route with ≤ 1 transfer and the
/// user is not within 200 m of it.
@MainActor
final class CommuteSource: ContextProvider {
    let name = "commute"

    private static let refreshInterval: TimeInterval = 5 * 60
    private static let selfSkipMeters: CLLocationDistance = 200
    private static let maxTransfers = 1

    private let location: NativeLocation
    private let settings: Settings

    private var lastFetch: Date?
    private var cachedRows: [String: CommuteFormatter.Row] = [:]  // keyed by label

    init(location: NativeLocation, settings: Settings) {
        self.location = location
        self.settings = settings
    }

    var currentNote: QuickNote? {
        guard !cachedRows.isEmpty else { return nil }
        let body = CommuteFormatter.body(rows: Array(cachedRows.values))
        guard !body.isEmpty else { return nil }
        return QuickNote(title: "Commute", body: body)
    }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        let destinations = settings.commuteLocations
        guard !destinations.isEmpty else {
            cachedRows.removeAll()
            return
        }
        // Fetch implementation lands in Task 7.
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add COGOS/Glance/Sources/CommuteSource.swift
git commit -m "feat(glance): scaffold CommuteSource provider"
```

---

## Task 7: MKDirections fetch + transfer filter + concurrent group

**Files:**
- Modify: `COGOS/Glance/Sources/CommuteSource.swift`

This task adds the MapKit machinery. No unit tests — `MKDirections` requires network and is region-gated by Apple, so we verify on device in Task 11.

- [ ] **Step 1: Add a `fetch(for:from:)` helper**

Add inside `CommuteSource` (before `refresh`):

```swift
    private struct Fetched {
        let label: String
        let minutes: Int
        let legs: [CommuteLeg]
    }

    private func fetch(for dest: CommuteLocation, from origin: CLLocation) async -> Fetched? {
        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        let destItem = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: dest.latitude, longitude: dest.longitude)
        ))
        let req = MKDirections.Request()
        req.source = originItem
        req.destination = destItem
        req.transportType = .transit
        req.requestsAlternateRoutes = true
        let directions = MKDirections(request: req)

        let response: MKDirections.Response
        do {
            response = try await directions.calculate()
        } catch {
            trace("\(dest.label): MKDirections failed — \(error.localizedDescription)")
            return nil
        }

        let eligible = response.routes.first { route in
            CommuteParser.transferCount(in: route.steps.map(toRawStep)) <= Self.maxTransfers
        }
        guard let route = eligible else {
            trace("\(dest.label): no route with ≤\(Self.maxTransfers) transfer")
            return nil
        }
        let legs = CommuteParser.legs(from: route.steps.map(toRawStep))
        guard !legs.isEmpty else {
            trace("\(dest.label): route had no parseable transit legs")
            return nil
        }
        let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        return Fetched(label: dest.label, minutes: minutes, legs: legs)
    }

    private func toRawStep(_ step: MKRoute.Step) -> RawStep {
        let kind: RawStep.Kind
        switch step.transportType {
        case .walking: kind = .walking
        case .transit: kind = .transit
        default:       kind = .other
        }
        return RawStep(kind: kind, instructions: step.instructions)
    }
```

- [ ] **Step 2: Replace the `refresh` body to drive the task group**

Replace the existing `refresh(_:)` body with:

```swift
    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        let destinations = settings.commuteLocations
        guard !destinations.isEmpty else {
            cachedRows.removeAll()
            return
        }
        guard let userLoc = location.lastKnownLocation() else {
            trace("no user location — skipping cycle")
            return
        }

        let nearby: Set<String> = Set(destinations.compactMap { dest -> String? in
            let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
            return destLoc.distance(from: userLoc) <= Self.selfSkipMeters ? dest.label : nil
        })
        for label in nearby { cachedRows.removeValue(forKey: label) }

        let toFetch = destinations.filter { !nearby.contains($0.label) }
        guard !toFetch.isEmpty else { return }

        let results = await withTaskGroup(of: Fetched?.self, returning: [Fetched].self) { group in
            for dest in toFetch {
                group.addTask { await self.fetch(for: dest, from: userLoc) }
            }
            var collected: [Fetched] = []
            for await r in group { if let r { collected.append(r) } }
            return collected
        }

        for r in results {
            cachedRows[r.label] = (label: r.label, minutes: r.minutes, legs: r.legs)
        }
        // Stale entries (destination removed by user) are evicted on next setter
        // change to `commuteLocations`; here we only keep entries whose label is
        // still in the current settings list:
        let validLabels = Set(destinations.map(\.label))
        cachedRows = cachedRows.filter { validLabels.contains($0.key) }
        trace("refreshed \(results.count)/\(toFetch.count) destinations")
    }
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run existing tests to confirm no regression**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Glance/Sources/CommuteSource.swift
git commit -m "feat(glance): MKDirections fetch with transfer filter and concurrent group"
```

---

## Task 8: Wire `CommuteSource` into `GlanceService` and `AppState`

**Files:**
- Modify: `COGOS/Glance/GlanceService.swift:18-40`
- Modify: `COGOS/App/AppState.swift:32`

- [ ] **Step 1: Update `GlanceService` init signature and providers array**

Replace the `private weak var session: EvenAISession?` line in `GlanceService.swift` with nothing (delete it). Replace the `init` (currently lines 29–40) with:

```swift
    init(proto: Proto, location: NativeLocation, settings: Settings) {
        self.proto = proto
        self.location = location
        self.weather = WeatherSource(location: location)
        self.providers = [
            CalendarSource(),
            TransitSource(location: location),
            CommuteSource(location: location, settings: settings),
            NotificationSource(),
            NewsSource()
        ]
    }
```

- [ ] **Step 2: Update `AppState` to pass `settings`**

In `COGOS/App/AppState.swift`, line 32, replace:

```swift
        let glance = GlanceService(proto: proto, location: location, session: session)
```

with:

```swift
        let glance = GlanceService(proto: proto, location: location, settings: settings)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run tests to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Glance/GlanceService.swift COGOS/App/AppState.swift
git commit -m "feat(glance): wire CommuteSource and drop unused session field"
```

---

## Task 9: `LocationSearchCompleter` autocomplete wrapper

**Files:**
- Create: `COGOS/Glance/Sources/LocationSearchCompleter.swift`

Pure UI/MapKit glue, no unit test (delegate-driven, not worth mocking).

- [ ] **Step 1: Create the file**

Create `COGOS/Glance/Sources/LocationSearchCompleter.swift`:

```swift
import Foundation
import MapKit
import Combine

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { schedule() }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    private var debounce: Task<Void, Never>?

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    func bias(to coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 50_000,
            longitudinalMeters: 50_000
        )
    }

    private func schedule() {
        debounce?.cancel()
        let q = query
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.completer.queryFragment = q }
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> (name: String, coord: CLLocationCoordinate2D)? {
        let req = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: req)
        do {
            let resp = try await search.start()
            guard let item = resp.mapItems.first else { return nil }
            let name = item.placemark.name ?? completion.title
            return (name, item.placemark.coordinate)
        } catch {
            return nil
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in self.suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add COGOS/Glance/Sources/LocationSearchCompleter.swift
git commit -m "feat(glance): add LocationSearchCompleter autocomplete wrapper"
```

---

## Task 10: Settings UI — picker sheet + provider settings view

**Files:**
- Create: `COGOS/Views/LocationPickerView.swift`
- Create: `COGOS/Views/ContextProvidersSettingsView.swift`
- Modify: `COGOS/Views/SettingsView.swift`

- [ ] **Step 1: Create the picker sheet**

Create `COGOS/Views/LocationPickerView.swift`:

```swift
import SwiftUI
import MapKit

struct LocationPickerView: View {
    @EnvironmentObject var location: NativeLocation
    @StateObject private var completer = LocationSearchCompleter()
    @Environment(\.dismiss) private var dismiss

    let onPick: (CommuteLocation) -> Void

    @State private var pendingName: String?
    @State private var pendingCoord: CLLocationCoordinate2D?
    @State private var label: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for an address or place", text: $completer.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(completer.suggestions, id: \.self) { s in
                        Button {
                            Task { await select(s) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.title)
                                Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if pendingName != nil {
                    Section("Label") {
                        TextField("e.g. Home, Work, Gym", text: $label)
                        Button("Add") { commit() }.disabled(label.isEmpty)
                    }
                }
            }
            .navigationTitle("Add Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let here = location.lastKnownLocation() {
                    completer.bias(to: here.coordinate)
                }
            }
        }
    }

    private func select(_ s: MKLocalSearchCompletion) async {
        guard let resolved = await completer.resolve(s) else { return }
        pendingName = resolved.name
        pendingCoord = resolved.coord
        label = resolved.name
    }

    private func commit() {
        guard let coord = pendingCoord else { return }
        onPick(CommuteLocation(
            label: label,
            latitude: coord.latitude,
            longitude: coord.longitude
        ))
        dismiss()
    }
}
```

- [ ] **Step 2: Create the provider settings view**

Create `COGOS/Views/ContextProvidersSettingsView.swift`:

```swift
import SwiftUI

struct ContextProvidersSettingsView: View {
    @EnvironmentObject var settings: Settings
    @State private var showPicker = false

    var body: some View {
        Form {
            Section(
                header: Text("Commute Locations"),
                footer: Text("Up to 5. Used by CommuteSource to show transit directions.")
            ) {
                ForEach($settings.commuteLocations, id: \.label) { $loc in
                    TextField("Label", text: $loc.label)
                }
                .onDelete { idx in
                    settings.commuteLocations.remove(atOffsets: idx)
                }
                if settings.commuteLocations.count < 5 {
                    Button("Add Location") { showPicker = true }
                }
            }
        }
        .navigationTitle("Context Providers")
        .sheet(isPresented: $showPicker) {
            LocationPickerView { loc in
                settings.commuteLocations.append(loc)
            }
        }
    }
}
```

- [ ] **Step 3: Add nav link from `SettingsView`**

In `COGOS/Views/SettingsView.swift`, add a new `Section` after the `Display` section (before the closing `}` of `Form`):

```swift
            Section(header: Text("Context")) {
                NavigationLink("Context Providers") {
                    ContextProvidersSettingsView()
                }
            }
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add COGOS/Views/LocationPickerView.swift COGOS/Views/ContextProvidersSettingsView.swift COGOS/Views/SettingsView.swift
git commit -m "feat(settings): add Context Providers section with location picker"
```

---

## Task 11: Manual on-device verification — **LOCAL ONLY, NOT FOR CLOUD AGENT**

> **Cloud agents: do not execute this task.** It requires the user's physical iOS device, paired G1 glasses, and access to the user's home/work area for `MKDirections` `.transit` coverage. Stop after Task 10.

`MKDirections` `.transit` cannot be exercised in unit tests — it's network-bound and Apple gates transit coverage by region. Verify on the physical iOS device described in the project README.

**Files:** none

- [ ] **Step 1: Generate project and install**

Run: `xcodegen generate && xcodebuild -project COGOS.xcodeproj -scheme COGOS -destination 'generic/platform=iOS' -allowProvisioningUpdates build`
Expected: `** BUILD SUCCEEDED **`. Then run from Xcode on the connected device.

- [ ] **Step 2: Add a destination via UI**

In Settings → Context Providers → Add Location, search for a real address (NYC region recommended for transit support). Verify it appears in the list with the correct label.

- [ ] **Step 3: Verify provider log lines**

Tail device console for `[provider:commute]`. Expected within ~10 s of next tick:
```
[provider:commute] refreshed N/N destinations
```
And the `[dashboard]` block for the slot should show:
```
slots*[k] Commute
  <Label> <m>m: <Line> @ <Station>[ → <Line> @ <Station>]
```

- [ ] **Step 4: Verify self-skip**

Stand within ~200 m of a saved destination. On the next tick, that destination's row should be absent (no "0m" line).

- [ ] **Step 5: Verify priority order**

Confirm CalendarSource still wins when an event is imminent. Confirm TransitSource still wins when at a station (since CommuteSource sits at array index 2). Confirm CommuteSource fills a Quick Notes slot otherwise.

- [ ] **Step 6: Verify empty-state**

Delete all commute locations. On next tick the slot should clear; `[provider:commute]` should not appear in the log (early-return on empty).

- [ ] **Step 7: Final commit (notes only, if any tweaks needed)**

If verification surfaces a bug, fix it and commit. Otherwise no commit is required.

---

## Edge cases (covered by code; cross-reference)

| Case | Handled in |
|------|------------|
| `commuteLocations` empty | Task 6 `refresh` early-return; Task 6 `currentNote` returns nil when `cachedRows` empty |
| User within 200 m of a destination | Task 7 `nearby` set drops it from this cycle |
| One destination fails, others succeed | Task 7 `withTaskGroup` collects only non-nil; failed label keeps prior `cachedRows` entry until label removed from settings |
| All destinations fail | `cachedRows` retains prior values; `currentNote` returns those until next successful tick |
| `MKDirections` returns no eligible route (>1 transfer or no routes) | Task 7 `fetch` returns nil → label dropped this cycle |
| Unparseable transit step | Task 4 parser skips that leg silently; if no legs left, `fetch` returns nil |
| Station name has trailing " Station" | Task 4 regex `(.+?)(?: Station)?$` strips it |
| Walk-step missing before transit step | Task 4 falls back to `"?"` for station |
| Stale `cachedRows` after user removes a destination | Task 7 final filter prunes by current `validLabels` |
| Truncation past 5 locations | Task 3 `didSet` truncates and rewrites |

## Out of scope

- Google Maps Directions API fallback
- Departure-time alerts ("leave now to arrive by 9 a.m.")
- Direction arrows (^/v) on transit steps — `MKRoute.Step` doesn't carry structured direction
- Provider enable/disable toggles in settings
- MTA GTFS-realtime delay/service-change overlay
- Localized parsing — English-only by design; document as a known limit

## Final priority order

```
0. CalendarSource     — imminent events (within 60 min)
1. TransitSource      — station arrivals (within 200 m of a station)
2. CommuteSource      — transit directions to saved locations (up to 5)
3. NotificationSource — recent delivered notifications
4. NewsSource         — fallback headlines
```
