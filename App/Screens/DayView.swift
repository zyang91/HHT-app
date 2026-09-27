import SwiftUI
import MapKit
import HHTCore

/// One entry in the chronological diary.
enum DiaryItem: Identifiable {
    case visit(Visit, Place?)
    case trip(Trip)

    var id: String {
        switch self {
        case .visit(let v, _): return "v-" + v.id
        case .trip(let t): return "t-" + t.id
        }
    }
    var start: Date {
        switch self {
        case .visit(let v, _): return v.arrival
        case .trip(let t): return t.departure
        }
    }
}

/// Loaded data for one local day.
struct DayData {
    var items: [DiaryItem] = []
    var visits: [Visit] = []
    var trips: [Trip] = []
    var places: [String: Place] = [:]

    static func load(_ store: TravelStore, day: Date) -> DayData {
        let r = DateRange.day(day)
        var d = DayData()
        d.visits = (try? store.visits(overlapping: r.start, r.end)) ?? []
        d.trips = (try? store.trips(overlapping: r.start, r.end)) ?? []
        let ids = Set(d.visits.compactMap(\.placeID) + d.trips.flatMap { [$0.originPlaceID, $0.destinationPlaceID].compactMap { $0 } })
        for id in ids { if let p = try? store.place(id) { d.places[id] = p } }
        d.items = (d.visits.map { DiaryItem.visit($0, $0.placeID.flatMap { d.places[$0] }) } + d.trips.map { DiaryItem.trip($0) })
            .sorted { $0.start < $1.start }
        return d
    }
}

struct DayView: View {
    @EnvironmentObject var model: AppModel
    @State var day: Date = Calendar.current.startOfDay(for: Calendar.current.date(
        byAdding: .day, value: -UserDefaults.standard.integer(forKey: "hhtDaysAgo"), to: Date())!)
    var fixedDay: Bool = false
    @State private var data = DayData()
    @State private var quickModes: [TravelMode] = [.walk, .bus, .subway, .car]
    @State private var selectedTrip: IDBox?
    @State private var selectedVisit: IDBox?
    @State private var showSettings = false
    @State private var showDatePicker = false
    @State private var reviewCount = 0

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        List {
            if !fixedDay && reviewCount > 0 {
                Section {
                    NavigationLink { ReviewView() } label: {
                        Label("\(reviewCount) trip\(reviewCount == 1 ? "" : "s") in the last 7 days could use a quick check",
                              systemImage: "checklist")
                    }
                }
            }
            Section {
                DayMap(data: data).frame(height: 230).listRowInsets(EdgeInsets())
                summary
            }
            Section {
                if data.items.isEmpty {
                    emptyState
                } else {
                    ForEach(data.items) { item in
                        switch item {
                        case .visit(let v, let p):
                            VisitRow(visit: v, place: p, day: day).contentShape(Rectangle())
                                .onTapGesture { selectedVisit = IDBox(id: v.id) }
                        case .trip(let t):
                            TripRow(trip: t, quickModes: quickModes, day: day) { mode in
                                model.perform { try model.edit.setTripMode(t.id, mode) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTrip = IDBox(id: t.id) }
                        }
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle(isToday && !fixedDay ? "Today" : Fmt.shortDay(day))
        .inlineTitle()
        .toolbar {
            if !fixedDay {
                ToolbarItem(placement: .navigation) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Button { showDatePicker = true } label: { Image(systemName: "calendar") }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday)
            }
        }
        .refreshable { await model.runInference() }
        .sheet(item: $selectedTrip) { box in TripDetailView(tripID: box.id).environmentObject(model) }
        .sheet(item: $selectedVisit) { box in VisitDetailView(visitID: box.id).environmentObject(model) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() }.environmentObject(model) }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDatePicker = false } } }
            }
            .presentationDetents([.medium])
        }
        .task(id: "\(model.revision)-\(day.timeIntervalSince1970)") { reload() }
    }

    private var summary: some View {
        let dist = data.trips.reduce(0) { $0 + $1.distance }
        let time = data.trips.reduce(0) { $0 + $1.duration }
        return HStack {
            StatPill(value: "\(data.trips.count)", label: "trips")
            StatPill(value: Fmt.distance(dist), label: "distance")
            StatPill(value: Fmt.duration(time), label: "travelling")
            StatPill(value: "\(Set(data.visits.compactMap(\.placeID)).count)", label: "places")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing recorded for this day yet.").font(.subheadline)
            if model.collector.mode == .off {
                Text("Location collection is off. Turn it on in Settings.").font(.caption).foregroundStyle(.secondary)
            } else if isToday {
                Text("Visits appear after you've stayed somewhere ~5 minutes; trips once you arrive. Pull to refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: day), d <= Date() { day = Calendar.current.startOfDay(for: d) }
    }

    private func reload() {
        day = Calendar.current.startOfDay(for: day)
        data = DayData.load(model.store, day: day)
        let freq = (try? model.store.frequentModes(limit: 4)) ?? []
        quickModes = Array((freq + [.walk, .bus, .subway, .car, .bicycle]).reduce(into: [TravelMode]()) { acc, m in
            if !acc.contains(m) { acc.append(m) }
        }.prefix(4))
        reviewCount = (try? model.store.reviewCount(since: Date().addingTimeInterval(-7 * 86_400))) ?? 0
    }
}

// MARK: - Rows

struct VisitRow: View {
    let visit: Visit
    let place: Place?
    let day: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: place?.category?.symbol ?? "mappin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(place?.isNamed == true ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(place?.isNamed == true ? place!.displayName : (place?.address ?? "Unnamed place"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(place?.isNamed == true ? .primary : .secondary)
                    if visit.userStatus.isLocked { Image(systemName: "checkmark.seal").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    Text(timeSpan).monospacedDigit()
                    Text("·")
                    Text(visit.departure == nil ? "now · \(Fmt.duration(visit.duration()))" : Fmt.duration(visit.duration()))
                    if let p = visit.purpose ?? place?.category?.defaultPurpose { Text("· \(p.label)") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let n = visit.notes { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeSpan: String {
        let cal = Calendar.current
        let a = cal.isDate(visit.arrival, inSameDayAs: day) ? Fmt.time(visit.arrival) : "‹ " + Fmt.time(visit.arrival)
        guard let d = visit.departure else { return a + "–" }
        let b = cal.isDate(d, inSameDayAs: day) ? Fmt.time(d) : Fmt.time(d) + " ›"
        return "\(a)–\(b)"
    }
}

struct TripRow: View {
    let trip: Trip
    let quickModes: [TravelMode]
    let day: Date
    var onQuickMode: (TravelMode) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModeIcon(mode: trip.mode)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(modeText).font(.subheadline.weight(.medium))
                    if trip.needsReview {
                        Text("check").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                    }
                    if trip.hasGap { Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(Fmt.time(trip.departure))–\(Fmt.time(trip.arrival)) · \(Fmt.duration(trip.duration)) · \(Fmt.distance(trip.distance))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if trip.needsReview {
                    HStack(spacing: 6) {
                        ForEach(quickModes.filter { $0 != trip.mode }.prefix(3)) { m in
                            Button { onQuickMode(m) } label: {
                                Label(m.label, systemImage: m.symbol).font(.caption).labelStyle(.titleAndIcon)
                                    .lineLimit(1).fixedSize()
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                        if trip.modeAuto != nil && trip.modeAuto != .unknown {
                            Button { onQuickMode(trip.mode) } label: { Image(systemName: "checkmark") }
                                .buttonStyle(.bordered).controlSize(.small).tint(.green)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 8)
    }

    private var modeText: String {
        let segs = trip.segments.map(\.mode)
        var uniq: [TravelMode] = []
        for m in segs where uniq.last != m { uniq.append(m) }
        if uniq.count > 1 && trip.modeUser == nil { return uniq.map(\.label).joined(separator: " + ") }
        return trip.mode.label
    }
}

// MARK: - Map

struct DayMap: View {
    let data: DayData
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(data.trips) { t in
                if t.segments.count > 1 {
                    ForEach(t.segments) { s in
                        if let poly = s.routePolyline {
                            MapPolyline(coordinates: Polyline.decode(poly).map(\.cl))
                                .stroke(s.mode.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                    }
                } else if t.route.count >= 2 {
                    MapPolyline(coordinates: t.route.map(\.cl))
                        .stroke(t.mode.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(data.visits) { v in
                let p = v.placeID.flatMap { data.places[$0] }
                Annotation(p?.isNamed == true ? p!.displayName : "", coordinate: (p?.coordinate ?? v.coordinate).cl) {
                    Image(systemName: p?.category?.symbol ?? "circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onAppear { position = Self.camera(for: data) }
        .onChange(of: data.items.map(\.id)) { _, _ in position = Self.camera(for: data) }
    }

    /// Fit everything, but never closer than ~1 km across (a lone visit would otherwise zoom to street level).
    static func camera(for data: DayData) -> MapCameraPosition {
        let coords = data.visits.map { v in (v.placeID.flatMap { data.places[$0] }?.coordinate ?? v.coordinate) }
            + data.trips.flatMap(\.route)
        guard let first = coords.first else { return .automatic }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                                    longitudeDelta: max(0.012, (maxLon - minLon) * 1.3))
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}
