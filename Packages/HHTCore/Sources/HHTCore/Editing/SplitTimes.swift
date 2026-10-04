import Foundation

/// Starting times for the "split visit" / "split trip" sheets.
///
/// Every value is ordered and lies strictly inside the record, so the date-picker ranges built from them
/// (`leave...back`, `start...trip.arrival`, …) are valid on first render and the edit service accepts them as-is.
public enum SplitTimes {
    public struct VisitSplit: Equatable {
        public var leave: Date, back: Date
        public var stopArrival: Date, stopDeparture: Date
    }

    public struct TripSplit: Equatable {
        public var stopStart: Date, stopEnd: Date
    }

    /// A gap of up to 30 min centred in the visit; a still-open visit ends at `now`.
    public static func visit(arrival: Date, departure: Date?, now: Date = Date()) -> VisitSplit {
        let end = max(arrival, departure ?? now)
        let span = end.timeIntervalSince(arrival)
        let mid = arrival.addingTimeInterval(span / 2)
        let gap = min(span / 3, 1800)
        let leave = mid.addingTimeInterval(-gap / 2), back = mid.addingTimeInterval(gap / 2)
        return VisitSplit(leave: leave, back: back,
                          stopArrival: leave.addingTimeInterval(gap / 4), stopDeparture: back.addingTimeInterval(-gap / 4))
    }

    /// A stop of up to 5 min centred in the trip.
    public static func trip(departure: Date, arrival: Date) -> TripSplit {
        let span = max(0, arrival.timeIntervalSince(departure))
        let mid = departure.addingTimeInterval(span / 2)
        let gap = min(span / 3, 300)
        return TripSplit(stopStart: mid.addingTimeInterval(-gap / 2), stopEnd: mid.addingTimeInterval(gap / 2))
    }

    /// The stop the user picked, padded to at least a minute where the trip leaves room for it.
    public static func tripStop(start: Date, end: Date, arrival: Date) -> TripSplit {
        let latest = max(start, arrival.addingTimeInterval(-1))
        return TripSplit(stopStart: start, stopEnd: min(max(end, start.addingTimeInterval(60)), latest))
    }
}

public extension ClosedRange where Bound == Date {
    /// `lower...upper`, collapsing to a single instant instead of trapping when `upper < lower`.
    static func ordered(_ lower: Date, _ upper: Date) -> ClosedRange<Date> { lower...Swift.max(lower, upper) }
}
