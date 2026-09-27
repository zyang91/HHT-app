import Foundation
import Testing
@testable import HHTCore

private func run(_ traj: Trajectory, now: Date? = nil) throws -> (TravelStore, [Visit], [Trip]) {
    let store = try makeStore(traj)
    let engine = InferenceEngine(store: store)
    try engine.processNew(now: now ?? traj.t.addingTimeInterval(60))
    return (store, try store.allVisits(), try store.allTrips(withSegments: true))
}

private func minutes(_ a: Date, _ b: Date) -> Double { abs(a.timeIntervalSince(b)) / 60 }

@Suite("Inference fixtures")
struct InferenceTests {

    // 1. home → work → home
    @Test func homeWorkHome() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-14 00:00"), at: Philly.home)
        tr.stay(minutes: 8 * 60 + 10)                                  // until 08:10
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)      // ~29 min walk
        let arrivePenn = tr.t
        tr.stay(minutes: 8 * 60)
        let leavePenn = tr.t
        tr.move(to: Philly.home, speed: 1.4, activity: .walking)
        tr.stay(minutes: 120)
        let (_, visits, trips) = try run(tr)

        #expect(visits.count == 3)
        #expect(trips.count == 2)
        #expect(trips.allSatisfy { $0.mode == .walk })
        #expect(minutes(visits[1].arrival, arrivePenn) < 2)
        #expect(minutes(visits[1].departure!, leavePenn) < 2)
        #expect(visits[0].placeID == visits[2].placeID)              // same home place recognised
        #expect(visits.last!.departure == nil)                        // still home
        #expect(trips[0].distance > 2200 && trips[0].distance < 2800) // ~2.4 km
    }

    // 2. home → work → restaurant → work → home
    @Test func tripChain() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-15 07:00"), at: Philly.home)
        tr.stay(minutes: 60)
        tr.move(to: Philly.penn, speed: 9, activity: .automotive)
        tr.stay(minutes: 240)
        tr.move(to: Philly.restaurant, speed: 1.3, activity: .walking)
        tr.stay(minutes: 45)
        tr.move(to: Philly.penn, speed: 1.3, activity: .walking)
        tr.stay(minutes: 240)
        tr.move(to: Philly.home, speed: 9, activity: .automotive)
        tr.stay(minutes: 60)
        let (_, visits, trips) = try run(tr)
        #expect(visits.count == 5)
        #expect(trips.count == 4)
        #expect(visits[1].placeID == visits[3].placeID)
        #expect(trips.map(\.mode) == [.car, .walk, .walk, .car])
        // contiguous chain
        for i in 0..<trips.count {
            #expect(trips[i].originVisitID == visits[i].id)
            #expect(trips[i].destinationVisitID == visits[i + 1].id)
        }
    }

    // 3. walking trip without motion data: speed-only classification
    @Test func walkingSpeedOnly() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-16 09:00"), at: Philly.home)
        tr.stay(minutes: 30, activity: nil)
        tr.move(to: Philly.grocery, speed: 1.3)
        tr.stay(minutes: 20, activity: nil)
        let (_, _, trips) = try run(tr)
        #expect(trips.count == 1)
        #expect(trips[0].mode == .walk)
    }

    // 4. subway: walk, underground (no GPS, automotive motion), walk
    @Test func subwayTrip() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-17 08:00"), at: Philly.home)
        tr.stay(minutes: 30)
        tr.move(to: Coordinate(39.9530, -75.1680), speed: 1.4, activity: .walking)
        tr.move(to: Coordinate(39.9545, -75.1890), speed: 9, activity: .automotive, noGPS: true)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 60)
        let (_, visits, trips) = try run(tr)
        #expect(visits.count == 2)
        try #require(trips.count == 1)
        let t = trips[0]
        #expect(t.segments.count == 3)
        #expect(t.segments.first?.mode == .walk && t.segments.last?.mode == .walk)
        #expect(t.mode == .subway)
    }

    // 5. car trip
    @Test func carTrip() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-18 10:00"), at: Philly.home)
        tr.stay(minutes: 30)
        tr.move(to: Philly.phl, speed: 15, activity: .automotive)
        tr.stay(minutes: 30)
        let (_, _, trips) = try run(tr)
        #expect(trips.count == 1)
        #expect(trips[0].mode == .car)
        #expect(trips[0].segments.count == 1)
    }

    // 6. multimodal: walk → vehicle → walk
    @Test func multimodal() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-19 08:00"), at: Philly.home)
        tr.stay(minutes: 30)
        tr.move(to: Coordinate(39.9546, -75.1640), speed: 1.4, activity: .walking)   // ~250 m access walk
        tr.move(to: Coordinate(39.9540, -75.1900), speed: 7, activity: .automotive)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 60)
        let (_, _, trips) = try run(tr)
        #expect(trips.count == 1)
        #expect(trips[0].segments.map(\.mode) == [.walk, .car, .walk])
        #expect(trips[0].mode == .car)
    }

    // 7. brief stop should not become a visit
    @Test func briefStopIgnored() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-20 12:00"), at: Philly.home)
        tr.stay(minutes: 30)
        tr.move(to: Philly.grocery, speed: 1.4, activity: .walking)
        tr.stay(minutes: 3, denseMinutes: 3)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 30)
        let (_, visits, trips) = try run(tr)
        #expect(visits.count == 2)
        #expect(trips.count == 1)
    }

    // 8. long stationary period with a single fix
    @Test func longStationary() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-21 18:00"), at: Philly.home)
        tr.stay(minutes: 14 * 60, denseMinutes: 1)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 30)
        let (_, visits, _) = try run(tr)
        #expect(visits.count == 2)
        #expect(visits[0].duration() > 13.5 * 3600)
    }

    // 9. GPS drift while stationary: a single 300 m spike must not create a trip
    @Test func driftWhileStationary() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-22 09:00"), at: Philly.home)
        tr.stay(minutes: 10, denseMinutes: 10)
        tr.emit(Geo.unproject((300, 0), origin: Philly.home), speed: 0, acc: 60, mode: "moving")
        tr.t = tr.t.addingTimeInterval(30)
        tr.stay(minutes: 30, denseMinutes: 10)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 30)
        let (_, visits, trips) = try run(tr)
        #expect(visits.count == 2)
        #expect(trips.count == 1)
    }

    // 10. missing GPS mid-trip
    @Test func missingInterval() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-23 09:00"), at: Philly.home)
        tr.stay(minutes: 30)
        tr.move(to: Coordinate(39.99, -75.20), speed: 12, activity: .automotive)
        tr.move(to: Coordinate(40.10, -75.30), speed: 12, activity: .automotive, noGPS: true)   // ~25 min silent
        tr.move(to: Coordinate(40.12, -75.32), speed: 12, activity: .automotive)
        tr.stay(minutes: 30)
        let (_, visits, trips) = try run(tr)
        #expect(visits.count == 2)
        #expect(trips.count == 1)
        #expect(trips[0].hasGap)
        // 25 silent minutes at urban speed is ambiguous (tunnel vs. dead GPS): vehicle either way
        #expect([.car, .subway].contains(trips[0].mode))
        #expect(trips[0].needsReview)
    }

    // 11 + 12. overnight visit and a trip crossing midnight
    @Test func crossingMidnight() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-24 21:30"), at: Philly.penn)
        tr.stay(minutes: 130)                                        // until 23:40
        tr.move(to: Philly.home, speed: 1.4, activity: .walking)     // arrives ~00:10
        tr.stay(minutes: 8 * 60)
        let (store, visits, trips) = try run(tr)
        #expect(trips.count == 1)
        let day1 = DateRange.day(Trajectory.date("2026-09-24 12:00"), calendar: nyCalendar)
        let day2 = DateRange.day(Trajectory.date("2026-09-25 12:00"), calendar: nyCalendar)
        #expect(try store.trips(overlapping: day1.start, day1.end).count == 1)
        #expect(try store.trips(overlapping: day2.start, day2.end).count == 1)
        #expect(try store.visits(overlapping: day2.start, day2.end).contains { $0.id == visits[1].id })
        // person-day is the local date of departure
        let csv = try Exporter(store: store).tripsCSV(range: nil)
        #expect(csv.contains("2026-09-24,\(trips[0].id),1,"))
    }

    // 13. airport → flight → airport
    @Test func flight() throws {
        var tr = Trajectory(start: Trajectory.date("2026-08-18 06:00"), at: Philly.phl)
        tr.stay(minutes: 90)
        tr.move(to: Philly.slc, speed: 230, noGPS: true)             // airplane mode
        tr.tz = "America/Denver"
        tr.stay(minutes: 60)
        let (store, visits, trips) = try run(tr)
        #expect(visits.count == 2)
        try #require(trips.count == 1)
        #expect(trips[0].mode == .airplane)
        let flights = try store.flights()
        #expect(flights.count == 1)
        #expect(flights[0].tripID == trips[0].id)
        #expect((flights[0].distance ?? 0) > 3_000_000)
    }

    // 14. several days without opening the app, and incremental == one-shot (no duplicates)
    @Test func multiDayIncrementalMatchesOneShot() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-01 00:00"), at: Philly.home)
        for _ in 0..<3 {
            tr.stay(minutes: 8 * 60)
            tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
            tr.stay(minutes: 8 * 60)
            tr.move(to: Philly.home, speed: 1.4, activity: .walking)
            tr.stay(minutes: 8 * 60 - 58)
        }
        let (_, oneShotVisits, oneShotTrips) = try run(tr)
        #expect(oneShotTrips.count == 6)
        #expect(oneShotVisits.count == 7)

        // incremental: run every 2 hours as data "arrives"
        let store = try TravelStore.inMemory()
        let engine = InferenceEngine(store: store)
        try store.insertMotion(tr.motion)
        var cursor = tr.points.first!.timestamp
        while cursor <= tr.t {
            let next = cursor.addingTimeInterval(2 * 3600)
            try store.insertPoints(tr.points.filter { $0.timestamp >= cursor && $0.timestamp < next })
            try engine.processNew(now: next)
            cursor = next
        }
        try engine.processNew(now: tr.t.addingTimeInterval(60))
        let v = try store.allVisits(), t = try store.allTrips()
        #expect(v.count == oneShotVisits.count)
        #expect(t.count == oneShotTrips.count)
        for (a, b) in zip(t, oneShotTrips) { #expect(minutes(a.departure, b.departure) < 1) }
        // running again changes nothing
        let ids = Set(t.map(\.id))
        try engine.processNew(now: tr.t.addingTimeInterval(120))
        #expect(Set(try store.allTrips().map(\.id)) == ids)
    }

    // Reprocessing a whole range keeps the same result (idempotent) and never duplicates.
    @Test func fullReprocessIsIdempotent() throws {
        var tr = Trajectory(start: Trajectory.date("2026-09-15 07:00"), at: Philly.home)
        tr.stay(minutes: 60)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)
        tr.stay(minutes: 120)
        tr.move(to: Philly.home, speed: 1.4, activity: .walking)
        tr.stay(minutes: 60)
        let (store, visits, trips) = try run(tr)
        let engine = InferenceEngine(store: store)
        try engine.process(from: .distantPast, to: tr.t, now: tr.t.addingTimeInterval(60))
        try engine.process(from: .distantPast, to: tr.t, now: tr.t.addingTimeInterval(60))
        #expect(try store.allVisits().map(\.id) == visits.map(\.id))   // stable IDs for visits
        #expect(try store.allTrips().count == trips.count)
    }

    // DST: 2026-11-01 01:30 EDT → EST; duration must use UTC, not wall-clock.
    @Test func daylightSaving() throws {
        let start = Trajectory.date("2026-11-01 00:30")
        var tr = Trajectory(start: start, at: Philly.home)
        tr.stay(minutes: 60)
        tr.move(to: Philly.penn, speed: 1.4, activity: .walking)     // spans the repeated 01:xx hour
        tr.stay(minutes: 60)
        let (_, _, trips) = try run(tr)
        #expect(trips.count == 1)
        let expected = Geo.distance(Philly.home, Philly.penn) / 1.4
        #expect(abs(trips[0].duration - expected) < 60)
    }
}

let nyCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}()
