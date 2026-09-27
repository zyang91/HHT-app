import Foundation
import Testing
@testable import HHTCore

/// home → penn → restaurant → penn → home, all walking.
private func chainDay() -> Trajectory {
    var tr = Trajectory(start: Trajectory.date("2026-09-15 07:00"), at: Philly.home)
    tr.stay(minutes: 60)
    tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
    tr.stay(minutes: 180)
    tr.move(to: Philly.restaurant, speed: 1.3, activity: .walking)
    tr.stay(minutes: 45)
    tr.move(to: Philly.penn, speed: 1.3, activity: .walking)
    tr.stay(minutes: 180)
    tr.move(to: Philly.home, speed: 1.4, activity: .walking)
    tr.stay(minutes: 60)
    return tr
}

private func processed(_ tr: Trajectory, path: String = ":memory:") throws -> (TravelStore, InferenceEngine) {
    let store = try TravelStore(path: path)
    try store.insertPoints(tr.points)
    try store.insertMotion(tr.motion)
    let engine = InferenceEngine(store: store)
    try engine.processNew(now: tr.t.addingTimeInterval(60))
    return (store, engine)
}

@Suite("Editing, persistence, export")
struct EditExportTests {

    @Test func modeEditSurvivesReprocessing() throws {
        let tr = chainDay()
        let (store, engine) = try processed(tr)
        let edit = EditService(store: store)
        let trips = try store.allTrips()
        try edit.setTripMode(trips[0].id, .bicycle)
        try engine.process(from: .distantPast, to: tr.t, now: tr.t.addingTimeInterval(60))
        let after = try store.allTrips()
        #expect(after.count == trips.count)
        #expect(after.first { $0.id == trips[0].id }?.mode == .bicycle)
        #expect(after.first { $0.id == trips[0].id }?.modeAuto == .walk)   // automatic value preserved
        #expect(try store.auditLog(entityID: trips[0].id).contains { $0.action == "set_mode" && $0.newValue == "bicycle" })
    }

    @Test func deleteVisitMergesTripsAndStaysDeleted() throws {
        let tr = chainDay()
        let (store, engine) = try processed(tr)
        let edit = EditService(store: store)
        let visits = try store.allVisits()
        #expect(visits.count == 5)
        let restaurant = visits[2]
        try edit.deleteVisit(restaurant.id)
        var trips = try store.allTrips()
        #expect(trips.count == 3)
        #expect(trips[1].originVisitID == visits[1].id && trips[1].destinationVisitID == visits[3].id)
        // reprocessing must not resurrect the stop
        try engine.process(from: .distantPast, to: tr.t, now: tr.t.addingTimeInterval(60))
        trips = try store.allTrips()
        #expect(try store.allVisits().count == 4)
        #expect(trips.count == 3)
        #expect(try store.visit(restaurant.id)?.deleted == true)           // soft delete, still in DB
    }

    @Test func deleteTripMergesVisits() throws {
        let tr = chainDay()
        let (store, engine) = try processed(tr)
        let edit = EditService(store: store)
        let trips = try store.allTrips()
        // delete penn → restaurant: restaurant visit is absorbed into penn visit
        try edit.deleteTrip(trips[1].id)
        #expect(try store.allTrips().count == 3)
        #expect(try store.allVisits().count == 4)
        try engine.process(from: .distantPast, to: tr.t, now: tr.t.addingTimeInterval(60))
        #expect(try store.allTrips().count == 3)
        let remaining = try store.allTrips()
        #expect(remaining[1].originVisitID == trips[1].originVisitID)       // relinked to surviving visit
    }

    @Test func namedPlaceRecognisedAgain() throws {
        var tr = chainDay()
        let (store, engine) = try processed(tr)
        let edit = EditService(store: store)
        let penn = try store.allVisits()[1]
        let place = try edit.createPlace(forVisit: penn.id, name: "Penn", category: .workSchool, radius: 150)
        // next day: new data, same place
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 120)
        try store.insertPoints(tr.points.filter { $0.timestamp > (store.lastPoint()?.timestamp ?? .distantPast) })
        try store.insertMotion(tr.motion)
        try engine.processNew(now: tr.t.addingTimeInterval(60))
        #expect(try store.allVisits().last?.placeID == place.id)
    }

    @Test func splitVisitAndSplitTrip() throws {
        let tr = chainDay()
        let (store, _) = try processed(tr)
        let edit = EditService(store: store)
        let visits = try store.allVisits()
        let penn = visits[1]
        let leave = penn.arrival.addingTimeInterval(3600), back = leave.addingTimeInterval(1800)
        let created = try edit.splitVisit(penn.id, leave: leave, back: back, mode: .walk)
        #expect(created.count == 1)
        #expect(try store.allVisits().count == 6)
        #expect(try store.allTrips().count == 5)

        let t = try store.allTrips().last!
        let mid = t.departure.addingTimeInterval(t.duration / 2)
        let stop = try edit.splitTrip(t.id, stopStart: mid, stopEnd: mid.addingTimeInterval(1), placeID: nil)
        let all = try store.allTrips()
        #expect(all.count == 6)
        #expect(all.contains { $0.destinationVisitID == stop.id } && all.contains { $0.originVisitID == stop.id })
    }

    @Test func correctionsPersistAcrossRestart() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hht-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tr = chainDay()
        var tripID = ""
        do {
            let (store, _) = try processed(tr, path: path)
            let edit = EditService(store: store)
            tripID = try store.allTrips()[0].id
            try edit.setTripMode(tripID, .ebike)
            try edit.setVisitPurpose(try store.allVisits()[2].id, .meal)
        }
        let reopened = try TravelStore(path: path)
        #expect(try reopened.trip(tripID)?.mode == .ebike)
        #expect(try reopened.allVisits()[2].purpose == .meal)
        #expect(reopened.schemaVersion == 1)
    }

    @Test func personalisedModeFromCorrections() throws {
        // Home→Penn at 8 m/s without motion data looks like a car; the user says e-bike twice.
        var tr = Trajectory(start: Trajectory.date("2026-09-15 07:00"), at: Philly.home)
        tr.stay(minutes: 60, activity: nil)
        for _ in 0..<2 {
            tr.move(to: Philly.penn, speed: 8)
            tr.stay(minutes: 120, activity: nil)
            tr.move(to: Philly.home, speed: 8)
            tr.stay(minutes: 120, activity: nil)
        }
        let (store, engine) = try processed(tr)
        let edit = EditService(store: store)
        let trips = try store.allTrips()
        #expect(trips.count == 4)
        #expect(trips[0].mode == .car)
        for t in trips { try edit.setTripMode(t.id, .ebike) }
        // third commute: learned from corrections
        tr.move(to: Philly.penn, speed: 8)
        tr.stay(minutes: 60, activity: nil)
        try store.insertPoints(tr.points.filter { $0.timestamp > (store.lastPoint()?.timestamp ?? .distantPast) })
        try engine.processNew(now: tr.t.addingTimeInterval(60))
        let last = try store.allTrips().last!
        #expect(last.userStatus == .auto)
        #expect(last.mode == .ebike)
    }

    @Test func exportBundle() throws {
        let tr = chainDay()
        let (store, _) = try processed(tr)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hht-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try Exporter(store: store).exportBundle(to: dir)
        for f in ["trips.csv", "trip_segments.csv", "visits.csv", "places.csv", "flights.csv", "data.json",
                  "places.geojson", "trips.geojson", "trip_ends.geojson", "travel.sqlite", "raw_location_points.csv", "README.txt"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(f).path), "\(f)")
        }
        let trips = CSV.parseRecords(try String(contentsOf: folder.appendingPathComponent("trips.csv"), encoding: .utf8))
        #expect(trips.count == 4)
        #expect(trips.map { $0["trip_seq"] } == ["1", "2", "3", "4"])
        let visits = CSV.parseRecords(try String(contentsOf: folder.appendingPathComponent("visits.csv"), encoding: .utf8))
        let visitIDs = Set(visits.compactMap { $0["visit_id"] })
        #expect(trips.allSatisfy { visitIDs.contains($0["origin_visit_id"] ?? "") && visitIDs.contains($0["destination_visit_id"] ?? "") })
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("data.json"))) as? [String: Any]
        #expect((json?["trips"] as? [Any])?.count == 4)
        let gj = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("trips.geojson"))) as? [String: Any]
        #expect((gj?["features"] as? [Any])?.count == 4)
        // the SQLite snapshot opens and has the same data
        let snap = try TravelStore(path: folder.appendingPathComponent("travel.sqlite").path)
        #expect(try snap.allTrips().count == 4)
        let viewRows = try snap.db.query("SELECT mode_final FROM v_trips")
        #expect(viewRows.count == 4)
    }

    @Test func importTripsAndFlights() throws {
        let store = try TravelStore.inMemory()
        let imp = Importer(store: store)
        let airports = """
        id,ident,type,name,latitude_deg,longitude_deg,elevation_ft,continent,iso_country,iso_region,municipality,scheduled_service,gps_code,iata_code,local_code,home_link,wikipedia_link,keywords
        1,KPHL,large_airport,Philadelphia International Airport,39.871899,-75.241096,36,NA,US,US-PA,Philadelphia,yes,KPHL,PHL,PHL,,,
        2,KSLC,large_airport,Salt Lake City International Airport,40.785749,-111.979746,4227,NA,US,US-UT,Salt Lake City,yes,KSLC,SLC,SLC,,,
        """
        #expect(try imp.importAirports(csv: airports) == 2)
        let res = try imp.importTrips(csv: """
        date,start_time,end_time,origin,destination,mode,distance_km,purpose,notes
        2026-08-18,08:00,10:30,PHL,SLC,airplane,,travel,"first trip, west"
        2026-08-19,23:30,00:15,Somewhere,Elsewhere,car_driver,12.5,,
        """, defaultTimeZone: TimeZone(identifier: "America/New_York")!)
        #expect(res.imported == 2)
        let trips = try store.allTrips()
        #expect(trips.count == 2)
        #expect(trips[0].mode == .airplane && trips[0].distance > 3_000_000)
        #expect(trips[1].duration == 45 * 60)                              // crossed midnight
        #expect(trips[1].notes?.contains("origin: Somewhere") == true)
        #expect(try store.flights().count == 1)
        let f = try imp.importFlights(csv: "date,origin,destination,airline,flight_number\n2026-08-25,SLC,PHL,DL,1234\n")
        #expect(f.imported == 1)
        #expect(Analytics.flightStats(try store.flights()).routes["PHL–SLC"] == 2)
    }

    @Test func gpxImport() throws {
        let store = try TravelStore.inMemory()
        let gpx = """
        <?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
        <trkpt lat="39.95" lon="-75.16"><ele>10</ele><time>2026-01-01T10:00:00Z</time></trkpt>
        <trkpt lat="39.96" lon="-75.17"><time>2026-01-01T10:05:00.500Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let r = try Importer(store: store).importGPX(Data(gpx.utf8))
        #expect(r.count == 2)
        #expect(store.pointCount() == 2)
    }
}

@Suite("Geometry and analytics")
struct GeoAnalyticsTests {
    @Test func polylineRoundTrip() {
        let c = [Coordinate(38.5, -120.2), Coordinate(40.7, -120.95), Coordinate(43.252, -126.453)]
        #expect(Polyline.encode(c) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let d = Polyline.decode(Polyline.encode(c))
        #expect(zip(c, d).allSatisfy { abs($0.latitude - $1.latitude) < 1e-5 && abs($0.longitude - $1.longitude) < 1e-5 })
    }

    @Test func distances() {
        // one degree of longitude on the equator = 2πR/360
        #expect(abs(Geo.distance(Coordinate(0, 0), Coordinate(0, 1)) - 2 * .pi * Geo.earthRadius / 360) < 0.01)
        #expect(abs(Geo.distance(Coordinate(0, 0), Coordinate(90, 0)) - .pi * Geo.earthRadius / 2) < 0.01)
        let rg = Geo.radiusOfGyration([Coordinate(0, 0), Coordinate(0, 0.02)])!
        #expect(abs(rg - Geo.distance(Coordinate(0, 0), Coordinate(0, 0.02)) / 2) < 1)
        let hull = Geo.convexHull([Coordinate(0, 0), Coordinate(0, 0.01), Coordinate(0.01, 0.01), Coordinate(0.01, 0), Coordinate(0.005, 0.005)])
        #expect(hull.hull.count == 4)
        #expect(abs(hull.areaSquareMeters / 1_236_000 - 1) < 0.02)
    }

    @Test func csvParsing() {
        let rows = CSV.parse("a,b\n\"x, y\",\"he said \"\"hi\"\"\"\r\n1,\n")
        #expect(rows == [["a", "b"], ["x, y", "he said \"hi\""], ["1", ""]])
    }

    @Test func metrics() throws {
        let tr = chainDay()
        let (store, _) = try processed(tr)
        let edit = EditService(store: store)
        let v = try store.allVisits()
        try edit.createPlace(forVisit: v[0].id, name: "Home", category: .home)
        try edit.setVisitPlace(v[4].id, placeID: try store.visit(v[0].id)!.placeID!)
        let m = try Analytics.compute(store: store, range: DateRange(start: .distantPast, end: tr.t), now: tr.t)
        #expect(m.trips == 4)
        #expect(m.personDays == 1)
        #expect(m.modeShare.first?.mode == .walk)
        #expect(m.uniquePlaces == 3)
        #expect(m.tours == 1)
        #expect(m.meanStopsPerTour == 3)
        #expect(m.complexTourShare == 1)
        #expect((m.radiusOfGyrationDwell ?? 0) > 500)
        #expect(m.departuresByHour.reduce(0, +) == 4)
        #expect(m.topODPairs.count == 4)
    }
}
