import Foundation

/// RFC 4180 CSV reading and writing.
public enum CSV {
    public static func escape(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func write(header: [String], rows: [[String?]]) -> String {
        var out = header.map(escape).joined(separator: ",") + "\n"
        for r in rows { out += r.map { escape($0 ?? "") }.joined(separator: ",") + "\n" }
        return out
    }

    /// Parse CSV text into rows of fields (handles quoted fields, embedded commas/newlines, CRLF).
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    /// Parse into dictionaries keyed by the (lower-cased, trimmed) header.
    public static func parseRecords(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return [] }
        return rows.dropFirst().map { r in
            var d: [String: String] = [:]
            for (i, h) in header.enumerated() where i < r.count {
                let v = r[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { d[h] = v }
            }
            return d
        }
    }
}
