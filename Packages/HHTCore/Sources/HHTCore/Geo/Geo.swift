import Foundation

/// WGS84 coordinate in decimal degrees.
public struct Coordinate: Equatable, Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
    public init(latitude: Double, longitude: Double) { self.init(latitude, longitude) }
}

public enum Geo {
    /// Mean Earth radius (IUGG), metres.
    public static let earthRadius = 6_371_008.8

    /// Great-circle (haversine) distance in metres. Error vs. the WGS84 ellipsoid is < 0.5%,
    /// which is well below GPS noise for trip distances.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Sum of consecutive distances along a path.
    public static func pathLength(_ coords: [Coordinate]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count { total += distance(coords[i - 1], coords[i]) }
        return total
    }

    /// Arithmetic centroid, optionally weighted. Fine for the small extents of a stay cluster
    /// (not for antimeridian-spanning sets).
    public static func centroid(_ coords: [Coordinate], weights: [Double]? = nil) -> Coordinate? {
        guard !coords.isEmpty else { return nil }
        var lat = 0.0, lon = 0.0, wsum = 0.0
        for (i, c) in coords.enumerated() {
            let w = weights?[i] ?? 1
            lat += c.latitude * w; lon += c.longitude * w; wsum += w
        }
        guard wsum > 0 else { return nil }
        return Coordinate(lat / wsum, lon / wsum)
    }

    /// Centre of mass on the sphere (via 3-D unit vectors); correct for world-scale sets.
    public static func sphericalCentroid(_ coords: [Coordinate], weights: [Double]? = nil) -> Coordinate? {
        guard !coords.isEmpty else { return nil }
        var x = 0.0, y = 0.0, z = 0.0, wsum = 0.0
        for (i, c) in coords.enumerated() {
            let w = weights?[i] ?? 1
            let φ = c.latitude * .pi / 180, λ = c.longitude * .pi / 180
            let cφ: Double = cos(φ)
            x += cφ * cos(λ) * w
            y += cφ * sin(λ) * w
            z += sin(φ) * w
            wsum += w
        }
        guard wsum > 0 else { return nil }
        x /= wsum; y /= wsum; z /= wsum
        let lon = atan2(y, x), hyp = sqrt(x * x + y * y), lat = atan2(z, hyp)
        return Coordinate(lat * 180 / .pi, lon * 180 / .pi)
    }

    /// Radius of gyration r_g = sqrt( Σ w_i d(p_i, c)^2 / Σ w_i ), where c is the weighted spherical
    /// centre of mass and d is great-circle distance. Metres.
    public static func radiusOfGyration(_ coords: [Coordinate], weights: [Double]? = nil) -> Double? {
        guard let c = sphericalCentroid(coords, weights: weights) else { return nil }
        var s = 0.0, wsum = 0.0
        for (i, p) in coords.enumerated() {
            let w = weights?[i] ?? 1
            let d = distance(p, c)
            s += w * d * d; wsum += w
        }
        return wsum > 0 ? sqrt(s / wsum) : nil
    }

    /// Local equirectangular projection (metres) around an origin — used for small-extent geometry.
    public static func project(_ c: Coordinate, origin: Coordinate) -> (x: Double, y: Double) {
        let x = (c.longitude - origin.longitude) * .pi / 180 * earthRadius * cos(origin.latitude * .pi / 180)
        let y = (c.latitude - origin.latitude) * .pi / 180 * earthRadius
        return (x, y)
    }

    public static func unproject(_ p: (x: Double, y: Double), origin: Coordinate) -> Coordinate {
        let lat = origin.latitude + p.y / earthRadius * 180 / .pi
        let lon = origin.longitude + p.x / (earthRadius * cos(origin.latitude * .pi / 180)) * 180 / .pi
        return Coordinate(lat, lon)
    }

    private struct HullPoint { let c: Coordinate; let x: Double; let y: Double }

    /// Convex hull (Andrew's monotone chain) in a local projection. Returns hull vertices and area (m²).
    public static func convexHull(_ coords: [Coordinate]) -> (hull: [Coordinate], areaSquareMeters: Double) {
        let unique = Array(Set(coords))
        guard unique.count >= 3, let origin = centroid(unique) else { return (unique, 0) }
        var pts: [HullPoint] = unique.map { c in
            let p = project(c, origin: origin)
            return HullPoint(c: c, x: p.x, y: p.y)
        }
        pts.sort { a, b in a.x == b.x ? a.y < b.y : a.x < b.x }
        func cross(_ o: HullPoint, _ a: HullPoint, _ b: HullPoint) -> Double {
            let u: Double = (a.x - o.x) * (b.y - o.y)
            let v: Double = (a.y - o.y) * (b.x - o.x)
            return u - v
        }
        var lower: [HullPoint] = []
        for pt in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], pt) <= 0 { lower.removeLast() }
            lower.append(pt)
        }
        var upper: [HullPoint] = []
        for pt in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], pt) <= 0 { upper.removeLast() }
            upper.append(pt)
        }
        let hull = Array(lower.dropLast()) + Array(upper.dropLast())
        var area = 0.0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        return (hull.map { $0.c }, abs(area) / 2)
    }

    /// Douglas–Peucker simplification with tolerance in metres.
    public static func simplify(_ coords: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard coords.count > 2, let origin = coords.first else { return coords }
        let pts = coords.map { project($0, origin: origin) }
        var keep = [Bool](repeating: false, count: coords.count)
        keep[0] = true; keep[coords.count - 1] = true
        var stack = [(0, coords.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            let a = pts[s], b = pts[e]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var maxD = 0.0, idx = s
            for i in (s + 1)..<e {
                let p = pts[i]
                var d: Double
                if len2 == 0 {
                    d = hypot(p.x - a.x, p.y - a.y)
                } else {
                    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                    d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
                }
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx)); stack.append((idx, e))
            }
        }
        return coords.enumerated().filter { keep[$0.offset] }.map { $0.element }
    }
}

/// Google encoded polyline algorithm (precision 1e-5). Compact route storage readable by most GIS tools
/// (e.g. `polyline` in Python / `googlePolylines` in R).
public enum Polyline {
    public static func encode(_ coords: [Coordinate]) -> String {
        var result = ""
        var prevLat = 0, prevLon = 0
        func enc(_ v: Int) {
            var v = v < 0 ? ~(v << 1) : (v << 1)
            while v >= 0x20 {
                result.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63)))
                v >>= 5
            }
            result.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            enc(lat - prevLat); enc(lon - prevLon)
            prevLat = lat; prevLon = lon
        }
        return result
    }

    public static func decode(_ s: String) -> [Coordinate] {
        let bytes = Array(s.utf8)
        var idx = 0, lat = 0, lon = 0
        var out: [Coordinate] = []
        func next() -> Int? {
            var result = 0, shift = 0
            while idx < bytes.count {
                let b = Int(bytes[idx]) - 63
                idx += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while idx < bytes.count {
            guard let dlat = next(), let dlon = next() else { break }
            lat += dlat; lon += dlon
            out.append(Coordinate(Double(lat) / 1e5, Double(lon) / 1e5))
        }
        return out
    }
}
