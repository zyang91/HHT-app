import Foundation

/// Imports: historical trips CSV, flights CSV, GPX tracks, and the OurAirports reference table.
/// Formats: docs/import-formats.md.
public final class Importer {
    public let store: TravelStore
    public init(store: TravelStore) { self.store = store }

    public struct Result: Equatable, Sendable {
        public var imported = 0
        public var skipped = 0
        public var messages: [String] = []
    }

    // MARK: - Airports (OurAirports airports.csv)

    public static let ourAirportsURL = URL(string: "https://davidmegginson.github.io/ourairports-data/airports.csv")!

    /// Load large/medium airports with an IATA code. Replaces the table.
    @discardableResult
    public func importAirports(csv text: String) throws -> Int {
        let records = CSV.parseRecords(text)
        var n = 0
        try store.db.transaction {
            try store.db.run("DELETE FROM airports")
            for r in records {
                guard let iata = r["iata_code"], iata.count == 3, let type = r["type"],
                      type == "large_airport" || type == "medium_airport" || type == "small_airport",
                      r["scheduled_service"] == "yes" || type == "large_airport",
                      let lat = r["latitude_deg"].flatMap(Double.init), let lon = r["longitude_deg"].flatMap(Double.init)
                else { continue }
                try store.db.run("INSERT OR REPLACE INTO airports(iata, icao, name, municipality, country, lat, lon, type) VALUES (?,?,?,?,?,?,?,?)",
                                 iata.uppercased(), r["gps_code"] ?? r["ident"], r["name"] ?? iata, r["municipality"],
                                 r["iso_country"], lat, lon, type)
                n += 1
            }
        }
        return n
    }

    public struct Airport: Equatable, Sendable {
        public var iata: String
        public var name: String
        public var municipality: String?
        public var country: String?
        public var coordinate: Coordinate
    }

    public func airport(_ code: String) -> Airport? {
        guard let r = try? store.db.query("SELECT * FROM airports WHERE iata = ?", code.uppercased()).first else { return nil }
        return Airport(iata: r.string("iata") ?? code, name: r.string("name") ?? code, municipality: r.string("municipality"),
                       country: r.string("country"), coordinate: Coordinate(r.double("lat") ?? 0, r.double("lon") ?? 0))
    }

    public func airportCount() -> Int { (try? store.db.scalar("SELECT COUNT(*) FROM airports").description).flatMap { Int($0) } ?? 0 }

    /// Find or create the Place for an airport code (category airport).
    public func airportPlace(_ code: String) throws -> Place? {
        let c = code.uppercased()
        if let r = try store.db.query("SELECT * FROM places WHERE code = ? AND merged_into IS NULL LIMIT 1", c).first {
            return TravelStore.place(r)
        }
        guard let a = airport(c) else { return nil }
        if let existing = try store.matchPlace(a.coordinate, slack: 1500), existing.category == .airport {
            var p = existing
            if p.code == nil { p.code = c; try store.upsertPlace(p) }
            return p
        }
        let p = Place(name: a.name, coordinate: a.coordinate, radius: 1500, city: a.municipality, country: a.country,
                      category: .airport, code: c, source: .importedCSV)
        try store.upsertPlace(p)
        return p
    }

    // MARK: - Place resolution for CSV rows

    func resolvePlace(name: String?, lat: String?, lon: String?) throws -> Place? {
        if let name, name.count == 3, name == name.uppercased(), let p = try airportPlace(name) { return p }
        if let name, let r = try store.db.query("""
            SELECT * FROM places WHERE merged_into IS NULL AND (name = ? COLLATE NOCASE OR code = ? COLLATE NOCASE) LIMIT 1
            """, name, name).first {
            return TravelStore.place(r)
        }
        if let la = lat.flatMap(Double.init), let lo = lon.flatMap(Double.init) {
            let c = Coordinate(la, lo)
            if let p = try store.matchPlace(c, slack: 50) { return p }
            let p = Place(name: name, coordinate: c, radius: 100, source: .importedCSV)
            try store.upsertPlace(p)
            return p
        }
        return nil
    }

    static func parseDateTime(date: String, time: String?, tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            let s = time.map { fmt.contains("'T'") ? "\(date)T\($0)" : "\(date) \($0)" } ?? date
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Trips CSV

    /// Columns: date,start_time,end_time,origin,destination,mode,distance_km,purpose,notes
    /// Optional: origin_lat,origin_lon,destination_lat,destination_lon,tz
    public func importTrips(csv text: String, defaultTimeZone: TimeZone = .current) throws -> Result {
        var res = Result()
        let edit = EditService(store: store)
        for (i, r) in CSV.parseRecords(text).enumerated() {
            let line = i + 2
            let tz = r["tz"].flatMap(TimeZone.init(identifier:)) ?? defaultTimeZone
            guard let date = r["date"], let dep = Self.parseDateTime(date: date, time: r["start_time"], tz: tz) else {
                res.skipped += 1; res.messages.append("line \(line): missing/invalid date or start_time"); continue
            }
            var arr = r["end_time"].flatMap { Self.parseDateTime(date: date, time: $0, tz: tz) } ?? dep.addingTimeInterval(60)
            if arr <= dep { arr = arr.addingTimeInterval(86_400) }   // crosses midnight
            let o = try resolvePlace(name: r["origin"], lat: r["origin_lat"], lon: r["origin_lon"])
            let d = try resolvePlace(name: r["destination"], lat: r["destination_lat"], lon: r["destination_lon"])
            let mode = r["mode"].flatMap { TravelMode(rawValue: $0.lowercased()) } ?? .unknown
            let purpose = r["purpose"].flatMap { TripPurpose(rawValue: $0.lowercased()) }
            var notes = r["notes"]
            let unresolved = [("origin", r["origin"], o), ("destination", r["destination"], d)]
                .compactMap { k, name, p in p == nil ? name.map { "\(k): \($0)" } : nil }
            if !unresolved.isEmpty { notes = ([notes].compactMap { $0 } + unresolved).joined(separator: "; ") }
            var t = try edit.addManualTrip(originPlaceID: o?.id, destinationPlaceID: d?.id, departure: dep, arrival: arr,
                                           mode: mode, purpose: purpose, distance: r["distance_km"].flatMap(Double.init).map { $0 * 1000 },
                                           notes: notes, source: .importedCSV)
            t.timeZone = tz.identifier
            try store.upsertTrip(t, replaceSegments: false)
            if mode == .airplane, let oc = r["origin"], let dc = r["destination"] {
                _ = try importFlightRow(["date": date, "origin": oc, "destination": dc, "departure_time": r["start_time"] ?? "",
                                         "arrival_time": r["end_time"] ?? ""], tz: tz, tripID: t.id)
            }
            res.imported += 1
        }
        return res
    }

    // MARK: - Flights CSV

    /// Columns: date,origin,destination[,departure_time,arrival_time,airline,flight_number,aircraft_type,seat,cabin,notes,tz]
    public func importFlights(csv text: String, defaultTimeZone: TimeZone = .current) throws -> Result {
        var res = Result()
        for (i, r) in CSV.parseRecords(text).enumerated() {
            let tz = r["tz"].flatMap(TimeZone.init(identifier:)) ?? defaultTimeZone
            if try importFlightRow(r, tz: tz, tripID: nil) {
                res.imported += 1
            } else {
                res.skipped += 1
                res.messages.append("line \(i + 2): need date, origin and destination")
            }
        }
        return res
    }

    func importFlightRow(_ r: [String: String], tz: TimeZone, tripID: String?) throws -> Bool {
        guard let date = r["date"], let o = r["origin"]?.uppercased(), let d = r["destination"]?.uppercased() else { return false }
        let oa = airport(o), da = airport(d)
        let dep = r["departure_time"].flatMap { $0.isEmpty ? nil : Self.parseDateTime(date: date, time: $0, tz: tz) }
        var arr = r["arrival_time"].flatMap { $0.isEmpty ? nil : Self.parseDateTime(date: date, time: $0, tz: tz) }
        if let a = arr, let dp = dep, a <= dp { arr = a.addingTimeInterval(86_400) }
        _ = try airportPlace(o); _ = try airportPlace(d)
        let f = Flight(tripID: tripID, date: date, originCode: o, destinationCode: d, origin: oa?.coordinate,
                       destination: da?.coordinate, departure: dep, arrival: arr, airline: r["airline"],
                       flightNumber: r["flight_number"], aircraftType: r["aircraft_type"], seat: r["seat"], cabin: r["cabin"],
                       notes: r["notes"], source: .importedCSV)
        try store.upsertFlight(f)
        return true
    }

    // MARK: - GPX

    /// Import track points from a GPX file as raw observations (source `imported_gpx`). Returns the time span.
    public func importGPX(_ data: Data) throws -> (count: Int, start: Date?, end: Date?) {
        let parser = GPXParser(data: data)
        let pts = parser.parse()
        try store.insertPoints(pts)
        return (pts.count, pts.map(\.timestamp).min(), pts.map(\.timestamp).max())
    }
}

final class GPXParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var points: [RawPoint] = []
    private var lat: Double?, lon: Double?, ele: Double?, time: Date?
    private var text = ""
    private let iso1 = ISO8601DateFormatter()
    private let iso2: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(data: Data) { parser = XMLParser(data: data) }

    func parse() -> [RawPoint] {
        parser.delegate = self
        parser.parse()
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "trkpt" || name == "rtept" || name == "wpt" {
            lat = attributes["lat"].flatMap(Double.init); lon = attributes["lon"].flatMap(Double.init)
            ele = nil; time = nil
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "ele": ele = Double(t)
        case "time": time = iso1.date(from: t) ?? iso2.date(from: t)
        case "trkpt", "rtept", "wpt":
            if let lat, let lon, let time {
                points.append(RawPoint(timestamp: time, coordinate: Coordinate(lat, lon), horizontalAccuracy: 20, altitude: ele,
                                       source: "imported_gpx", collectorMode: nil, timeZone: nil))
            }
        default: break
        }
    }
}
