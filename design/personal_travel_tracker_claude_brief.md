# Personal Travel Tracker — Product & Development Brief

## 0. One-sentence concept

Build a **private, local-first personal travel tracker** that behaves like a continuous **Household Travel Survey (HHTS) for one person**: it automatically reconstructs daily movements into visits, trips, modes, dwell times, routes, and trip chains, lets the user quickly correct mistakes, and turns years of mobility history into an analyzable personal dataset and visual travel diary.

This is **not primarily a tourism-planning app, social network, or Strava clone**. The core product is a long-term **mobility diary + personal spatial database + visualization dashboard**.

---

# 1. Product vision

The app should answer two different but connected questions:

1. **What did I do today?**
   - When did I leave?
   - Where did I go?
   - How long did I stay?
   - How did I get there?
   - What route did I take?
   - What was the purpose of the trip?
   - What sequence of activities formed the day's trip chain?

2. **What does my travel behavior look like over months and years?**
   - How many trips do I make?
   - How far do I travel?
   - Which modes do I use?
   - How routine or exploratory is my life?
   - Which places dominate my activity space?
   - How does my behavior change across semesters, jobs, cities, seasons, weekdays, or life transitions?
   - Which cities, airports, rail stations, and transport systems have I used?
   - What does my entire travel history look like on a map and timeline?

The desired end state is a **multi-year N-of-1 mobility dataset** that is simultaneously useful as:

- a personal diary;
- a travel-history archive;
- a self-quantification tool;
- a spatial-analysis dataset;
- a sandbox for transportation-planning metrics;
- and potentially a source of maps/visualizations for a personal website.

---

# 2. Product principles

## 2.1 Local-first and private

Travel history is highly sensitive.

Default behavior should therefore be:

- store raw location history locally;
- do not require a public account;
- do not upload precise location data to a third-party server unless explicitly enabled;
- keep exports under the user's control;
- support backup without making cloud storage structurally necessary;
- make deletion and export easy.

A future cloud-sync option is fine, but the app should remain usable without it.

## 2.2 Automatic first, editable second

Manual travel diaries fail because entering every trip is tedious.

The app should automatically infer:

- visits;
- departures;
- arrivals;
- dwell time;
- travel segments;
- approximate route;
- likely travel mode;
- trip chains.

The user should then be able to correct the result quickly.

The ideal interaction is:

> "The app reconstructed my day. I spend 30 seconds correcting two things."

not:

> "I manually log six trips every day."

## 2.3 Preserve raw data

Do not overwrite or destroy the original observation stream when a trip is edited.

Maintain separate layers:

1. **raw observations**
2. **automatically inferred events**
3. **user-corrected canonical records**

This matters because inference algorithms may improve later.

## 2.4 Research-grade data structure

Even though this is a personal app, the underlying data model should be clean enough to export into R/Python/SQL/GIS.

Every important object should have:

- stable ID;
- timestamp;
- geometry where relevant;
- source;
- confidence;
- edit history.

## 2.5 Useful without becoming obsessive

The product should summarize mobility, not gamify movement.

Avoid:

- streak pressure;
- arbitrary movement goals;
- "you traveled less than last week" guilt;
- leaderboard/social comparison mechanics.

---

# 3. Main product modules

The application can be thought of as six connected modules.

## Module A — Passive mobility collection

Collect a low-power stream of device movement/location observations.

Potential inputs:

- GPS/location updates;
- significant-location changes;
- motion/activity recognition;
- accelerometer-derived activity classification if available;
- device timestamps;
- optional manual imports.

The collection system should balance:

- spatial accuracy;
- battery use;
- continuity;
- privacy.

The system does not need second-by-second GPS for ordinary daily travel.

A practical approach is adaptive sampling:

- low frequency when stationary;
- higher frequency after movement begins;
- lower frequency again after a stable stop is detected.

---

## Module B — Visit and trip reconstruction

Transform observations into a human-readable daily travel diary.

### Core entities

**Visit**
- place
- arrival time
- departure time
- duration
- coordinates
- place category
- purpose
- confidence

**Trip**
- origin visit
- destination visit
- departure time
- arrival time
- duration
- distance
- mode
- route/polyline
- purpose if needed
- confidence

**Trip chain / tour**
- ordered sequence of visits and trips
- e.g. Home → Penn → Restaurant → Grocery → Home

### Basic inference logic

A location cluster becomes a probable visit when:

- the user remains within a geographic radius;
- for longer than a minimum dwell threshold.

A trip exists between consecutive visits.

Exact thresholds should be configurable internally rather than hard-coded throughout the codebase.

---

# 4. Daily diary: the core screen

The most important screen is a **Today / Day view**.

The user should see a chronological reconstruction such as:

```text
08:12   Left Home
08:12–08:31   Walk + Subway   4.2 mi
08:31–12:47   Penn — Work/School

12:47–12:55   Walk   0.4 mi
12:55–13:40   Restaurant — Meal

13:40–13:49   Walk
13:49–18:15   Penn — Work/School

18:15–18:38   Subway + Walk
18:38   Home
```

The same day should also appear on a small map.

### Required editing actions

Each inferred object should be editable.

The user should be able to:

- change mode;
- change destination/place;
- change purpose;
- adjust arrival/departure time;
- rename a place;
- merge duplicate places;
- merge trips;
- split a trip;
- split a visit;
- delete a false trip;
- create a missing trip;
- mark a segment as "unknown";
- identify multimodal trips;
- add notes.

### Editing philosophy

Do not make editing feel like GIS software.

Common corrections should take one or two taps.

---

# 5. Mode detection

The system should support at minimum:

- walk;
- run;
- bicycle;
- e-bike;
- private automobile — driver;
- private automobile — passenger;
- taxi / ridehail;
- local bus;
- subway / metro;
- light rail / streetcar;
- commuter rail;
- intercity rail;
- ferry;
- airplane;
- other;
- unknown.

Potential future modes:

- scooter;
- cable car / gondola;
- campus shuttle;
- coach bus.

Mode should contain:

```text
mode_auto
mode_confidence
mode_user_corrected
mode_final
```

Do not treat automated classification as certain.

Long-distance mode inference can use contextual clues later, for example:

- extreme speed + airport endpoints → flight;
- rail-line geometry + rail stations → rail;
- road path + vehicle speed → automobile;
- low speed + pedestrian network → walking.

MVP does not need perfect mode detection. Fast correction is more important.

---

# 6. Multimodal trips

A "trip" may contain multiple segments.

Example:

```text
Home
  ↓ walk
Subway station
  ↓ subway
Center City station
  ↓ walk
Penn
```

Data model:

```text
Trip
 ├── Segment 1: walk
 ├── Segment 2: subway
 └── Segment 3: walk
```

The UI can initially display the dominant mode while allowing the trip to expand into segments.

This is important because a transportation researcher will care about transfers and access/egress modes.

---

# 7. Places

The app should gradually build a personal place database.

Example place fields:

```text
place_id
name
latitude
longitude
geometry/radius
address
city
metro_area
state_region
country
category
personal_category
first_visit
last_visit
visit_count
total_dwell_time
notes
favorite
```

### Suggested personal categories

- Home
- Work / School
- Restaurant
- Cafe
- Grocery
- Shopping
- Recreation
- Entertainment
- Airport
- Rail station
- Transit station
- Hotel
- Friend / Family
- Medical
- Other

The user should be able to assign persistent labels such as:

- Home
- Penn
- Philadelphia International Airport
- 30th Street Station

Once a place is learned, future visits should be recognized automatically.

---

# 8. Trip purpose

Trip purpose can be associated with the destination visit.

Suggested categories:

- Home
- Work
- School
- Meal
- Shopping
- Recreation
- Social
- Personal business
- Medical
- Travel / airport
- Transfer
- Other

The system can later infer frequent purposes based on known places.

Do not force a purpose field for every observation.

---

# 9. Dashboard

The app should have a dashboard with multiple time scales:

- day;
- week;
- month;
- year;
- all time;
- custom range.

## Core metrics

### Mobility volume

- number of trips;
- total travel distance;
- total travel time;
- average trip distance;
- average trip duration;
- daily trips;
- daily distance.

### Mode use

- trips by mode;
- distance by mode;
- time by mode;
- mode share;
- mode share by weekday/weekend;
- mode share over time.

### Temporal behavior

- departure-time distribution;
- time of first trip;
- time of last trip;
- time away from home;
- dwell time by place/category;
- weekday vs weekend patterns.

### Places

- unique places visited;
- most visited places;
- total time at places;
- new places this month/year;
- repeat vs new destinations.

### Trip chaining

- trips per tour;
- number of stops per tour;
- direct Home ↔ destination vs chained travel;
- average chain complexity;
- percentage of days with complex chains.

---

# 10. Spatial analytics

Because the user works with urban spatial analytics, the app should go beyond generic fitness statistics.

Possible metrics:

## Activity space

Visualize all routinely visited locations and movements during a selected period.

Possible measures:

- convex hull;
- standard deviational ellipse;
- kernel-density surface later;
- total spatial extent.

## Radius of gyration

A useful compact measure of how spatially dispersed activity is.

Conceptually:

```text
r_g = sqrt(mean(distance(point_i, center_of_mass)^2))
```

Use a documented implementation and clearly state whether weighting is by:

- visits;
- dwell time;
- observations.

## Exploration vs routine

Track:

- new places vs previously visited places;
- proportion of trips to familiar destinations;
- recurrence of OD pairs;
- geographic novelty.

## Mobility entropy

A future advanced feature.

Potential measures:

- destination entropy;
- mode entropy;
- time-of-day entropy;
- sequence entropy.

The exact metric must be named and documented rather than displaying an unexplained "mobility score."

## Predictability / regularity

Potential indicators:

- repeated daily sequences;
- consistency of departure times;
- regularity of visits to recurring places;
- similarity of weekday travel patterns.

## Mode diversity

Measure how concentrated mobility is across modes.

## Trip-chain complexity

Possible measures:

- number of stops;
- number of modes;
- number of transfers;
- chain length;
- number of unique purposes;
- closed tours vs open chains.

These advanced analytics belong after the basic diary works correctly.

---

# 11. Personal travel-history layer

In addition to everyday mobility tracking, include a higher-level "My World" / travel-history view.

This is the more visual layer.

## Map

An interactive globe or world map showing:

- visited cities;
- places lived;
- airports used;
- flight routes;
- intercity rail routes where available;
- major road trips;
- countries/regions visited.

Useful hierarchy:

```text
World
 → Country
   → Region / state / province
     → City
       → places / trips
```

Possible map behavior:

- zoom from global travel history into everyday mobility;
- click a city to see first visit, last visit, total days, trips, airports, and photos/notes later;
- mark important locations such as "Home."

This map can eventually power a public-facing visualization on the user's personal website, while the raw location history remains private.

---

# 12. Flights and airports

Air travel is personally important enough to deserve a structured travel mode rather than being hidden inside generic trips.

Create explicit entities for:

## Flight

```text
flight_id
date
origin_airport
destination_airport
scheduled_departure
actual_departure
scheduled_arrival
actual_arrival
airline
flight_number
aircraft_type
seat
distance
duration
booking_reference_optional
notes
source
```

Not all fields are required.

## Airport visit

Track:

- airport;
- number of departures;
- number of arrivals;
- first use;
- last use;
- connections;
- total flights;
- routes flown.

## Flight statistics

Possible dashboard:

- total flights;
- total flight distance;
- total time in air;
- unique airports;
- unique routes;
- airports by frequency;
- airlines used;
- domestic vs international;
- map of routes.

Initial flights can be manually imported.

Future import sources could include:

- calendar events;
- airline email parsing;
- boarding-pass data;
- structured CSV.

Email integration should not be required for MVP.

---

# 13. Intercity travel

The same travel-history system should support:

- Amtrak / intercity rail;
- long-distance bus;
- road trips;
- ferry;
- flights.

Possible "Journey" abstraction:

```text
Journey
 ├── local access trip
 ├── main intercity segment
 └── local egress trip
```

Example:

```text
Philadelphia home
→ PHL Airport
→ flight PHL–SLC
→ rental car
→ Yellowstone
```

This makes the app more expressive than a pure GPS timeline.

---

# 14. Timeline

Create an all-time timeline that can be browsed by:

- day;
- month;
- year;
- city;
- trip/journey.

Potential examples:

```text
2026
 ├── Sep — Philadelphia
 ├── Aug — Yellowstone / Grand Teton
 │    ├── PHL → SLC
 │    ├── road trip
 │    └── SLC → MSP → ...
 └── ...
```

The timeline should connect long-distance travel and ordinary daily mobility rather than treating them as separate products.

---

# 15. Search and filtering

The user should eventually be able to query the dataset naturally through filters.

Examples:

- all trips by subway in September;
- every visit to JFK;
- all days with more than 8 trips;
- trips after 10 PM;
- travel during a specific semester;
- every city visited in 2026;
- all flights through Detroit;
- all Penn → Home trips;
- weekends only;
- days outside Philadelphia.

A simple filter UI is enough initially.

SQL-like / natural-language querying can come much later.

---

# 16. Contextual data integrations

These are optional enrichments, not core dependencies.

## Weather

For each trip/day:

- temperature;
- precipitation;
- snow;
- weather condition.

Useful for later personal travel-behavior analysis.

## Calendar

Potentially infer:

- class;
- meeting;
- event;
- flight;
- theater;
- appointment.

Calendar events must not automatically overwrite trip purpose.

## Transit

Potentially match observed movement to:

- transit routes;
- stations;
- GTFS schedules.

This could help distinguish subway/bus/rail.

## Health / activity

Potential context:

- steps;
- walking/running;
- cycling.

Optional only.

---

# 17. Manual import

The user already has historical trips that predate the app.

Support import through a documented CSV schema.

Example:

```csv
date,start_time,end_time,origin,destination,mode,distance_km,purpose,notes
2026-08-18,08:00,10:30,PHL,SLC,airplane,,travel,
```

For flights, use a separate flight CSV if cleaner.

Potential later imports:

- Google Maps Timeline export;
- Arc Timeline JSON;
- OwnTracks history;
- GPX;
- Apple location/activity exports where technically available.

Do not make legacy import a blocker for MVP.

---

# 18. Export

Export is a first-class feature.

Required formats:

## CSV

At minimum:

- trips.csv
- trip_segments.csv
- visits.csv
- places.csv
- flights.csv

## JSON

Full-fidelity export including relationships and metadata.

## GeoJSON

- places;
- routes;
- trip origins/destinations.

Potential later:

- GPX;
- Parquet;
- SQLite database export.

Every export should use stable IDs so tables can be joined.

---

# 19. Proposed data model

A relational structure is preferred.

## raw_location_points

```text
id
timestamp
latitude
longitude
horizontal_accuracy
altitude
speed
heading
source
```

## visits

```text
visit_id
place_id
arrival_time
departure_time
duration_seconds
latitude
longitude
auto_confidence
source
user_status
notes
```

## places

```text
place_id
name
latitude
longitude
radius
address
city
region
country
category
personal_category
created_at
updated_at
```

## trips

```text
trip_id
origin_visit_id
destination_visit_id
departure_time
arrival_time
duration_seconds
distance_meters
dominant_mode
purpose
route_geometry
auto_confidence
user_status
notes
```

## trip_segments

```text
segment_id
trip_id
sequence
start_time
end_time
mode
distance_meters
route_geometry
auto_confidence
user_corrected
```

## journeys

```text
journey_id
name
start_time
end_time
origin_city
destination_city
journey_type
notes
```

## journey_segments

```text
journey_id
trip_id_or_flight_id
sequence
```

## flights

```text
flight_id
journey_id
date
origin_airport
destination_airport
departure_time
arrival_time
airline
flight_number
aircraft_type
distance_meters
notes
```

## user_edits / audit_log

```text
edit_id
entity_type
entity_id
field
old_value
new_value
timestamp
```

This audit table can be simplified for MVP but preserving corrected vs raw state is important.

---

# 20. Confidence and provenance

Every inferred record should know where it came from.

Example:

```text
source:
- gps
- motion_api
- manual
- imported_csv
- imported_gpx
- inferred
```

Confidence:

```text
0.00–1.00
```

or an enum:

```text
high
medium
low
```

UI can highlight uncertain days rather than requiring review of everything.

A useful future feature:

> "3 trips need review"

This is preferable to forcing daily confirmation of correct records.

---

# 21. Home screen concept

Recommended primary navigation:

```text
Today
Timeline
Map
Stats
Places
Settings
```

### Today
Daily mobility diary and corrections.

### Timeline
Browse days, journeys, months, and years.

### Map
Activity-space and world-travel views.

### Stats
Mobility analytics.

### Places
Personal place database.

### Settings
Privacy, exports, imports, sensor behavior, backups.

Flights can be accessible through Timeline/Stats rather than requiring a permanent tab initially.

---

# 22. Suggested MVP

The first version should be deliberately narrow.

## MVP objective

Prove that the app can reliably create an editable daily mobility diary and persist it locally.

### MVP must include

1. Local database.
2. Background location collection.
3. Automatic stationary-place detection.
4. Automatic trip creation between visits.
5. Basic mode inference or mode = unknown.
6. Day timeline.
7. Day map.
8. Edit visit.
9. Edit trip mode.
10. Merge/split/delete records.
11. Persistent named places.
12. Basic statistics:
    - trips;
    - distance;
    - travel time;
    - mode share;
    - unique places.
13. CSV/JSON export.
14. Manual backup/export.
15. Clear privacy controls.

### MVP does NOT need

- social features;
- recommendations;
- travel booking;
- AI chatbot;
- perfect automated mode detection;
- weather;
- calendar;
- GTFS matching;
- health integration;
- flight-email parsing;
- complex machine learning;
- website publishing;
- polished global travel animation.

---

# 23. Version 2

After the diary is reliable:

- multimodal trip segmentation;
- better mode detection;
- trip-purpose inference;
- trip chains/tours;
- airport and flight model;
- manual historical import;
- week/month/year dashboards;
- activity space;
- radius of gyration;
- exploration vs routine;
- weekday/weekend comparisons;
- custom date-range analysis;
- confidence-based review queue.

---

# 24. Version 3

Long-term exploratory layer:

- world travel map;
- airport statistics;
- flight route map;
- intercity journeys;
- entropy metrics;
- regularity/predictability metrics;
- mode diversity;
- trip-chain complexity;
- automatic life-phase comparison;
- weather matching;
- calendar integration;
- GTFS/transit route matching;
- optional website-safe public summary;
- automated backup/sync.

---

# 25. Life-phase analysis

One unusually valuable future feature is the ability to define time periods such as:

- semester;
- internship;
- job;
- city of residence;
- vacation;
- research trip.

Example:

```text
Spring 2027
Summer 2027
PhD Year 1
Living in Philadelphia
Living in Los Angeles
```

Then compare:

- daily trips;
- distance;
- mode share;
- activity space;
- new places;
- departure times;
- trip-chain complexity.

This transforms the app from a log into a longitudinal behavioral dataset.

---

# 26. "Personal HHTS" framing

The app should explicitly preserve fields that make later travel-behavior analysis possible.

Traditional travel survey concepts to keep:

- person-day;
- trip;
- trip segment;
- origin;
- destination;
- departure time;
- arrival time;
- travel time;
- distance;
- mode;
- purpose;
- activity duration;
- trip chain / tour.

Even though there is only one person, retaining this conceptual structure will make the dataset easy to analyze alongside transportation datasets later.

A useful canonical export could therefore include:

```text
person_day_id
trip_id
trip_sequence
origin_place_id
destination_place_id
departure_time
arrival_time
travel_time
distance
mode
purpose
```

---

# 27. Example questions the finished product should answer

The architecture should make these questions possible without redesigning the database:

### Daily behavior
- How many trips did I make today?
- What time did I leave home?
- How much time did I spend traveling?
- How much time did I spend away from home?

### Mode
- What percentage of my trips are transit?
- How much distance did I travel by air vs rail vs car?
- Is my walking share different on weekends?

### Spatial behavior
- How large was my activity space this month?
- What is my radius of gyration?
- Which destinations dominate my mobility?
- How many new places did I visit?

### Regularity
- How repetitive are my weekday routines?
- How variable is my morning departure time?
- Which OD pairs recur most often?

### Trip chaining
- How often do I return directly home?
- How often do I chain errands?
- How many stops are typical in a tour?

### Long-run change
- How did my travel change after moving?
- How did my travel differ across semesters?
- Did I become more or less multimodal?

### Travel history
- Which airports have I used?
- How many flights have I taken?
- Which cities did I visit in a given year?
- What does my lifetime travel network look like?

---

# 28. UX requirements

## Keep correction cheap

A correction should usually require:

- tap event;
- choose replacement;
- save.

Frequently used modes and purposes should appear first.

## Avoid modal overload

Do not ask the user to classify every trip immediately.

Unknown values are acceptable.

## Surface uncertainty

For example:

```text
08:15–08:42
Unknown mode · 3.8 mi
[Walk] [Transit] [Car]
```

## Preserve context

When editing a trip, show:

- origin;
- destination;
- time;
- route;
- neighboring visits.

## Make maps informative, not decorative

Maps should help interpret the diary.

Do not let an oversized map displace the chronological travel record.

---

# 29. Technical direction

Claude should first choose a stack that can support **reliable mobile background location access**.

The most important technical requirement is not the frontend framework; it is dependable background sensing.

Possible approaches:

## Option A — Native iOS first

Advantages:
- strongest access to iOS location/motion APIs;
- easier background-behavior control;
- fewer cross-platform abstractions.

Possible stack:
- Swift / SwiftUI;
- Core Location;
- Core Motion;
- SQLite / SwiftData / Core Data;
- MapKit.

## Option B — Cross-platform

Possible stack:
- React Native / Expo development build;
- native background-location APIs where required;
- SQLite;
- Mapbox or native map provider.

Do **not** choose a framework solely because it makes the UI fast to prototype if it makes continuous background location unreliable.

For the first prototype, iOS-first is acceptable.

---

# 30. Database requirements

Prefer SQLite or another local relational database.

Reasons:

- structured joins;
- long-term history;
- stable schema;
- analytics;
- easy export;
- potentially millions of raw location observations.

Avoid storing the entire history only in app-state JSON.

Add database migrations from the beginning.

---

# 31. Geospatial handling

Recommended principles:

- use WGS84 coordinates for storage;
- calculate distance with geodesic-aware methods;
- store route geometry efficiently;
- simplify routes for visualization while preserving raw points separately;
- index timestamps;
- index place IDs;
- consider spatial indexes later if needed.

Raw GPS points may become very large.

Use retention tiers:

1. raw high-resolution observations;
2. simplified route geometry;
3. derived visits/trips.

Potential future setting:

- keep all raw data;
- keep 90 days raw then retain derived data;
- user-controlled archival.

Default should not silently delete data.

---

# 32. Algorithm-development strategy

Do not begin by building a complicated machine-learning model.

Start with transparent heuristics.

Suggested order:

1. detect stationary clusters;
2. infer visits;
3. create travel intervals;
4. calculate route distance;
5. classify obvious modes from speed/motion;
6. allow user correction;
7. collect corrected labels;
8. improve inference using the user's own labeled history later.

Because there is one primary user, **personalized learning from corrections** may eventually outperform a generic model.

---

# 33. Testing requirements

The app should include synthetic fixtures representing:

1. home → work → home;
2. home → work → restaurant → work → home;
3. walking trip;
4. subway trip;
5. car trip;
6. multimodal trip;
7. brief stop that should not become a visit;
8. long stationary period;
9. GPS drift while stationary;
10. missing GPS interval;
11. overnight visit;
12. crossing midnight;
13. airport → flight → airport;
14. multiple days without app interaction.

Important tests:

- trip ordering;
- timezone handling;
- daylight saving time;
- split/merge behavior;
- edit persistence;
- export consistency;
- no duplicate trips after reprocessing.

---

# 34. Privacy requirements

The app stores highly sensitive location history.

At minimum:

- no public-by-default endpoints;
- no analytics SDK that collects precise GPS coordinates;
- secrets/config separated from data;
- OS-level secure storage for credentials;
- optional app lock later;
- explicit consent for any external API receiving coordinates;
- user-controlled export/delete;
- clear distinction between private raw data and shareable aggregate data.

A future "public profile" should only receive intentionally selected aggregate information, such as:

- cities visited;
- airports used;
- total flights;
- generalized routes.

Never publish daily precise traces by default.

---

# 35. Design character

Desired feeling:

- clean;
- analytical;
- map-centric but not map-dominated;
- somewhere between a personal mobility diary, Arc Timeline, and a lightweight transportation-research dashboard.

Avoid:

- childish travel badges;
- tourism-app visual language;
- oversized social feed;
- excessive gamification.

The app should look like something a transportation planner / spatial analyst would enjoy using every day.

---

# 36. Development priority

Claude should optimize in this order:

```text
1. Data integrity
2. Background collection reliability
3. Correct trip/visit reconstruction
4. Fast manual correction
5. Exportability
6. Useful analytics
7. Visual polish
8. Advanced inference
```

Do not invert this list.

A beautiful globe with unreliable travel records would not satisfy the product goal.

---

# 37. First implementation milestone

The first working milestone should demonstrate this complete flow:

1. Install app.
2. Grant location permission.
3. Carry phone through several movements/stops.
4. Open app later.
5. See a reconstructed day.
6. Edit one destination.
7. Correct one travel mode.
8. Name a recurring place.
9. View a basic daily map.
10. Export the day's trips as CSV/JSON.
11. Restart the app and confirm all corrections remain intact.

That milestone is more important than implementing dozens of statistics.

---

# 38. Suggested repository structure

This is only a conceptual example; adapt it to the chosen stack.

```text
/src
  /location
    collector
    permissions
    background_tasks
  /inference
    stop_detection
    trip_builder
    mode_classifier
    chain_builder
  /database
    schema
    migrations
    repositories
  /models
    trip
    visit
    place
    segment
    journey
    flight
  /analytics
    mobility_metrics
    activity_space
    regularity
  /export
    csv
    json
    geojson
  /screens
    today
    timeline
    map
    stats
    places
    settings
  /components
  /tests
/docs
  data-model.md
  inference.md
  privacy.md
```

---

# 39. Documentation Claude should maintain

Create documentation alongside the app.

At minimum:

## `data-model.md`
Explain every table and field.

## `inference.md`
Explain:
- how stops are detected;
- how visits are created;
- how trips are generated;
- how modes are inferred;
- all thresholds.

## `privacy.md`
Explain:
- what is stored;
- where it is stored;
- what leaves the device;
- how export/deletion works.

## `export-schema.md`
Document every export column.

This is important because the app is intended to generate a dataset that may be analyzed years later.

---

# 40. Non-goals

Do not let scope drift toward:

- restaurant recommendations;
- hotel search;
- tourism itineraries;
- ticket booking;
- social check-ins;
- public follower profiles;
- fitness coaching;
- navigation;
- turn-by-turn routing;
- replacing Google Maps;
- replacing an airline app.

Those are separate products.

The distinctive idea is:

> **a longitudinal, editable, research-grade personal mobility history.**

---

# 41. Final product statement

The app should eventually feel like a fusion of:

- an automatic location timeline;
- a one-person travel survey;
- a personal GIS database;
- a travel-history map;
- and a transportation analytics dashboard.

The central data pipeline is:

```text
Location observations
        ↓
Stationary / movement detection
        ↓
Visits
        ↓
Trips + segments
        ↓
Trip chains / journeys
        ↓
User corrections
        ↓
Canonical personal mobility dataset
        ↓
Maps + statistics + long-run analysis
```

Everything should be built around the quality and longevity of that dataset.

---

# 42. Instruction to Claude

Start by producing:

1. a concrete technical architecture;
2. the local database schema;
3. an MVP screen map;
4. the background-location collection strategy;
5. the visit/trip inference logic;
6. a staged implementation plan.

Then implement the **smallest end-to-end prototype** that can collect movement, reconstruct one day, allow corrections, and export the resulting data.

Do not begin with the global travel map or advanced statistics.

When a design decision is uncertain, prioritize:

- privacy;
- local ownership;
- interpretable inference;
- editable records;
- research-quality data;
- long-term maintainability.
