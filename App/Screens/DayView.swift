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
            Section {
                MascotSays(text: mascotLine).toonRow(top: 8, bottom: 8)
                if !fixedDay && reviewCount > 0 {
                    reviewBanner
                        .background(NavigationLink { ReviewView() } label: { EmptyView() }.opacity(0))
                        .toonRow()
                }
                DayMap(data: data)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .toonCard(radius: 22, shadow: 5)
                    .toonRow(top: 8, bottom: 10)
                summary.toonRow(top: 8, bottom: 8)
            }
            Section {
                if data.items.isEmpty {
                    emptyState.toonRow()
                } else {
                    ForEach(data.items) { item in
                        switch item {
                        case .visit(let v, let p):
                            VisitRow(visit: v, place: p, day: day).contentShape(Rectangle())
                                .onTapGesture { selectedVisit = IDBox(id: v.id) }
                                .toonRow(top: 5, bottom: 5)
                        case .trip(let t):
                            TripRow(trip: t, quickModes: quickModes, day: day) { mode in
                                model.perform { try model.edit.setTripMode(t.id, mode) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTrip = IDBox(id: t.id) }
                            .toonRow(top: 3, bottom: 3)
                        }
                    }
                }
            } header: {
                if !data.items.isEmpty { SectionLabel(text: "Your day, step by step") }
            }
        }
        .listSectionSpacing(.compact)
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
        return Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                StatSticker(value: "\(data.trips.count)", label: "trips", color: Toon.sun, tilt: -2)
                StatSticker(value: Fmt.distance(dist), label: "distance", color: Toon.lime, tilt: 1.5)
            }
            GridRow {
                StatSticker(value: Fmt.duration(time), label: "travelling", color: Toon.sky, tilt: 1)
                StatSticker(value: "\(Set(data.visits.compactMap(\.placeID)).count)", label: "places", color: Toon.bubblegum, tilt: -1.5)
            }
        }
        .padding(.vertical, 4)
    }

    private var reviewBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(Toon.ink)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Toon.accent))
            Text("\(reviewCount) trip\(reviewCount == 1 ? "" : "s") in the last 7 days could use a quick check")
                .font(.toon(14, .heavy)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "arrow.right").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Toon.ink))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Toon.accent).offset(x: 4, y: 4))
    }

    /// What Pip says above the map.
    private var mascotLine: String {
        guard !data.trips.isEmpty else {
            return isToday && !fixedDay ? "No trips yet today. I'm keeping an eye out!" : "A quiet day. Nothing recorded here."
        }
        let dist = Fmt.distance(data.trips.reduce(0) { $0 + $1.distance })
        let n = data.trips.count
        let lead = "\(n) trip\(n == 1 ? "" : "s") and \(dist)\(isToday && !fixedDay ? " so far" : "")."
        var byGroup: [ModeGroup: Double] = [:]
        for t in data.trips { byGroup[t.mode.group, default: 0] += t.duration }
        switch byGroup.max(by: { $0.value < $1.value })?.key {
        case .active: return lead + " Your feet did most of the work!"
        case .transit: return lead + " Transit pro, nice."
        case .car: return lead + " Mostly on wheels today."
        case .longDistance: return lead + " Big journey day!"
        default: return lead
        }
    }

    @ViewBuilder private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            ToonChip(symbol: "moon.zzz", color: Toon.grape, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing recorded for this day yet.").font(.toon(16, .heavy))
                if model.collector.mode == .off {
                    Text("Location collection is off. Turn it on in Settings.").font(.toon(13, .bold)).foregroundStyle(Toon.muted)
                } else if isToday {
                    Text("Visits appear after you've stayed somewhere ~5 minutes; trips once you arrive. Pull to refresh.")
                        .font(.toon(13, .bold)).foregroundStyle(Toon.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Toon.ink)
        .padding(14)
        .toonCard(radius: 20)
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
        HStack(alignment: .center, spacing: 12) {
            ToonChip(symbol: place?.category?.symbol ?? "mappin", color: place?.toonColor ?? Toon.stone, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place?.isNamed == true ? place!.displayName : (place?.address ?? "Unnamed place"))
                        .font(.toon(18, .bold))
                        .foregroundStyle(place?.isNamed == true ? Toon.ink : Toon.muted)
                        .lineLimit(2)
                    if visit.userStatus.isLocked { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Toon.okGreen) }
                    if visit.departure == nil { ToonBadge(text: "here now", color: Toon.accent) }
                }
                HStack(spacing: 6) {
                    Text(timeSpan).monospacedDigit()
                    Text("·")
                    Text(visit.departure == nil ? "now · \(Fmt.duration(visit.duration()))" : Fmt.duration(visit.duration()))
                    if let p = visit.purpose ?? place?.category?.defaultPurpose { Text("· \(p.label)") }
                }
                .font(.toon(12, .bold)).foregroundStyle(Toon.muted)
                if let n = visit.notes { Text(n).font(.toon(12, .semibold)).foregroundStyle(Toon.muted).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .toonCard(radius: 18, shadow: 3)
        }
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
            // dashed "path" between the visit stickers
            Rectangle().fill(.clear).frame(width: 44)
                .overlay {
                    Line().stroke(Toon.ink.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                        .frame(width: 3)
                }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(Array(uniqueModes.prefix(3).enumerated()), id: \.offset) { _, m in ModeIcon(mode: m, size: 30) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(modeText).font(.toon(14, .heavy)).foregroundStyle(Toon.ink)
                            if trip.needsReview { ToonBadge(text: "check") }
                            if trip.hasGap { Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.caption).foregroundStyle(Toon.muted) }
                        }
                        Text("\(Fmt.time(trip.departure))–\(Fmt.time(trip.arrival)) · \(Fmt.duration(trip.duration)) · \(Fmt.distance(trip.distance))")
                            .font(.toon(12, .bold)).monospacedDigit().foregroundStyle(Toon.muted)
                    }
                }
                if trip.needsReview {
                    Text("Did I get that right?").font(.toon(13, .heavy)).foregroundStyle(Toon.ink)
                    // full labels when they fit, icons only on narrow screens
                    ViewThatFits(in: .horizontal) {
                        quickButtons(iconOnly: false)
                        quickButtons(iconOnly: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(trip.needsReview ? 12 : 4)
            .background {
                if trip.needsReview { Color.clear.toonCard(Toon.cream, radius: 18, shadow: 0, dashed: true) }
            }
        }
    }

    private func quickButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(quickModes.filter { $0 != trip.mode }.prefix(3)) { m in
                Button { onQuickMode(m) } label: {
                    if iconOnly {
                        Image(systemName: m.symbol).accessibilityLabel(m.label)
                    } else {
                        Label(m.label, systemImage: m.symbol).labelStyle(.titleAndIcon)
                            .lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(ToonButtonStyle(height: 34, fontSize: 12, shadow: 2))
            }
            if trip.modeAuto != nil && trip.modeAuto != .unknown {
                Button { onQuickMode(trip.mode) } label: { Image(systemName: "checkmark").fontWeight(.black) }
                    .buttonStyle(ToonButtonStyle(fill: Toon.lime, height: 34, fontSize: 13, shadow: 2))
                    .accessibilityLabel("Confirm \(trip.mode.label)")
            }
        }
        .padding(.trailing, 2)
    }

    private var uniqueModes: [TravelMode] {
        var uniq: [TravelMode] = []
        for m in trip.segments.map(\.mode) where uniq.last != m { uniq.append(m) }
        return uniq.isEmpty || trip.modeUser != nil ? [trip.mode] : uniq
    }

    private var modeText: String {
        let segs = trip.segments.map(\.mode)
        var uniq: [TravelMode] = []
        for m in segs where uniq.last != m { uniq.append(m) }
        if uniq.count > 1 && trip.modeUser == nil { return uniq.map(\.label).joined(separator: " + ") }
        return trip.mode.label
    }
}

/// Vertical line used for the dashed path between diary stickers.
struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
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
                            let coords = Polyline.decode(poly).map(\.cl)
                            MapPolyline(coordinates: coords)
                                .stroke(Toon.ink, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                            MapPolyline(coordinates: coords)
                                .stroke(s.mode.color, style: ToonMap.style(for: s.mode))
                        }
                    }
                } else if t.route.count >= 2 {
                    MapPolyline(coordinates: t.route.map(\.cl))
                        .stroke(Toon.ink, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: t.route.map(\.cl))
                        .stroke(t.mode.color, style: ToonMap.style(for: t.mode))
                }
            }
            ForEach(data.visits) { v in
                let p = v.placeID.flatMap { data.places[$0] }
                Annotation("", coordinate: (p?.coordinate ?? v.coordinate).cl, anchor: .center) {
                    ToonPin(symbol: p?.category?.symbol ?? "mappin", color: p?.category?.toonColor ?? Toon.accent,
                            label: p?.isNamed == true ? p!.displayName : nil)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
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

// MARK: - Cartoon map pieces

enum ToonMap {
    /// Walking is drawn dotted, rail/transit dashed, everything else solid — on top of an ink casing.
    static func style(for mode: TravelMode) -> StrokeStyle {
        switch mode.group {
        case .active: return StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round, dash: [1, 7])
        case .transit, .longDistance: return StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round, dash: [9, 5])
        default: return StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
        }
    }
}

/// Sticker-style map pin: coloured disc with an icon and an optional name tag underneath.
struct ToonPin: View {
    let symbol: String
    let color: Color
    var label: String?
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(Toon.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Toon.ink, lineWidth: 2.5))
            .background(Circle().fill(Toon.ink).offset(x: 1.5, y: 2))
            .overlay(alignment: .top) {
                if let label, !label.isEmpty {
                    Text(label)
                        .font(.toon(11, .heavy)).foregroundStyle(Toon.ink)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Toon.paper))
                        .overlay(Capsule().strokeBorder(Toon.ink, lineWidth: 2))
                        .offset(y: size + 3)
                }
            }
    }
}
