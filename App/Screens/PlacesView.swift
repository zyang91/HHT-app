import SwiftUI
import MapKit
import HHTCore

struct PlacesView: View {
    @EnvironmentObject var model: AppModel
    enum Sort: String, CaseIterable, Identifiable { case time = "Time", visits = "Visits", recent = "Recent", name = "Name"; var id: String { rawValue } }

    @State private var places: [Place] = []
    @State private var stats: [String: TravelStore.PlaceStats] = [:]
    @State private var query = ""
    @State private var sort: Sort = .time
    @State private var namedOnly = false

    var body: some View {
        List {
            Section {
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                Toggle("Named places only", isOn: $namedOnly)
            }
            Section("\(shown.count) places") {
                ForEach(shown) { p in
                    NavigationLink { PlaceDetailView(placeID: p.id) } label: {
                        HStack {
                            Image(systemName: p.category?.symbol ?? "mappin")
                                .foregroundStyle(p.isNamed ? Color.accentColor : .secondary).frame(width: 26)
                            VStack(alignment: .leading) {
                                Text(p.isNamed ? p.displayName : (p.address ?? "Unnamed place"))
                                    .foregroundStyle(p.isNamed ? .primary : .secondary)
                                let s = stats[p.id]
                                Text("\(s?.visitCount ?? 0) visits · \(Fmt.hours(s?.totalDwell ?? 0))"
                                     + (s?.lastVisit.map { " · last \(Fmt.shortDay($0))" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if p.favorite { Spacer(); Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                        }
                    }
                }
            }
        }
        .groupedList()
        .searchable(text: $query, prompt: "Search places")
        .navigationTitle("Places")
        .task(id: model.revision) {
            places = (try? model.store.places()) ?? []
            stats = (try? model.store.placeStats()) ?? [:]
        }
    }

    private var shown: [Place] {
        var ps = places
        if namedOnly { ps = ps.filter(\.isNamed) }
        if !query.isEmpty {
            ps = ps.filter { $0.displayName.localizedCaseInsensitiveContains(query) || ($0.code ?? "").localizedCaseInsensitiveContains(query)
                || ($0.city ?? "").localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .time: return ps.sorted { (stats[$0.id]?.totalDwell ?? 0) > (stats[$1.id]?.totalDwell ?? 0) }
        case .visits: return ps.sorted { (stats[$0.id]?.visitCount ?? 0) > (stats[$1.id]?.visitCount ?? 0) }
        case .recent: return ps.sorted { (stats[$0.id]?.lastVisit ?? .distantPast) > (stats[$1.id]?.lastVisit ?? .distantPast) }
        case .name: return ps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }
}

struct PlaceDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let placeID: String

    @State private var place: Place?
    @State private var draft: Place?
    @State private var visits: [Visit] = []
    @State private var mergeCandidates: [Place] = []
    @State private var showMerge = false
    @State private var radiusText = ""

    var body: some View {
        Form {
            if let p = draft {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: p.coordinate.cl, latitudinalMeters: max(500, p.radius * 5),
                                                                    longitudinalMeters: max(500, p.radius * 5)))) {
                        MapCircle(center: p.coordinate.cl, radius: p.radius).foregroundStyle(.blue.opacity(0.15)).stroke(.blue, lineWidth: 1)
                        ForEach(visits.prefix(200)) { v in
                            MapCircle(center: v.coordinate.cl, radius: 4).foregroundStyle(.orange)
                        }
                    }
                    .frame(height: 200).listRowInsets(EdgeInsets())
                }
                Section("Place") {
                    TextField("Name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0.isEmpty ? nil : $0 }))
                    Picker("Category", selection: Binding(get: { draft?.category }, set: { draft?.category = $0 })) {
                        Text("None").tag(PlaceCategory?.none)
                        ForEach(PlaceCategory.allCases) { c in Label(c.label, systemImage: c.symbol).tag(PlaceCategory?.some(c)) }
                    }
                    TextField("Code (IATA, station…)", text: Binding(get: { draft?.code ?? "" }, set: { draft?.code = $0.isEmpty ? nil : $0.uppercased() }))
                        .capsKeyboard()
                    HStack {
                        Text("Radius")
                        Slider(value: Binding(get: { draft?.radius ?? 80 }, set: { draft?.radius = $0.rounded() }), in: 30...2000, step: 10)
                        Text("\(Int(p.radius)) m").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    Toggle("Favorite", isOn: Binding(get: { draft?.favorite ?? false }, set: { draft?.favorite = $0 }))
                }
                Section("Location info") {
                    TextField("Address", text: Binding(get: { draft?.address ?? "" }, set: { draft?.address = $0.isEmpty ? nil : $0 }))
                    TextField("City", text: Binding(get: { draft?.city ?? "" }, set: { draft?.city = $0.isEmpty ? nil : $0 }))
                    TextField("Region / state", text: Binding(get: { draft?.region ?? "" }, set: { draft?.region = $0.isEmpty ? nil : $0 }))
                    TextField("Country", text: Binding(get: { draft?.country ?? "" }, set: { draft?.country = $0.isEmpty ? nil : $0 }))
                    TextField("Notes", text: Binding(get: { draft?.notes ?? "" }, set: { draft?.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
                if draft != place {
                    Section {
                        Button("Save changes") { model.perform { try model.edit.updatePlace(draft!) } }
                        Button("Discard", role: .cancel) { draft = place }
                    }
                }
                Section {
                    Button { showMerge = true } label: { Label("Merge into another place…", systemImage: "arrow.triangle.merge") }
                } footer: { Text("Use when the same real place was detected twice. All visits move; nothing is lost.") }

                Section("\(visits.count) visits") {
                    ForEach(visits.prefix(100)) { v in
                        NavigationLink { DayView(day: Calendar.current.startOfDay(for: v.arrival), fixedDay: true) } label: {
                            HStack {
                                Text(Fmt.shortDay(v.arrival))
                                Spacer()
                                Text("\(Fmt.time(v.arrival))–\(v.departure.map { Fmt.time($0) } ?? "now") · \(Fmt.duration(v.duration()))")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Text("This place no longer exists (it may have been merged).")
            }
        }
        .navigationTitle(place?.displayName ?? "Place")
        .inlineTitle()
        .task(id: model.revision) { load() }
        .sheet(isPresented: $showMerge) {
            NavigationStack {
                List(mergeCandidates) { c in
                    Button {
                        model.perform { try model.edit.mergePlaces(placeID, into: c.id) }
                        showMerge = false
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(c.displayName)
                            if let p = place { Text(Fmt.distance(Geo.distance(p.coordinate, c.coordinate)) + " away").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .navigationTitle("Merge into…")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMerge = false } } }
            }
        }
    }

    private func load() {
        place = try? model.store.place(placeID)
        if place?.mergedInto != nil { place = nil }
        draft = place
        visits = (try? model.store.visits(atPlace: placeID)) ?? []
        if let p = place {
            mergeCandidates = ((try? model.store.places()) ?? []).filter { $0.id != p.id }
                .sorted { Geo.distance($0.coordinate, p.coordinate) < Geo.distance($1.coordinate, p.coordinate) }
                .prefix(40).map { $0 }
        }
    }
}
