import SwiftUI
import HHTCore

struct DaySummary: Identifiable {
    var id: Date { day }
    var day: Date
    var trips = 0
    var distance = 0.0
    var modes: [TravelMode] = []
    var places: [String] = []
    var needsReview = 0
    var flight = false
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var months: [(month: Date, days: [DaySummary])] = []
    @State private var flightsCount = 0

    var body: some View {
        List {
            if model.isProcessing || model.inferenceFailure != nil {
                Section { InferenceStatusBanner() }
            }
            Section {
                NavigationLink { TripSearchView() } label: { Label("Find trips…", systemImage: "line.3.horizontal.decrease.circle") }
                NavigationLink { FlightsView() } label: {
                    Label("Flights", systemImage: "airplane").badge(flightsCount)
                }
                NavigationLink { LifePhasesView() } label: { Label("Life phases", systemImage: "calendar.badge.clock") }
            }
            ForEach(months, id: \.month) { m in
                Section(monthTitle(m.month)) {
                    ForEach(m.days) { d in
                        NavigationLink { DayView(day: d.day, fixedDay: true) } label: { DayRow(summary: d) }
                    }
                }
            }
            if months.isEmpty {
                Text("No trips yet. Your history will build up here day by day.").foregroundStyle(.secondary)
            }
        }
        .groupedList()
        .navigationTitle("Timeline")
        .task(id: model.revision) { load() }
    }

    private func monthTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    private func load() {
        let cal = Calendar.current
        let trips = (try? model.store.allTrips(withSegments: true)) ?? []
        let visits = (try? model.store.allVisits()) ?? []
        let places = Dictionary(uniqueKeysWithValues: ((try? model.store.places()) ?? []).map { ($0.id, $0) })
        let visitPlace = Dictionary(uniqueKeysWithValues: visits.map { ($0.id, $0.placeID) })
        var days: [Date: DaySummary] = [:]
        for t in trips {
            let d = cal.startOfDay(for: t.departure)
            var s = days[d] ?? DaySummary(day: d)
            s.trips += 1
            s.distance += t.distance
            if !s.modes.contains(t.mode) { s.modes.append(t.mode) }
            if t.needsReview { s.needsReview += 1 }
            if t.mode == .airplane { s.flight = true }
            let dest = (t.destinationVisitID.flatMap { visitPlace[$0] ?? nil } ?? t.destinationPlaceID).flatMap { places[$0] }
            if let name = dest?.isNamed == true ? dest?.displayName : nil, !s.places.contains(name) { s.places.append(name) }
            days[d] = s
        }
        for v in visits {
            let d = cal.startOfDay(for: v.arrival)
            if days[d] == nil { days[d] = DaySummary(day: d) }
            if let p = v.placeID.flatMap({ places[$0] }), p.isNamed, !(days[d]!.places.contains(p.displayName)) {
                days[d]!.places.append(p.displayName)
            }
        }
        let grouped = Dictionary(grouping: days.values) { cal.date(from: cal.dateComponents([.year, .month], from: $0.day))! }
        months = grouped.map { (month: $0.key, days: $0.value.sorted { $0.day > $1.day }) }.sorted { $0.month > $1.month }
        flightsCount = ((try? model.store.flights()) ?? []).count
    }
}

struct DayRow: View {
    let summary: DaySummary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Fmt.shortDay(summary.day)).font(.subheadline.weight(.semibold))
                if summary.flight { Image(systemName: "airplane").font(.caption).foregroundStyle(.purple) }
                Spacer()
                HStack(spacing: 2) {
                    ForEach(summary.modes.prefix(4)) { m in Image(systemName: m.symbol).font(.caption2).foregroundStyle(m.color) }
                }
            }
            Text("\(summary.trips) trips · \(Fmt.distance(summary.distance))" + (summary.needsReview > 0 ? " · \(summary.needsReview) to check" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if !summary.places.isEmpty {
                Text(summary.places.prefix(4).joined(separator: " → ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Simple filter-based query over the trip table (brief §15).
struct TripSearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: TravelMode?
    @State private var placeID: String?
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()
    @State private var afterHour = 0
    @State private var weekendsOnly = false
    @State private var places: [Place] = []
    @State private var results: [Trip] = []
    @State private var names: [String: String] = [:]
    @State private var selected: IDBox?

    var body: some View {
        List {
            Section("Filters") {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                Picker("Mode", selection: $mode) {
                    Text("Any").tag(TravelMode?.none)
                    ForEach(TravelMode.allCases) { m in Text(m.label).tag(TravelMode?.some(m)) }
                }
                Picker("Origin or destination", selection: $placeID) {
                    Text("Any").tag(String?.none)
                    ForEach(places) { p in Text(p.displayName).tag(String?.some(p.id)) }
                }
                Stepper("Departing after \(afterHour):00", value: $afterHour, in: 0...23)
                Toggle("Weekends only", isOn: $weekendsOnly)
            }
            Section("\(results.count) trips · \(Fmt.distance(results.reduce(0) { $0 + $1.distance }))") {
                ForEach(results) { t in
                    Button { selected = IDBox(id: t.id) } label: {
                        HStack {
                            ModeIcon(mode: t.mode, size: 24)
                            VStack(alignment: .leading) {
                                Text("\(names[t.id] ?? "")").font(.subheadline).foregroundStyle(.primary)
                                Text("\(Fmt.shortDay(t.departure)) \(Fmt.time(t.departure)) · \(Fmt.distance(t.distance)) · \(Fmt.duration(t.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Find trips")
        .inlineTitle()
        .sheet(item: $selected) { b in TripDetailView(tripID: b.id).environmentObject(model) }
        .task { places = ((try? model.store.places()) ?? []).filter(\.isNamed) }
        .task(id: "\(mode?.rawValue ?? "")\(placeID ?? "")\(from)\(to)\(afterHour)\(weekendsOnly)\(model.revision)") { search() }
    }

    private func search() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!
        var trips = ((try? model.store.trips(overlapping: start, end, withSegments: false)) ?? []).filter { $0.departure >= start && $0.departure < end }
        if let mode { trips = trips.filter { $0.mode == mode } }
        if afterHour > 0 { trips = trips.filter { cal.component(.hour, from: $0.departure) >= afterHour } }
        if weekendsOnly { trips = trips.filter { cal.isDateInWeekend($0.departure) } }
        var n: [String: String] = [:]
        var keep: [Trip] = []
        for t in trips {
            let o = (t.originVisitID.flatMap { try? model.store.visit($0) }?.placeID ?? t.originPlaceID)
            let d = (t.destinationVisitID.flatMap { try? model.store.visit($0) }?.placeID ?? t.destinationPlaceID)
            if let placeID, o != placeID && d != placeID { continue }
            let on = o.flatMap { try? model.store.place($0) }?.displayName ?? "?"
            let dn = d.flatMap { try? model.store.place($0) }?.displayName ?? "?"
            n[t.id] = "\(on) → \(dn)"
            keep.append(t)
        }
        names = n
        results = keep.reversed()
    }
}
