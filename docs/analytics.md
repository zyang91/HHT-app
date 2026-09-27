# Metric definitions

Implemented in `Packages/HHTCore/Sources/HHTCore/Analytics/MobilityMetrics.swift` and mirrored in `analysis/hht.py`.
A trip belongs to a period if its departure is inside it. Visits are clipped to the period for dwell time.

| Metric | Definition |
|---|---|
| Person-day | Local date (record `tz`) with ≥ 1 trip or visit. Per-day rates divide by person-days, not calendar days. |
| Trips, distance, travel time | Sum over trips; means are per trip. |
| Mode share | By trips, distance or time, on the final mode. Group shares: active / car / transit / long-distance / other. |
| Departure-time distribution | Trips by local hour of departure. |
| First departure / last arrival | Per person-day, then mean (and SD for first departure — a regularity indicator). |
| Time away from home | 24 h − time at `home`-category places, averaged over observed days with a home visit. |
| Unique / new places | Places visited in the period / places whose first-ever visit is in the period. |
| Radius of gyration | r_g = √(Σ wᵢ d(pᵢ, c)² / Σ wᵢ) over places visited; c = weighted spherical centre of mass; d = great-circle. Reported dwell-weighted and visit-weighted. |
| Activity space | Convex hull area of visited places (local equirectangular projection). |
| Destination entropy | Shannon entropy (bits) of visit counts per place. |
| Mode entropy | Shannon entropy (bits) of trip counts per mode. |
| Repeat OD share | Share of trips whose origin→destination place pair already occurred earlier in the period. |
| Home-based tour | Trips from a departure at a Home place until the next arrival at a Home place. Stops per tour = intermediate destinations; complex tour = ≥ 2 stops. |
| Weekday vs weekend | Trips per weekday / weekend person-day and mode-group shares. |
| Flights | Count, great-circle distance, air time (if times known), airports, routes (unordered pairs), airlines. |

Life phases (Timeline › Life phases) define custom ranges; Stats can compare any two periods side by side.
