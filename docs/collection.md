# Background collection

Implemented in `App/Location/LocationCollector.swift`.

| State | Location settings | Leaves the state when |
|---|---|---|
| **moving** | continuous updates; Balanced: 10 m accuracy / 15 m filter; Precise: best / 5 m | no fix > 60 m from an anchor for 3 min → stationary |
| **stationary** | standard updates **off**; 150 m geofence around the stop; CLVisit + significant-change monitoring stay on | geofence exit, CLVisit departure, or a significant-change fix > 150 m away → moving |

- Region exits, visits and significant changes relaunch the app even after it was terminated;
  `AppDelegate` restarts collection on every launch (including background launches).
- Every fix is written immediately to `raw_location_points` with its `collector_mode`. When entering stationary mode the
  last fix is written again as `stationary_marker`, so inference can distinguish "quiet because stationary" from lost signal.
- CoreMotion activity is not streamed; its ~7-day history is queried whenever inference runs.
- A background refresh task (`com.zyang91.hht.refresh`, ~every 2 h when iOS allows) runs inference and the daily backup.

Permissions: Location **Always** (required for background), Motion & Fitness (optional but improves modes).
The blue background-location indicator is disabled; iOS still shows the location arrow in the status bar.

Battery: GPS runs only while moving. Expect a few % per day for a typical urban routine; "Precise" costs more.
