import Foundation

/// Travel modes. Raw values are the canonical codes written to the database and exports.
public enum TravelMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case walk, run, bicycle, ebike, scooter
    case car                // automobile, driver/passenger not known (typical auto-classification)
    case carDriver = "car_driver"
    case carPassenger = "car_passenger"
    case taxi               // taxi / ridehail
    case bus                // local bus
    case subway             // subway / metro
    case lightRail = "light_rail"   // light rail / streetcar / trolley
    case commuterRail = "commuter_rail"
    case intercityRail = "intercity_rail"
    case coach              // long-distance bus
    case shuttle            // campus / employer shuttle
    case ferry
    case airplane
    case other
    case unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .bicycle: return "Bike"
        case .ebike: return "E-bike"
        case .scooter: return "Scooter"
        case .car: return "Car"
        case .carDriver: return "Car (driver)"
        case .carPassenger: return "Car (passenger)"
        case .taxi: return "Taxi / ridehail"
        case .bus: return "Bus"
        case .subway: return "Subway / metro"
        case .lightRail: return "Light rail / trolley"
        case .commuterRail: return "Commuter rail"
        case .intercityRail: return "Intercity rail"
        case .coach: return "Coach bus"
        case .shuttle: return "Shuttle"
        case .ferry: return "Ferry"
        case .airplane: return "Airplane"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol name used by the app.
    public var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .bicycle, .ebike: return "bicycle"
        case .scooter: return "scooter"
        case .car, .carDriver, .carPassenger: return "car.fill"
        case .taxi: return "car.side.fill"
        case .bus, .coach, .shuttle: return "bus.fill"
        case .subway: return "tram.fill.tunnel"
        case .lightRail: return "tram.fill"
        case .commuterRail, .intercityRail: return "train.side.front.car"
        case .ferry: return "ferry.fill"
        case .airplane: return "airplane"
        case .other: return "ellipsis.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    public var group: ModeGroup {
        switch self {
        case .walk, .run, .bicycle, .ebike, .scooter: return .active
        case .car, .carDriver, .carPassenger, .taxi: return .car
        case .bus, .subway, .lightRail, .commuterRail, .ferry, .shuttle: return .transit
        case .intercityRail, .coach, .airplane: return .longDistance
        case .other, .unknown: return .other
        }
    }
}

public enum ModeGroup: String, CaseIterable, Codable, Sendable {
    case active, car, transit, longDistance = "long_distance", other
    public var label: String {
        switch self {
        case .active: return "Active"
        case .car: return "Car"
        case .transit: return "Transit"
        case .longDistance: return "Long-distance"
        case .other: return "Other / unknown"
        }
    }
}

/// Activity purpose at the destination (HHTS-style).
public enum TripPurpose: String, CaseIterable, Codable, Identifiable, Sendable {
    case home, work, school, meal, shopping, recreation, social
    case personalBusiness = "personal_business"
    case medical
    case travel          // travel / airport / station
    case transfer        // change of mode, not an activity
    case escort          // pick up / drop off someone
    case other

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .home: return "Home"
        case .work: return "Work"
        case .school: return "School"
        case .meal: return "Meal"
        case .shopping: return "Shopping"
        case .recreation: return "Recreation"
        case .social: return "Social"
        case .personalBusiness: return "Personal business"
        case .medical: return "Medical"
        case .travel: return "Travel / airport"
        case .transfer: return "Transfer"
        case .escort: return "Pick-up / drop-off"
        case .other: return "Other"
        }
    }
}

/// Personal place category.
public enum PlaceCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case home
    case workSchool = "work_school"
    case restaurant, cafe, grocery, shopping, recreation, entertainment
    case airport
    case railStation = "rail_station"
    case transitStation = "transit_station"
    case hotel
    case friendFamily = "friend_family"
    case medical
    case other

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .home: return "Home"
        case .workSchool: return "Work / School"
        case .restaurant: return "Restaurant"
        case .cafe: return "Cafe"
        case .grocery: return "Grocery"
        case .shopping: return "Shopping"
        case .recreation: return "Recreation"
        case .entertainment: return "Entertainment"
        case .airport: return "Airport"
        case .railStation: return "Rail station"
        case .transitStation: return "Transit station"
        case .hotel: return "Hotel"
        case .friendFamily: return "Friend / Family"
        case .medical: return "Medical"
        case .other: return "Other"
        }
    }
    public var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .workSchool: return "building.columns.fill"
        case .restaurant: return "fork.knife"
        case .cafe: return "cup.and.saucer.fill"
        case .grocery: return "cart.fill"
        case .shopping: return "bag.fill"
        case .recreation: return "leaf.fill"
        case .entertainment: return "theatermasks.fill"
        case .airport: return "airplane.departure"
        case .railStation: return "train.side.front.car"
        case .transitStation: return "tram.fill"
        case .hotel: return "bed.double.fill"
        case .friendFamily: return "person.2.fill"
        case .medical: return "cross.case.fill"
        case .other: return "mappin"
        }
    }
    /// Default activity purpose implied by a place category.
    public var defaultPurpose: TripPurpose? {
        switch self {
        case .home: return .home
        case .workSchool: return .work
        case .restaurant, .cafe: return .meal
        case .grocery, .shopping: return .shopping
        case .recreation, .entertainment: return .recreation
        case .airport, .railStation, .hotel: return .travel
        case .transitStation: return .transfer
        case .friendFamily: return .social
        case .medical: return .medical
        case .other: return nil
        }
    }
}

/// Provenance of a derived or entered record.
public enum RecordSource: String, Codable, Sendable {
    case inferred, manual
    case importedCSV = "imported_csv"
    case importedGPX = "imported_gpx"
}

/// Edit state of a derived record. Anything other than `.auto` is protected from reprocessing.
public enum UserStatus: String, Codable, Sendable {
    case auto        // produced by inference, untouched
    case confirmed   // user reviewed and accepted as-is
    case edited      // user changed at least one field
    case manual      // user created it
    public var isLocked: Bool { self != .auto }
}
