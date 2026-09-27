import Foundation
@testable import HHTCore

/// Deterministic synthetic trajectory generator that mimics the app's adaptive collector:
/// dense fixes while moving, a few fixes then silence while stationary.
struct Trajectory {
    var t: Date
    var here: Coordinate
    var points: [RawPoint] = []
    var motion: [MotionSample] = []
    var rng = SplitMix(seed: 42)
    var tz = "America/New_York"

    init(start: Date, at c: Coordinate) { t = start; here = c }

    static func date(_ s: String, tz: String = "America/New_York") -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    mutating func jitter(_ c: Coordinate, meters: Double) -> Coordinate {
        let dx = (rng.nextDouble() * 2 - 1) * meters, dy = (rng.nextDouble() * 2 - 1) * meters
        return Geo.unproject((dx, dy), origin: c)
    }

    mutating func emit(_ c: Coordinate, speed: Double? = nil, acc: Double = 10, mode: String, source: String = "gps") {
        points.append(RawPoint(timestamp: t, coordinate: c, horizontalAccuracy: acc, speed: speed, source: source,
                               collectorMode: mode, timeZone: tz))
    }

    /// Stay: fixes every 30 s for `denseMinutes`, then the collector goes quiet (stationary mode).
    mutating func stay(minutes: Double, denseMinutes: Double = 3, drift: Double = 15, activity: MotionSample.Activity? = .stationary) {
        if let a = activity { motion.append(MotionSample(timestamp: t, activity: a, confidence: 2)) }
        let end = t.addingTimeInterval(minutes * 60)
        let denseEnd = min(end, t.addingTimeInterval(denseMinutes * 60))
        while t < denseEnd {
            emit(jitter(here, meters: drift), speed: 0, mode: "moving")
            t = t.addingTimeInterval(30)
        }
        if t < end {
            emit(jitter(here, meters: drift), speed: 0, mode: "stationary")
            t = end
        }
    }

    /// Straight-line movement to `dest` at `speed` m/s with a fix every `interval` s.
    mutating func move(to dest: Coordinate, speed: Double, interval: Double = 15,
                       activity: MotionSample.Activity? = nil, noGPS: Bool = false) {
        let d = Geo.distance(here, dest)
        let dur = d / speed
        if let a = activity { motion.append(MotionSample(timestamp: t, activity: a, confidence: 2)) }
        let start = t, origin = here
        let o = Geo.project(origin, origin: origin), e = Geo.project(dest, origin: origin)
        var elapsed = interval
        while elapsed < dur {
            t = start.addingTimeInterval(elapsed)
            if !noGPS {
                let f = elapsed / dur
                let p = Geo.unproject((o.x + (e.x - o.x) * f, o.y + (e.y - o.y) * f), origin: origin)
                emit(jitter(p, meters: 5), speed: speed, mode: "moving")
            }
            elapsed += interval
        }
        t = start.addingTimeInterval(dur)
        here = dest
    }

    mutating func gap(minutes: Double) { t = t.addingTimeInterval(minutes * 60) }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum Philly {
    static let home = Coordinate(39.9526, -75.1652)       // Center City
    static let penn = Coordinate(39.9522, -75.1932)       // University of Pennsylvania
    static let restaurant = Coordinate(39.9540, -75.2010)
    static let grocery = Coordinate(39.9480, -75.1700)
    static let station30th = Coordinate(39.9557, -75.1822)
    static let phl = Coordinate(39.8744, -75.2424)
    static let slc = Coordinate(40.7899, -111.9791)
}

func makeStore(_ traj: Trajectory) throws -> TravelStore {
    let store = try TravelStore.inMemory()
    try store.insertPoints(traj.points)
    try store.insertMotion(traj.motion)
    return store
}
