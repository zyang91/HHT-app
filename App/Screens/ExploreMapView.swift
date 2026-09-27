import SwiftUI
import MapKit
import HHTCore

/// Shared period selector for Map and Stats.
enum Period: Hashable, Identifiable {
    case week, month, year, all
    case phase(LifePhase)

    var id: String {
        switch self {
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        case .all: return "all"
        case .phase(let p): return "phase-" + p.id
        }
    }
    var label: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .year: return "Year"
        case .all: return "All time"
        case .phase(let p): return p.name
        }
    }
    func range(first: Date?) -> DateRange {
        switch self {
        case .week: return .lastDays(7)
        case .month: return .lastDays(30)
        case .year: return .lastDays(365)
        case .all: return DateRange(start: first ?? Date(), end: Date())
        case .phase(let p): return DateRange.phase(p) ?? .lastDays(30)
        }
    }
    static func == (a: Period, b: Period) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PeriodPicker: View {
    @Binding var period: Period
    var phases: [LifePhase]
    var body: some View {
        Menu {
            ForEach([Period.week, .month, .year, .all]) { p in Button(p.label) { period = p } }
            if !phases.isEmpty {
                Section("Life phases") { ForEach(phases) { ph in Button(ph.name) { period = .phase(ph) } } }
            }
        } label: {
            Label(period.label, systemImage: "calendar").labelStyle(.titleAndIcon)
        }
    }
}

struct ExploreMapView: View {
    @EnvironmentObject var model: AppModel
    @State private var period: Period = .month
    @State private var phases: [LifePhase] = []
    @State private var trips: [Trip] = []
    @State private var placeUse: [(Place, Int)] = []
    @State private var flights: [Flight] = []
    @State private var metrics: MobilityMetrics?
    @State private var showRoutes = true
    @State private var showPlaces = true
    @State private var showHull = true
    @State private var showFlights = true
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                if showHull, let hull = metrics?.activitySpaceHull, hull.count >= 3 {
                    MapPolygon(coordinates: hull.map(\.cl)).foregroundStyle(.blue.opacity(0.08)).stroke(.blue.opacity(0.6), lineWidth: 1)
                }
                if showRoutes {
                    ForEach(trips) { t in
                        if t.mode != .airplane, t.route.count >= 2 {
                            MapPolyline(coordinates: t.route.map(\.cl)).stroke(t.mode.color.opacity(0.55), lineWidth: 3)
                        }
                    }
                }
                if showFlights {
                    ForEach(flights) { f in
                        if let o = f.origin, let d = f.destination {
                            MapPolyline(MKGeodesicPolyline(coordinates: [o.cl, d.cl], count: 2)).stroke(.purple.opacity(0.7), lineWidth: 2)
                        }
                    }
                }
                if showPlaces {
                    ForEach(placeUse, id: \.0.id) { p, n in
                        Annotation(p.isNamed ? p.displayName : "", coordinate: p.coordinate.cl) {
                            Circle().fill(Color.orange.opacity(0.8))
                                .frame(width: CGFloat(8 + min(24, sqrt(Double(n)) * 3)), height: CGFloat(8 + min(24, sqrt(Double(n)) * 3)))
                                .overlay(Circle().stroke(.white, lineWidth: 1))
                        }
                    }
                }
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))

            if let m = metrics {
                HStack {
                    StatPill(value: Fmt.distance(m.radiusOfGyrationDwell ?? 0), label: "radius of gyration")
                    StatPill(value: String(format: "%.1f km²", (m.activitySpaceHullArea ?? 0) / 1e6), label: "hull area")
                    StatPill(value: "\(m.uniquePlaces)", label: "places")
                    StatPill(value: "\(m.trips)", label: "trips")
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .navigationTitle("Map")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) { PeriodPicker(period: $period, phases: phases) }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Routes", isOn: $showRoutes)
                    Toggle("Places", isOn: $showPlaces)
                    Toggle("Activity space (convex hull)", isOn: $showHull)
                    Toggle("Flights", isOn: $showFlights)
                } label: { Image(systemName: "square.3.layers.3d") }
            }
        }
        .task(id: "\(period.id)-\(model.revision)") { load() }
    }

    private func load() {
        phases = (try? model.store.lifePhases()) ?? []
        let r = period.range(first: model.store.firstPointDate() ?? (try? model.store.allTrips().first?.departure) ?? nil)
        trips = ((try? model.store.trips(overlapping: r.start, r.end, withSegments: false)) ?? []).filter { r.contains($0.departure) }
        metrics = try? Analytics.compute(store: model.store, range: r)
        let places = Dictionary(uniqueKeysWithValues: ((try? model.store.places()) ?? []).map { ($0.id, $0) })
        placeUse = (metrics?.topPlaces ?? []).isEmpty ? [] : placeCounts(r, places)
        flights = ((try? model.store.flights()) ?? []).filter { f in Fmt.parseYMD(f.date).map(r.contains) ?? true }
        position = .automatic
    }

    private func placeCounts(_ r: DateRange, _ places: [String: Place]) -> [(Place, Int)] {
        let visits = (try? model.store.visits(overlapping: r.start, r.end)) ?? []
        var counts: [String: Int] = [:]
        for v in visits { if let p = v.placeID { counts[p, default: 0] += 1 } }
        return counts.compactMap { k, n in places[k].map { ($0, n) } }
    }
}
