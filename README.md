# HHT — personal travel diary

A private, local-first iOS app that works like a continuous **household travel survey for one person**.
It records location in the background, rebuilds each day into **visits, trips, modes and trip chains**, lets you fix
mistakes in one or two taps, and exports a clean, research-grade dataset (CSV / JSON / GeoJSON / SQLite).
The product brief is in [`design/`](design/personal_travel_tracker_claude_brief.md).

```
App/                    SwiftUI iOS app (Today · Timeline · Map · Stats · Places · Settings)
  Location/             background collector, CoreMotion sync, optional geocoder
  Screens/              UI
Packages/HHTCore/       platform-independent core (Swift package, no dependencies)
  Database/             SQLite wrapper, schema + migrations, repository
  Inference/            stay detection, trip building, mode classification, reprocessing
  Editing/              every correction (mode, place, times, split/merge/delete) + audit log
  Analytics/            HHTS metrics, radius of gyration, entropy, tours…
  Export/               CSV/JSON/GeoJSON/SQLite export; CSV/GPX/airport import
  Tests/                29 tests incl. the brief's 14 synthetic scenarios
analysis/               Python loader + example analysis (pandas)
docs/                   data-model, inference, collection, analytics, privacy, import formats
project.yml             XcodeGen spec (HHT.xcodeproj is generated from it)
```

## Install on your iPhone (personal use, no App Store)

1. Open `HHT.xcodeproj` in Xcode.
2. Select the **HHT** target › *Signing & Capabilities* › Team: your Apple ID (add it in Xcode › Settings › Accounts).
   If the bundle ID `com.zyang91.hht` is taken, change it to anything unique.
3. Connect the iPhone (enable *Developer Mode* in Settings › Privacy & Security when asked), pick it as the run destination, press ▶.
4. First launch: on the iPhone, trust the developer profile (Settings › General › VPN & Device Management).
5. In the app: *Allow location & start* → allow *While Using*, then later **Change to Always Allow**; allow Motion & Fitness.

With a free Apple ID the install expires after **7 days**. Re-run from Xcode to renew; your data is kept because the
database lives in the app container. A paid developer account makes it last a year.

After changing `project.yml`, regenerate with `xcodegen generate` (`brew install xcodegen`).

## Daily use
- **Today**: the reconstructed day on a map plus the chronological diary. Uncertain trips show quick mode buttons;
  tap any trip or visit to change mode/segments, place, purpose, times, split, merge/delete or add notes.
- **Places**: name recurring places once (Home, Penn, 30th St…) and they're recognised from then on. Merge duplicates.
- **Timeline**: days by month, trip search/filters, flights, life phases.
- **Map / Stats**: activity space, radius of gyration, mode share, departure times, tours, weekday/weekend, and
  period-vs-period comparisons (e.g. two semesters).
- **Settings** (gear on Today): collection status, export/import, rebuild from raw data, backups, privacy.

## Research workflow
Settings › *Create export* writes a folder (also in Files › On My iPhone › HHT › Exports) and offers a share sheet.

```bash
cd analysis && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
```

```bash
python explore.py ~/Downloads/hht-export-20260927-120000
```

```python
from hht import load, summary, mode_share
d = load("~/Downloads/hht-export-…")        # or the travel.sqlite snapshot
d.trips          # one row per trip: person_day_id, trip_seq, OD, times, mode, purpose, distance…
summary(d.phase("Fall 2026"))
```
Or query `travel.sqlite` directly (`v_trips`, `v_visits` views) from R/DBI, DuckDB or QGIS. Every user correction is in
`audit_log`, a ready-made labelled set for improving mode detection later.

## Development
```bash
cd Packages/HHTCore && swift test
```
The simulator build has a *Load demo data* button in Settings, and launching with `-hhtDemo YES` seeds three
synthetic Philadelphia days. Neither exists in device builds.

Design priorities follow the brief: data integrity → collection reliability → correct reconstruction → fast correction →
exportability → analytics → polish. Raw observations are never modified; inference can be re-run at any time without
touching anything you corrected.
