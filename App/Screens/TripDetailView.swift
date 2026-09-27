import SwiftUI
import MapKit
import HHTCore

struct TripDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tripID: String

    @State private var trip: Trip?
    @State private var origin: (Visit?, Place?) = (nil, nil)
    @State private var destination: (Visit?, Place?) = (nil, nil)
    @State private var frequent: [TravelMode] = []
    @State private var notes = ""
    @State private var history: [AuditEntry] = []
    @State private var confirmDelete = false
    @State private var showSplit = false
    @State private var showAllModes = false

    var body: some View {
        NavigationStack {
            Group {
                if let t = trip { content(t) } else { ProgressView() }
            }
            .navigationTitle("Trip")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { saveNotes(); dismiss() } } }
            .task(id: model.revision) { load() }
        }
    }

    @ViewBuilder private func content(_ t: Trip) -> some View {
        List {
            Section {
                TripMap(trip: t, origin: origin.1?.coordinate ?? origin.0?.coordinate,
                        destination: destination.1?.coordinate ?? destination.0?.coordinate)
                    .frame(height: 220).listRowInsets(EdgeInsets())
                VStack(alignment: .leading, spacing: 4) {
                    Label(origin.1?.displayName ?? "Unknown origin", systemImage: "circle")
                    Label(destination.1?.displayName ?? "Unknown destination", systemImage: "mappin.circle.fill")
                    Text("\(Fmt.dateTime(t.departure)) → \(Fmt.time(t.arrival))  ·  \(Fmt.duration(t.duration))  ·  \(Fmt.distance(t.distance))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Mode") {
                modeGrid(t)
                if t.modeUser != nil {
                    Button("Reset to automatic (\(t.modeAuto?.label ?? "unknown"))") {
                        model.perform { try model.edit.setTripMode(t.id, nil) }
                    }
                    .font(.footnote)
                }
            }

            if t.segments.count > 1 {
                Section("Segments") {
                    ForEach(t.segments) { s in
                        HStack {
                            ModeIcon(mode: s.mode, size: 24)
                            VStack(alignment: .leading) {
                                Text(s.mode.label)
                                Text("\(Fmt.time(s.start))–\(Fmt.time(s.end)) · \(Fmt.distance(s.distance))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                ForEach(TravelMode.allCases) { m in
                                    Button { model.perform { try model.edit.setSegmentMode(s.id, m) } } label: {
                                        Label(m.label, systemImage: m.symbol)
                                    }
                                }
                            } label: { Text("Change").font(.caption) }
                        }
                    }
                }
            }

            Section("Purpose (activity at destination)") {
                Picker("Purpose", selection: Binding(
                    get: { t.purpose },
                    set: { p in model.perform { try model.edit.setTripPurpose(t.id, p) } })) {
                    Text(destinationDefaultPurpose.map { "Auto (\($0.label))" } ?? "Not set").tag(TripPurpose?.none)
                    ForEach(TripPurpose.allCases) { p in Text(p.label).tag(TripPurpose?.some(p)) }
                }
            }

            Section("Notes") {
                TextField("Add a note", text: $notes, axis: .vertical)
                    .onSubmit(saveNotes)
            }

            Section {
                if t.userStatus == .auto {
                    Button { model.perform { try model.edit.confirm(tripID: t.id) } } label: {
                        Label("Looks right", systemImage: "checkmark.circle")
                    }
                }
                Button { showSplit = true } label: { Label("I stopped somewhere (split trip)", systemImage: "scissors") }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("This trip didn't happen", systemImage: "trash")
                }
            }

            Section("Details") {
                LabeledContent("Automatic mode", value: "\(t.modeAuto?.label ?? "–") (\(Fmt.percent(t.modeConfidence)))")
                LabeledContent("Status", value: t.userStatus.rawValue)
                LabeledContent("Source", value: t.source.rawValue)
                if t.hasGap { LabeledContent("GPS gap", value: "yes – route partly straight-line") }
                LabeledContent("Trip ID", value: String(t.id.prefix(8)))
                if !history.isEmpty {
                    DisclosureGroup("Edit history (\(history.count))") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading) {
                                Text("\(h.action) \(h.field ?? "")").font(.caption.weight(.medium))
                                Text("\(h.oldValue ?? "∅") → \(h.newValue ?? "∅") · \(Fmt.dateTime(h.timestamp))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .groupedList()
        .confirmationDialog("Remove this trip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove and join the visits before/after", role: .destructive) {
                model.perform { try model.edit.deleteTrip(t.id) }
                dismiss()
            }
        } message: {
            Text("Use this for GPS jumps. The stay before and after become one visit. Raw data is kept.")
        }
        .sheet(isPresented: $showSplit) { SplitTripSheet(trip: t).environmentObject(model) }
    }

    private var destinationDefaultPurpose: TripPurpose? {
        destination.0?.purpose ?? destination.1?.category?.defaultPurpose
    }

    private func modeGrid(_ t: Trip) -> some View {
        let primary: [TravelMode] = {
            var list = frequent
            for m in [TravelMode.walk, .bicycle, .bus, .subway, .car, .carPassenger, .taxi, .commuterRail, .lightRail, .airplane]
            where !list.contains(m) { list.append(m) }
            return Array(list.prefix(showAllModes ? 99 : 8))
        }()
        let all = showAllModes ? primary + TravelMode.allCases.filter { !primary.contains($0) } : primary
        return VStack(alignment: .leading) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(all) { m in
                    Button { model.perform { try model.edit.setTripMode(t.id, m) } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: m.symbol).font(.title3)
                            Text(m.label).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(t.mode == m ? m.color.opacity(0.25) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.mode == m ? m.color : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(showAllModes ? "Fewer modes" : "All modes…") { showAllModes.toggle() }.font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private func saveNotes() {
        guard let t = trip, notes != (t.notes ?? "") else { return }
        model.perform { try model.edit.setNotes(tripID: t.id, notes) }
    }

    private func load() {
        guard let t = try? model.store.trip(tripID) else { trip = nil; return }
        trip = t
        notes = t.notes ?? ""
        let ov = t.originVisitID.flatMap { try? model.store.visit($0) }
        let dv = t.destinationVisitID.flatMap { try? model.store.visit($0) }
        origin = (ov, (ov?.placeID ?? t.originPlaceID).flatMap { try? model.store.place($0) })
        destination = (dv, (dv?.placeID ?? t.destinationPlaceID).flatMap { try? model.store.place($0) })
        frequent = (try? model.store.frequentModes(limit: 4)) ?? []
        history = (try? model.store.auditLog(entityID: t.id)) ?? []
    }
}

struct TripMap: View {
    let trip: Trip
    let origin: Coordinate?
    let destination: Coordinate?

    var body: some View {
        Map(initialPosition: .automatic) {
            if trip.segments.count > 1 {
                ForEach(trip.segments) { s in
                    if let p = s.routePolyline {
                        MapPolyline(coordinates: Polyline.decode(p).map(\.cl)).stroke(s.mode.color, lineWidth: 5)
                    }
                }
            } else if trip.mode == .airplane, let o = origin, let d = destination {
                MapPolyline(MKGeodesicPolyline(coordinates: [o.cl, d.cl], count: 2)).stroke(trip.mode.color, lineWidth: 4)
            } else {
                MapPolyline(coordinates: trip.route.map(\.cl)).stroke(trip.mode.color, lineWidth: 5)
            }
            if let o = origin { Marker("Start", systemImage: "circle", coordinate: o.cl).tint(.gray) }
            if let d = destination { Marker("End", systemImage: "mappin", coordinate: d.cl).tint(.red) }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

/// Insert a stop into a trip.
struct SplitTripSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    @State private var start = Date()
    @State private var end = Date()
    @State private var placeID: String?
    @State private var places: [Place] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Arrived at stop", selection: $start, in: trip.departure...trip.arrival, displayedComponents: [.hourAndMinute])
                    DatePicker("Left stop", selection: $end, in: start...trip.arrival, displayedComponents: [.hourAndMinute])
                } footer: { Text("The trip becomes two trips with a visit in between.") }
                Section("Where") {
                    Picker("Place", selection: $placeID) {
                        Text("Location on route (new place)").tag(String?.none)
                        ForEach(places) { p in Text(p.displayName).tag(String?.some(p.id)) }
                    }
                }
            }
            .navigationTitle("Add stop")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") {
                        model.perform { _ = try model.edit.splitTrip(trip.id, stopStart: start, stopEnd: max(end, start.addingTimeInterval(60)), placeID: placeID) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                let mid = trip.departure.addingTimeInterval(trip.duration / 2)
                start = mid
                end = min(trip.arrival.addingTimeInterval(-30), mid.addingTimeInterval(300))
                places = ((try? model.store.places()) ?? []).filter(\.isNamed)
            }
        }
    }
}
