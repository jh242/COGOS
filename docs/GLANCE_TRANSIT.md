# Glance: transit source

Contextual glance line for the nearest NYC subway station and its next
arrivals. Lives in `COGOS/Glance/Sources/TransitSource.swift` with HTTP
client at `COGOS/Glance/Sources/WTFTClient.swift`.

## Behavior

On each refresh (≤ once per 120s via `GlanceService` cache):

1. Read device location from `NativeLocation` (last-known first, then a
   fresh request). No permission / no fix → source returns `nil` and the
   glance skips it.
2. `GET https://api.wheresthefuckingtrain.com/by-location?lat=…&lon=…`
   with a 5s timeout. Free, no API key.
3. Take the first station in the response (API returns them sorted by
   distance).
4. Compute straight-line distance client-side with
   `CLLocation.distance(from:)`. Do **not** trust any distance field in
   the payload — keeps us source-agnostic if the provider ever changes.
5. If distance > `maxStationDistance` (currently **3 km**,
   private file-scope constant in `TransitSource.swift`) → return `nil`.
   In practice this means the glance shows a transit line only when the
   user is in NYC near a subway station.
6. Merge the station's northbound (`N`) and southbound (`S`) arrival
   arrays, drop any timestamps already in the past, sort ascending, take
   up to 3.
7. Format one line, e.g.
   `Transit: 14 St–Union Sq (0.1 mi) · N 2m, R 5m, Q 9m`.
   If no future arrivals:
   `Transit: 14 St–Union Sq (0.1 mi) · no arrivals`.

Any network error, non-200, or decode failure returns `nil` — matches
the pattern every other `GlanceSource` uses.

## Why this provider

- **Free, no API key.** Eliminating key management was an explicit goal.
- **JSON, not protobuf.** MTA's official GTFS-Realtime feeds are
  protobuf; WTFT is a thin JSON wrapper over them. Fewer dependencies.
- **NYC only.** Acceptable for now — the user is in NYC. Broader coverage
  (Transitland, Navitia, agency-specific) is deferred to a later
  structured-dashboard redesign.

## Payload format (reference)

```jsonc
{
  "data": [
    {
      "id": "635",
      "name": "14 St-Union Sq",
      "location": [40.735, -73.990],
      "routes": ["N", "4", "5", "6", "L", "Q", "R", "W"],
      "N": [{"route": "6X", "time": "2026-04-13T19:33:06-04:00"}, ...],
      "S": [{"route": "Q",  "time": "2026-04-13T19:33:36-04:00"}, ...],
      "stops": { "635": [lat, lon], ... },
      "last_update": "2026-04-13T19:32:47-04:00"
    },
    ...
  ]
}
```

Only `name`, `location`, `N`, and `S` are used. Times are ISO-8601 with
timezone; decoded with `JSONDecoder.dateDecodingStrategy = .iso8601`.

## Schedule fabrication note

Before this change, `TransitSource` returned only station names (no
schedule data) and Haiku was silently inventing arrival times from those
names in the glance summary. Including real minutes-from-now in the
snippet here eliminates that specific class of hallucination **for the
NYC case only** — outside NYC, the source returns `nil` and the whole
transit line drops off the glance, which is correct. If we ever feed
Haiku a snippet that lacks schedule data but still names a station, we
should explicitly instruct it not to infer times. Not required today.

## Extending

- **Raise or lower the threshold:** edit `maxStationDistance` in
  `TransitSource.swift`. Meters. Applies to straight-line distance, not
  walking distance.
- **Non-NYC coverage:** the "one provider, no key" constraint eliminates
  Transitland / Navitia / Google. Realistic paths when revisiting are
  (a) accept an API key and use Transitland, or (b) accept more code and
  integrate a second agency directly. Either way, `TransitSource` should
  dispatch by location to the right provider rather than having the
  providers know about each other.
