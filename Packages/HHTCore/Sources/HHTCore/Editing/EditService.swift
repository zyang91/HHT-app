import Foundation

public enum EditError: Error, LocalizedError {
    case notFound(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "Not found: \(s)"
        case .invalid(let s): return s
        }
    }
}

/// All user corrections go through here. Each edit:
/// * marks the record `edited` / `manual` (locking it against reprocessing),
/// * soft-deletes instead of hard-deleting,
/// * writes field-level entries to `audit_log`.
public final class EditService {
    public let store: TravelStore
    public init(store: TravelStore) { self.store = store }

    private var db: SQLiteConnection { store.db }

    // MARK: - Lookups

    func visitOrThrow(_ id: String) throws -> Visit {
        guard let v = try store.visit(id) else { throw EditError.notFound("visit \(id)") }
        return v
    }

    func tripOrThrow(_ id: String) throws -> Trip {
        guard let t = try store.trip(id) else { throw EditError.notFound("trip \(id)") }
        return t
    }

    func incomingTrip(_ visitID: String) throws -> Trip? {
        try store.tripsReferencing(visitID: visitID).first { $0.destinationVisitID == visitID }
            .flatMap { try store.trip($0.id) }
    }

    func outgoingTrip(_ visitID: String) throws -> Trip? {
        try store.tripsReferencing(visitID: visitID).first { $0.originVisitID == visitID }
            .flatMap { try store.trip($0.id) }
    }

    private func touch(_ v: inout Visit) {
        v.updatedAt = Date()
        if v.userStatus == .auto || v.userStatus == .confirmed { v.userStatus = .edited }
    }

    private func touch(_ t: inout Trip) {
        t.updatedAt = Date()
        if t.userStatus == .auto || t.userStatus == .confirmed { t.userStatus = .edited }
    }

    // MARK: - Trip mode / purpose

    public func setTripMode(_ tripID: String, _ mode: TravelMode?) throws {
        try db.transaction {
            var t = try tripOrThrow(tripID)
            let old = t.mode
            t.modeUser = mode
            // a single-segment trip's segment follows the trip mode
            if t.segments.count == 1 { t.segments[0].modeUser = mode }
            touch(&t)
            try store.upsertTrip(t)
            try store.audit("trip", tripID, "set_mode", field: "mode_user", old: old.rawValue, new: mode?.rawValue)
        }
    }

    public func setSegmentMode(_ segmentID: String, _ mode: TravelMode?) throws {
        try db.transaction {
            guard let r = try db.query("SELECT trip_id FROM trip_segments WHERE id = ?", segmentID).first,
                  let tripID = r.string("trip_id") else { throw EditError.notFound("segment \(segmentID)") }
            var t = try tripOrThrow(tripID)
            guard let i = t.segments.firstIndex(where: { $0.id == segmentID }) else { throw EditError.notFound("segment") }
            let old = t.segments[i].mode
            t.segments[i].modeUser = mode
            // trip main mode follows the segment hierarchy unless the user set it explicitly
            let main = ModeClassifier.mainMode(t.segments.map { ($0.mode, $0.end.timeIntervalSince($0.start), $0.distance) })
            if t.modeUser == nil || t.segments.count > 1 { t.modeUser = main }
            touch(&t)
            try store.upsertTrip(t)
            try store.audit("trip_segment", segmentID, "set_mode", field: "mode_user", old: old.rawValue, new: mode?.rawValue)
        }
    }

    public func setTripPurpose(_ tripID: String, _ purpose: TripPurpose?) throws {
        try db.transaction {
            var t = try tripOrThrow(tripID)
            let old = t.purpose
            t.purpose = purpose
            touch(&t)
            try store.upsertTrip(t, replaceSegments: false)
            try store.audit("trip", tripID, "set_purpose", field: "purpose", old: old?.rawValue, new: purpose?.rawValue)
        }
    }

    public func setVisitPurpose(_ visitID: String, _ purpose: TripPurpose?) throws {
        try db.transaction {
            var v = try visitOrThrow(visitID)
            let old = v.purpose
            v.purpose = purpose
            touch(&v)
            try store.upsertVisit(v)
            try store.audit("visit", visitID, "set_purpose", field: "purpose", old: old?.rawValue, new: purpose?.rawValue)
        }
    }

    public func setNotes(visitID: String, _ notes: String?) throws {
        var v = try visitOrThrow(visitID)
        let old = v.notes
        v.notes = notes?.isEmpty == true ? nil : notes
        touch(&v)
        try store.upsertVisit(v)
        try store.audit("visit", visitID, "set_notes", field: "notes", old: old, new: v.notes)
    }

    public func setNotes(tripID: String, _ notes: String?) throws {
        var t = try tripOrThrow(tripID)
        let old = t.notes
        t.notes = notes?.isEmpty == true ? nil : notes
        touch(&t)
        try store.upsertTrip(t, replaceSegments: false)
        try store.audit("trip", tripID, "set_notes", field: "notes", old: old, new: t.notes)
    }

    /// Mark as reviewed without changing anything.
    public func confirm(tripID: String) throws {
        var t = try tripOrThrow(tripID)
        guard t.userStatus == .auto else { return }
        t.userStatus = .confirmed
        t.updatedAt = Date()
        try store.upsertTrip(t, replaceSegments: false)
        try store.audit("trip", tripID, "confirm")
    }

    public func confirm(visitID: String) throws {
        var v = try visitOrThrow(visitID)
        guard v.userStatus == .auto else { return }
        v.userStatus = .confirmed
        v.updatedAt = Date()
        try store.upsertVisit(v)
        try store.audit("visit", visitID, "confirm")
    }

    // MARK: - Places

    public func setVisitPlace(_ visitID: String, placeID: String) throws {
        try db.transaction {
            var v = try visitOrThrow(visitID)
            guard let p = try store.place(placeID), !p.deleted else { throw EditError.notFound("place \(placeID)") }
            let old = v.placeID
            v.placeID = placeID
            touch(&v)
            try store.upsertVisit(v)
            try store.audit("visit", visitID, "set_place", field: "place_id", old: old, new: placeID)
            try store.pruneOrphanPlaces()
        }
    }

    /// Create a named place at the visit's location (or given coordinate) and assign it.
    @discardableResult
    public func createPlace(forVisit visitID: String, name: String, category: PlaceCategory?,
                            coordinate: Coordinate? = nil, radius: Double = 80) throws -> Place {
        try db.transaction {
            let v = try visitOrThrow(visitID)
            let p = Place(name: name, coordinate: coordinate ?? v.coordinate, radius: radius, category: category, source: .manual)
            try store.upsertPlace(p)
            try store.audit("place", p.id, "create", field: "name", new: name)
            try setVisitPlace(visitID, placeID: p.id)
            return p
        }
    }

    /// Update any editable place fields; audits each changed field.
    public func updatePlace(_ updated: Place) throws {
        try db.transaction {
            guard let old = try store.place(updated.id) else { throw EditError.notFound("place \(updated.id)") }
            var p = updated
            p.updatedAt = Date()
            if p.source == .inferred && (p.name != old.name || p.category != old.category) { p.source = .manual }
            try store.upsertPlace(p)
            let pairs: [(String, String?, String?)] = [
                ("name", old.name, p.name), ("category", old.category?.rawValue, p.category?.rawValue),
                ("radius_m", String(old.radius), String(p.radius)), ("code", old.code, p.code),
                ("address", old.address, p.address), ("city", old.city, p.city), ("region", old.region, p.region),
                ("country", old.country, p.country), ("notes", old.notes, p.notes),
                ("favorite", String(old.favorite), String(p.favorite)),
                ("lat", String(old.coordinate.latitude), String(p.coordinate.latitude)),
                ("lon", String(old.coordinate.longitude), String(p.coordinate.longitude)),
            ]
            for (f, o, n) in pairs where o != n { try store.audit("place", p.id, "update", field: f, old: o, new: n) }
        }
    }

    /// Merge duplicate places: all visits move to `target`; `source` is kept as a tombstone pointing at it.
    public func mergePlaces(_ sourceID: String, into targetID: String) throws {
        guard sourceID != targetID else { return }
        try db.transaction {
            guard var src = try store.place(sourceID) else { throw EditError.notFound("place \(sourceID)") }
            guard try store.place(targetID) != nil else { throw EditError.notFound("place \(targetID)") }
            let n = try db.run("UPDATE visits SET place_id = ?, updated_at = ? WHERE place_id = ?", targetID, Date(), sourceID)
            try db.run("UPDATE trips SET origin_place_id = ? WHERE origin_place_id = ?", targetID, sourceID)
            try db.run("UPDATE trips SET destination_place_id = ? WHERE destination_place_id = ?", targetID, sourceID)
            try db.run("UPDATE places SET merged_into = ? WHERE merged_into = ?", targetID, sourceID)
            src.mergedInto = targetID
            src.updatedAt = Date()
            try store.upsertPlace(src)
            try store.audit("place", sourceID, "merge", field: "merged_into", old: nil, new: "\(targetID) (\(n) visits)")
        }
    }

    /// "This isn't a real place": every visit there is deleted like "This wasn't a stop" (neighbouring trips
    /// are joined), and the place is soft-deleted so it leaves the place list and is no longer matched.
    public func deletePlace(_ placeID: String) throws {
        try db.transaction {
            guard var p = try store.place(placeID), !p.deleted else { throw EditError.notFound("place \(placeID)") }
            let visits = try store.visits(atPlace: placeID)
            for v in visits { try deleteVisit(v.id) }
            p.deleted = true
            p.updatedAt = Date()
            try store.upsertPlace(p)
            try store.audit("place", placeID, "delete", field: "visits_deleted", new: String(visits.count))
        }
    }

    // MARK: - Times

    /// Change a visit's arrival / departure; neighbouring trips are adjusted to stay contiguous.
    public func setVisitTimes(_ visitID: String, arrival: Date, departure: Date?) throws {
        try db.transaction {
            var v = try visitOrThrow(visitID)
            if let d = departure, d <= arrival { throw EditError.invalid("Departure must be after arrival.") }
            var inc = try incomingTrip(visitID)
            var out = try outgoingTrip(visitID)
            if let t = inc, arrival <= t.departure { throw EditError.invalid("Arrival would be before the previous trip starts.") }
            if let t = out, let d = departure, d >= t.arrival { throw EditError.invalid("Departure would be after the next trip ends.") }
            try store.audit("visit", visitID, "set_times", field: "arrival_ts", old: iso(v.arrival), new: iso(arrival))
            try store.audit("visit", visitID, "set_times", field: "departure_ts", old: iso(v.departure), new: iso(departure))
            v.arrival = arrival
            v.departure = departure
            touch(&v)
            try store.upsertVisit(v)
            if inc != nil {
                inc!.arrival = arrival
                touch(&inc!)
                try store.upsertTrip(inc!, replaceSegments: false)
            }
            if out != nil, let d = departure {
                out!.departure = d
                touch(&out!)
                try store.upsertTrip(out!, replaceSegments: false)
            }
        }
    }

    // MARK: - Delete / merge

    /// "This wasn't a stop": remove the visit and join the trips before and after it into one trip.
    public func deleteVisit(_ visitID: String) throws {
        try db.transaction {
            var v = try visitOrThrow(visitID)
            let inc = try incomingTrip(visitID)
            let out = try outgoingTrip(visitID)
            if var a = inc, let b = out {
                try store.audit("trip", a.id, "merge", field: "absorbed_trip", new: b.id)
                a.arrival = b.arrival
                a.destinationVisitID = b.destinationVisitID
                a.destinationPlaceID = b.destinationPlaceID
                a.distance += b.distance
                a.hasGap = a.hasGap || b.hasGap
                let route = a.route + b.route.dropFirst()
                a.routePolyline = Polyline.encode(route)
                let offset = a.segments.count
                a.segments += b.segments.enumerated().map { i, s in
                    var s = s; s.id = newID(); s.tripID = a.id; s.sequence = offset + i; return s
                }
                a.modeAuto = ModeClassifier.mainMode(a.segments.map { ($0.mode, $0.end.timeIntervalSince($0.start), $0.distance) })
                if a.modeUser != nil || b.modeUser != nil {
                    a.modeUser = ModeClassifier.mainMode([(a.mode, a.duration, a.distance), (b.mode, b.duration, b.distance)])
                }
                if a.notes == nil { a.notes = b.notes } else if let bn = b.notes { a.notes = a.notes! + "\n" + bn }
                touch(&a)
                try store.upsertTrip(a)
                try softDelete(trip: b)
            } else if let only = inc ?? out {
                // stop at the edge of the data: the dangling trip goes too
                try softDelete(trip: only)
            }
            v.deleted = true
            touch(&v)
            try store.upsertVisit(v)
            try store.audit("visit", visitID, "delete")
        }
    }

    /// "This trip didn't happen": remove it and join the visits on either side (the origin visit survives).
    public func deleteTrip(_ tripID: String) throws {
        try db.transaction {
            let t = try tripOrThrow(tripID)
            if let oID = t.originVisitID, let dID = t.destinationVisitID,
               var a = try store.visit(oID), var b = try store.visit(dID) {
                a.departure = b.departure
                if a.notes == nil { a.notes = b.notes }
                touch(&a)
                try store.upsertVisit(a)
                try store.audit("visit", a.id, "merge", field: "absorbed_visit", new: b.id)
                if var next = try outgoingTrip(b.id) {
                    next.originVisitID = a.id
                    touch(&next)
                    try store.upsertTrip(next, replaceSegments: false)
                    try store.audit("trip", next.id, "relink", field: "origin_visit_id", old: b.id, new: a.id)
                }
                b.deleted = true
                touch(&b)
                try store.upsertVisit(b)
                try store.audit("visit", b.id, "delete")
            }
            try softDelete(trip: t)
        }
    }

    private func softDelete(trip t: Trip) throws {
        var t = t
        t.deleted = true
        touch(&t)
        try store.upsertTrip(t, replaceSegments: false)
        try db.run("UPDATE flights SET trip_id = NULL WHERE trip_id = ?", t.id)
        try store.audit("trip", t.id, "delete")
    }

    // MARK: - Split / insert

    /// Split a trip by inserting a stop between `stopStart` and `stopEnd`, at `placeID`, else at `coordinate`
    /// (picked on the map), else at the GPS position around `stopStart` — which can be far off inside a GPS gap.
    @discardableResult
    public func splitTrip(_ tripID: String, stopStart: Date, stopEnd: Date, placeID: String? = nil,
                          at coordinate: Coordinate? = nil) throws -> Visit {
        try db.transaction {
            var t = try tripOrThrow(tripID)
            guard stopStart > t.departure, stopEnd < t.arrival, stopEnd >= stopStart else {
                throw EditError.invalid("The stop must lie inside the trip.")
            }
            let raw = try store.points(from: t.departure, to: t.arrival)
            let atStop = raw.filter { $0.timestamp >= stopStart && $0.timestamp <= stopEnd }.map(\.coordinate)
            let nearest = raw.min { abs($0.timestamp.timeIntervalSince(stopStart)) < abs($1.timestamp.timeIntervalSince(stopStart)) }
            let place = try placeID.flatMap(store.place)
            let coord = place?.coordinate ?? coordinate ?? Geo.centroid(atStop) ?? nearest?.coordinate
                ?? t.route.dropFirst(t.route.count / 2).first ?? Coordinate(0, 0)

            var resolvedPlace = place
            if resolvedPlace == nil {
                resolvedPlace = try store.matchPlace(coord, slack: 40)
            }
            if resolvedPlace == nil {
                let p = Place(coordinate: coord, radius: 80, source: .manual)
                try store.upsertPlace(p)
                resolvedPlace = p
            }
            let stop = Visit(placeID: resolvedPlace!.id, arrival: stopStart, departure: stopEnd, coordinate: coord,
                             source: .manual, userStatus: .manual, timeZone: t.timeZone)
            try store.upsertVisit(stop)

            let origin = try t.originVisitID.flatMap(store.visit)?.coordinate
            let dest = try t.destinationVisitID.flatMap(store.visit)?.coordinate
            let firstPath = [origin].compactMap { $0 } + raw.filter { $0.timestamp < stopStart }.map(\.coordinate) + [coord]
            let secondPath = [coord] + raw.filter { $0.timestamp > stopEnd }.map(\.coordinate) + [dest].compactMap { $0 }

            var second = Trip(originVisitID: stop.id, destinationVisitID: t.destinationVisitID,
                              destinationPlaceID: t.destinationPlaceID, departure: stopEnd, arrival: t.arrival,
                              distance: Geo.pathLength(secondPath), modeAuto: t.modeAuto, modeConfidence: t.modeConfidence,
                              modeUser: t.modeUser, purpose: nil, routePolyline: Polyline.encode(Geo.simplify(secondPath, tolerance: 8)),
                              hasGap: t.hasGap, autoConfidence: t.autoConfidence, source: .manual, userStatus: .manual,
                              timeZone: t.timeZone)
            second.segments = splitSegments(t.segments, from: stopEnd, to: t.arrival, tripID: second.id)

            t.arrival = stopStart
            t.destinationVisitID = stop.id
            t.destinationPlaceID = nil
            t.distance = Geo.pathLength(firstPath)
            t.routePolyline = Polyline.encode(Geo.simplify(firstPath, tolerance: 8))
            t.segments = splitSegments(t.segments, from: t.departure, to: stopStart, tripID: t.id)
            touch(&t)
            try store.upsertTrip(t)
            try store.upsertTrip(second)
            try store.audit("trip", t.id, "split", field: "new_visit", new: stop.id)
            try store.audit("trip", second.id, "create", field: "split_from", new: t.id)
            return stop
        }
    }

    private func splitSegments(_ segs: [TripSegment], from: Date, to: Date, tripID: String) -> [TripSegment] {
        let kept = segs.filter { $0.end > from && $0.start < to }
        return kept.enumerated().map { i, s in
            var s = s
            let full = max(1, s.end.timeIntervalSince(s.start))
            let ns = max(s.start, from), ne = min(s.end, to)
            s.distance *= ne.timeIntervalSince(ns) / full
            s.start = ns; s.end = ne; s.id = newID(); s.tripID = tripID; s.sequence = i
            return s
        }
    }

    /// Split a visit: "I left at `leave` and came back at `back`", optionally with a stop somewhere in between.
    /// Returns the created trips.
    @discardableResult
    public func splitVisit(_ visitID: String, leave: Date, back: Date, stop: (placeID: String, arrival: Date, departure: Date)? = nil,
                           mode: TravelMode? = nil) throws -> [Trip] {
        try db.transaction {
            var v = try visitOrThrow(visitID)
            let end = v.departure ?? .distantFuture
            guard leave > v.arrival, back < end, back > leave else { throw EditError.invalid("Times must lie inside the visit.") }
            if let s = stop, !(s.arrival > leave && s.departure < back && s.departure >= s.arrival) {
                throw EditError.invalid("The stop must lie between leaving and returning.")
            }
            let out = try outgoingTrip(visitID)
            let second = Visit(placeID: v.placeID, arrival: back, departure: v.departure, coordinate: v.coordinate,
                               purpose: v.purpose, source: .manual, userStatus: .manual, timeZone: v.timeZone)
            try store.upsertVisit(second)
            v.departure = leave
            touch(&v)
            try store.upsertVisit(v)

            var created: [Trip] = []
            func manualTrip(_ a: Visit, _ b: Visit) throws {
                let d = Geo.distance(a.coordinate, b.coordinate)
                let t = Trip(originVisitID: a.id, destinationVisitID: b.id, departure: a.departure!, arrival: b.arrival,
                             distance: d, modeAuto: nil, modeConfidence: nil, modeUser: mode,
                             routePolyline: Polyline.encode([a.coordinate, b.coordinate]), source: .manual,
                             userStatus: .manual, timeZone: a.timeZone)
                try store.upsertTrip(t)
                try store.audit("trip", t.id, "create")
                created.append(t)
            }
            if let s = stop {
                guard let p = try store.place(s.placeID) else { throw EditError.notFound("place \(s.placeID)") }
                let mid = Visit(placeID: p.id, arrival: s.arrival, departure: s.departure, coordinate: p.coordinate,
                                purpose: p.category?.defaultPurpose, source: .manual, userStatus: .manual, timeZone: v.timeZone)
                try store.upsertVisit(mid)
                try manualTrip(v, mid)
                try manualTrip(mid, second)
            } else {
                try manualTrip(v, second)
            }
            if var o = out {
                o.originVisitID = second.id
                touch(&o)
                try store.upsertTrip(o, replaceSegments: false)
            }
            try store.audit("visit", visitID, "split", field: "new_visit", new: second.id)
            return created
        }
    }

    // MARK: - Manual records

    /// Record a trip with no sensor data (forgotten phone, historical entry).
    @discardableResult
    public func addManualTrip(originPlaceID: String?, destinationPlaceID: String?, departure: Date, arrival: Date,
                              mode: TravelMode, purpose: TripPurpose? = nil, distance: Double? = nil,
                              notes: String? = nil, source: RecordSource = .manual) throws -> Trip {
        guard arrival > departure else { throw EditError.invalid("Arrival must be after departure.") }
        let o = try originPlaceID.flatMap(store.place)
        let d = try destinationPlaceID.flatMap(store.place)
        var dist = distance
        if dist == nil, let o, let d { dist = Geo.distance(o.coordinate, d.coordinate) }
        let route = [o?.coordinate, d?.coordinate].compactMap { $0 }
        let t = Trip(originVisitID: nil, destinationVisitID: nil, originPlaceID: originPlaceID,
                     destinationPlaceID: destinationPlaceID, departure: departure, arrival: arrival, distance: dist ?? 0,
                     modeAuto: nil, modeConfidence: nil, modeUser: mode, purpose: purpose,
                     routePolyline: route.count == 2 ? Polyline.encode(route) : nil, source: source,
                     userStatus: .manual, notes: notes)
        try store.upsertTrip(t)
        try store.audit("trip", t.id, "create", field: "source", new: source.rawValue)
        return t
    }

    @discardableResult
    public func addManualVisit(placeID: String, arrival: Date, departure: Date?, purpose: TripPurpose? = nil) throws -> Visit {
        guard let p = try store.place(placeID) else { throw EditError.notFound("place \(placeID)") }
        if let d = departure, d <= arrival { throw EditError.invalid("Departure must be after arrival.") }
        let v = Visit(placeID: p.id, arrival: arrival, departure: departure, coordinate: p.coordinate, purpose: purpose,
                      source: .manual, userStatus: .manual)
        try store.upsertVisit(v)
        try store.audit("visit", v.id, "create")
        return v
    }
}
