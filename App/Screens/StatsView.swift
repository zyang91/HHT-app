import SwiftUI
import Charts
import HHTCore

struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var period: Period = .month
    @State private var compare: Period?
    @State private var phases: [LifePhase] = []
    @State private var m: MobilityMetrics?
    @State private var c: MobilityMetrics?
    @State private var shareBasis = 0   // 0 trips, 1 distance, 2 time
    @State private var flightStats = Analytics.FlightStats()

    var body: some View {
        List {
            Section {
                HStack {
                    PeriodPicker(period: $period, phases: phases)
                    Spacer()
                    Menu {
                        Button("No comparison") { compare = nil }
                        ForEach([Period.week, .month, .year, .all]) { p in Button(p.label) { compare = p } }
                        ForEach(phases) { ph in Button(ph.name) { compare = .phase(ph) } }
                    } label: {
                        Label(compare.map { "vs \($0.label)" } ?? "Compare…", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
            if let m {
                volume(m)
                modes(m)
                temporal(m)
                places(m)
                spatial(m)
                chaining(m)
                weekday(m)
                if flightStats.flights > 0 {
                    Section("Flights (all time)") {
                        row("Flights", "\(flightStats.flights)")
                        row("Flight distance", Fmt.distance(flightStats.distance))
                        row("Airports", "\(flightStats.airports.count)")
                        row("Routes", "\(flightStats.routes.count)")
                    }
                }
                Section {
                    NavigationLink("How these are calculated") { MetricsHelpView() }
                }
            } else {
                ProgressView()
            }
        }
        .groupedList()
        .navigationTitle("Stats")
        .task(id: "\(period.id)-\(compare?.id ?? "")-\(model.revision)") { load() }
    }

    // MARK: sections

    private func row(_ label: String, _ value: String, _ other: String? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
            if compare != nil {
                Text(other ?? "–").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
            }
        }
    }

    private func volume(_ m: MobilityMetrics) -> some View {
        Section {
            row("Person-days observed", "\(m.personDays)", c.map { "\($0.personDays)" })
            row("Trips", "\(m.trips)", c.map { "\($0.trips)" })
            row("Trips / day", String(format: "%.2f", m.tripsPerDay), c.map { String(format: "%.2f", $0.tripsPerDay) })
            row("Distance / day", Fmt.distance(m.distancePerDay), c.map { Fmt.distance($0.distancePerDay) })
            row("Travel time / day", Fmt.duration(m.travelTimePerDay), c.map { Fmt.duration($0.travelTimePerDay) })
            row("Mean trip distance", Fmt.distance(m.meanTripDistance), c.map { Fmt.distance($0.meanTripDistance) })
            row("Mean trip duration", Fmt.duration(m.meanTripDuration), c.map { Fmt.duration($0.meanTripDuration) })
            row("Total distance", Fmt.distance(m.totalDistance), c.map { Fmt.distance($0.totalDistance) })
        } header: { header("Mobility volume") }
    }

    private func header(_ s: String) -> some View {
        HStack {
            Text(s)
            if let compare { Spacer(); Text("\(period.label) / \(compare.label)").font(.caption2) }
        }
    }

    private func modes(_ m: MobilityMetrics) -> some View {
        Section {
            Picker("Basis", selection: $shareBasis) {
                Text("Trips").tag(0); Text("Distance").tag(1); Text("Time").tag(2)
            }
            .pickerStyle(.segmented)
            let total = m.modeShare.reduce(0.0) { $0 + value($1) }
            Chart(m.modeShare) { r in
                BarMark(x: .value("Share", total > 0 ? value(r) / total : 0), y: .value("Mode", r.mode.label))
                    .foregroundStyle(r.mode.color)
                    .annotation(position: .trailing) {
                        Text(Fmt.percent(total > 0 ? value(r) / total : 0)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(60, m.modeShare.count * 28)))
            ForEach(ModeGroup.allCases, id: \.self) { g in
                if (m.groupShareByTrips[g] ?? 0) > 0 || (c?.groupShareByTrips[g] ?? 0) > 0 {
                    row("\(g.label) share (trips)", Fmt.percent(m.groupShareByTrips[g] ?? 0), c.map { Fmt.percent($0.groupShareByTrips[g] ?? 0) })
                }
            }
            row("Mode entropy", m.modeEntropy.map { String(format: "%.2f bits", $0) } ?? "–", c?.modeEntropy.map { String(format: "%.2f", $0) })
        } header: { header("Modes") }
    }

    private func value(_ r: ModeShareRow) -> Double {
        switch shareBasis {
        case 1: return r.distance
        case 2: return r.time
        default: return Double(r.trips)
        }
    }

    private func temporal(_ m: MobilityMetrics) -> some View {
        Section {
            Chart(Array(m.departuresByHour.enumerated()), id: \.offset) { h, n in
                BarMark(x: .value("Hour", h), y: .value("Departures", n)).foregroundStyle(.blue.gradient)
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
            .frame(height: 120)
            row("Mean first departure", Fmt.minutesOfDay(m.meanFirstDepartureMinutes), c.map { Fmt.minutesOfDay($0.meanFirstDepartureMinutes) })
            row("SD first departure", m.sdFirstDepartureMinutes.map { String(format: "%.0f min", $0) } ?? "–",
                c?.sdFirstDepartureMinutes.map { String(format: "%.0f min", $0) })
            row("Mean last arrival", Fmt.minutesOfDay(m.meanLastArrivalMinutes), c.map { Fmt.minutesOfDay($0.meanLastArrivalMinutes) })
            row("Time away from home / day", m.meanTimeAwayFromHomePerDay.map(Fmt.duration) ?? "–",
                c?.meanTimeAwayFromHomePerDay.map(Fmt.duration))
        } header: { header("When") }
    }

    private func places(_ m: MobilityMetrics) -> some View {
        Section {
            row("Unique places", "\(m.uniquePlaces)", c.map { "\($0.uniquePlaces)" })
            row("New places (first visit)", "\(m.newPlaces)", c.map { "\($0.newPlaces)" })
            row("Destination entropy", m.destinationEntropy.map { String(format: "%.2f bits", $0) } ?? "–",
                c?.destinationEntropy.map { String(format: "%.2f", $0) })
            row("Repeat OD share", Fmt.percent(m.repeatODShare), c.map { Fmt.percent($0.repeatODShare) })
            ForEach(m.topPlaces.prefix(6)) { p in
                HStack {
                    Image(systemName: p.category?.symbol ?? "mappin").frame(width: 22).foregroundStyle(.secondary)
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text("\(p.visits)× · \(Fmt.hours(p.dwell))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !m.topODPairs.isEmpty {
                DisclosureGroup("Top origin–destination pairs") {
                    ForEach(m.topODPairs) { od in
                        HStack {
                            Text("\(od.originName) → \(od.destinationName)").font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(od.trips)").font(.caption).monospacedDigit()
                        }
                    }
                }
            }
            let cats = m.dwellByCategory.sorted { $0.value > $1.value }.prefix(6)
            if !cats.isEmpty {
                DisclosureGroup("Time by place category") {
                    ForEach(Array(cats), id: \.key) { k, v in
                        HStack {
                            Text(PlaceCategory(rawValue: k)?.label ?? "Uncategorized").font(.caption)
                            Spacer()
                            Text(Fmt.hours(v)).font(.caption).monospacedDigit()
                        }
                    }
                }
            }
        } header: { header("Places") }
    }

    private func spatial(_ m: MobilityMetrics) -> some View {
        Section {
            row("Radius of gyration (dwell-weighted)", m.radiusOfGyrationDwell.map(Fmt.distance) ?? "–", c?.radiusOfGyrationDwell.map(Fmt.distance))
            row("Radius of gyration (visit-weighted)", m.radiusOfGyrationVisits.map(Fmt.distance) ?? "–", c?.radiusOfGyrationVisits.map(Fmt.distance))
            row("Activity space (convex hull)", m.activitySpaceHullArea.map { String(format: "%.1f km²", $0 / 1e6) } ?? "–",
                c?.activitySpaceHullArea.map { String(format: "%.1f", $0 / 1e6) })
        } header: { header("Activity space") }
    }

    private func chaining(_ m: MobilityMetrics) -> some View {
        Section {
            row("Home-based tours", "\(m.tours)", c.map { "\($0.tours)" })
            row("Mean stops per tour", m.meanStopsPerTour.map { String(format: "%.2f", $0) } ?? "–", c?.meanStopsPerTour.map { String(format: "%.2f", $0) })
            row("Tours with ≥2 stops", Fmt.percent(m.complexTourShare), c.map { Fmt.percent($0.complexTourShare) })
        } header: { header("Trip chaining") } footer: {
            Text("Tours need a place categorised as Home.")
        }
    }

    private func weekday(_ m: MobilityMetrics) -> some View {
        Section {
            row("Trips / weekday", m.weekdayTripsPerDay.map { String(format: "%.2f", $0) } ?? "–", c?.weekdayTripsPerDay.map { String(format: "%.2f", $0) })
            row("Trips / weekend day", m.weekendTripsPerDay.map { String(format: "%.2f", $0) } ?? "–", c?.weekendTripsPerDay.map { String(format: "%.2f", $0) })
            row("Active share weekday / weekend",
                "\(Fmt.percent(m.weekdayModeShare[.active] ?? 0)) / \(Fmt.percent(m.weekendModeShare[.active] ?? 0))")
            row("Transit share weekday / weekend",
                "\(Fmt.percent(m.weekdayModeShare[.transit] ?? 0)) / \(Fmt.percent(m.weekendModeShare[.transit] ?? 0))")
        } header: { header("Weekday vs weekend") }
    }

    private func load() {
        phases = (try? model.store.lifePhases()) ?? []
        let first = model.store.firstPointDate() ?? ((try? model.store.allTrips().first?.departure) ?? nil)
        m = try? Analytics.compute(store: model.store, range: period.range(first: first))
        c = compare.flatMap { try? Analytics.compute(store: model.store, range: $0.range(first: first)) }
        flightStats = Analytics.flightStats((try? model.store.flights()) ?? [])
    }
}

struct MetricsHelpView: View {
    var body: some View {
        List {
            item("Person-day", "A local calendar day with at least one recorded visit or trip. Per-day values divide by person-days, not calendar days, so days without data don't count as zero-travel days.")
            item("Trip", "Movement between two consecutive visits (stays ≥ 5 min within ~100 m). A multimodal journey is one trip with several segments; its main mode follows the HHTS hierarchy (air > rail > transit > car > bike > walk).")
            item("Radius of gyration", "r_g = √(Σ wᵢ·d(pᵢ, c)² / Σ wᵢ), over the places visited in the period, c = weighted spherical centre of mass, d = great-circle distance. Dwell-weighted uses time spent at each place; visit-weighted uses the number of visits.")
            item("Activity space", "Convex hull of all places visited in the period (area in a local equal-distance projection).")
            item("Destination entropy", "Shannon entropy (bits) of the distribution of visits over places. 0 = always the same place; higher = visits spread across more places.")
            item("Mode entropy", "Shannon entropy (bits) of trips over modes.")
            item("Repeat OD share", "Share of trips whose origin→destination place pair already occurred earlier in the period.")
            item("Home-based tour", "The sequence of trips from leaving a Home place to the next arrival at a Home place. Stops per tour = intermediate destinations.")
            item("Time away from home", "24 h minus time at Home places, averaged over observed days that include a Home visit.")
            item("New places", "Places whose first-ever visit falls inside the period.")
        }
        .navigationTitle("Definitions")
    }

    private func item(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.headline)
            Text(d).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
