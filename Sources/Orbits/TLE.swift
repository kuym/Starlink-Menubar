import Foundation

/// One NORAD two-line element set, parsed (column positions as in Vallado's `twoline2rv`).
public struct TLE: Sendable {
    public enum ParseError: Error { case malformed(line: Int) }

    public let name: String?
    public let line1: String
    public let line2: String
    /// Catalog number (Alpha-5 numbers such as "A0001" decode to 100001).
    public let satnum: Int
    public let epochYear: Int
    /// Day of the year, with the fraction of the day (1.0 = 1 Jan 00:00 UTC).
    public let epochDays: Double
    /// First and second derivatives of mean motion, rev/day² and rev/day³ (as printed, before unit changes).
    public let ndot: Double
    public let nddot: Double
    /// SGP4 drag term, 1/earth radii.
    public let bstar: Double
    /// Degrees.
    public let inclination: Double
    public let raan: Double
    public let eccentricity: Double
    public let argumentOfPerigee: Double
    public let meanAnomaly: Double
    /// Revolutions per day.
    public let meanMotion: Double

    /// Julian date of the epoch (UTC).
    public var epochJD: Double {
        // Vallado's jday() for 1 Jan 00:00 of the epoch year, plus the day of the year.
        let y = Double(epochYear)
        let jan1 = 367.0 * y - ((7.0 * (y + ((1.0 + 9.0) / 12.0).rounded(.down))) * 0.25).rounded(.down)
            + (275.0 / 9.0).rounded(.down) + 1.0 + 1721013.5
        return jan1 + epochDays - 1.0
    }

    public init(name: String? = nil, line1: String, line2: String) throws {
        let l1 = Array(line1.utf8), l2 = Array(line2.utf8)
        func s(_ l: [UInt8], _ r: Range<Int>) -> String { String(decoding: l[r], as: UTF8.self) }
        func num(_ text: String) -> Double? {
            var t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(".") { t = "0" + t }
            if t.hasPrefix("-.") { t = "-0" + t.dropFirst() }
            if t.hasPrefix("+.") { t = "0" + t.dropFirst() }
            return Double(t)
        }
        /// "±nnnnn±e" with an implied leading decimal point, e.g. " 28098-4" = 0.28098e-4.
        func implied(_ l: [UInt8], sign: Int, digits: Range<Int>, exp: Range<Int>) -> Double? {
            guard let m = Double("0." + s(l, digits).replacingOccurrences(of: " ", with: "0")),
                  let e = Int(s(l, exp).trimmingCharacters(in: .whitespaces)) else { return nil }
            return (l[sign] == UInt8(ascii: "-") ? -m : m) * pow(10, Double(e))
        }
        guard l1.count >= 64, l1[0] == UInt8(ascii: "1"), l1[23] == UInt8(ascii: "."), l1[34] == UInt8(ascii: "."),
              let year = Int(s(l1, 18..<20)), let days = num(s(l1, 20..<32)), let ndot = num(s(l1, 33..<43)),
              let nddot = implied(l1, sign: 44, digits: 45..<50, exp: 50..<52),
              let bstar = implied(l1, sign: 53, digits: 54..<59, exp: 59..<61)
        else { throw ParseError.malformed(line: 1) }
        guard l2.count >= 63, l2[0] == UInt8(ascii: "2"), l2[11] == UInt8(ascii: "."),
              s(l2, 2..<7) == s(l1, 2..<7),
              let incl = num(s(l2, 8..<16)), let raan = num(s(l2, 17..<25)),
              let ecc = Double("0." + s(l2, 26..<33).replacingOccurrences(of: " ", with: "0")),
              let argp = num(s(l2, 34..<42)), let ma = num(s(l2, 43..<51)), let n = num(s(l2, 52..<63))
        else { throw ParseError.malformed(line: 2) }
        guard let satnum = Self.alpha5(s(l1, 2..<7)) else { throw ParseError.malformed(line: 1) }

        self.name = name
        self.line1 = line1
        self.line2 = line2
        self.satnum = satnum
        self.epochYear = year < 57 ? 2000 + year : 1900 + year
        self.epochDays = days
        self.ndot = ndot
        self.nddot = nddot
        self.bstar = bstar
        self.inclination = incl
        self.raan = raan
        self.eccentricity = ecc
        self.argumentOfPerigee = argp
        self.meanAnomaly = ma
        self.meanMotion = n
    }

    /// Decodes a 5-character catalog number, including Alpha-5 ("A0001" = 100001; I and O are skipped).
    static func alpha5(_ field: String) -> Int? {
        let f = field.trimmingCharacters(in: .whitespaces)
        if let n = Int(f) { return n }
        guard let first = f.first, first.isLetter, let rest = Int(f.dropFirst()) else { return nil }
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        guard let i = letters.firstIndex(of: Character(first.uppercased())) else { return nil }
        return (10 + i) * 10000 + rest
    }

    /// Parses a TLE file in 2- or 3-line format (CelesTrak's FORMAT=tle). Malformed entries are skipped.
    public static func parseFile(_ text: String) -> [TLE] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        var out: [TLE] = []
        out.reserveCapacity(lines.count / 3)
        var i = 0
        while i + 1 < lines.count {
            let a = lines[i], b = lines[i + 1]
            if a.hasPrefix("1 "), b.hasPrefix("2 ") {
                let prev = i > 0 ? lines[i - 1] : ""
                let name = prev.hasPrefix("1 ") || prev.hasPrefix("2 ") || prev.isEmpty
                    ? nil : prev.trimmingCharacters(in: .whitespaces)
                if let tle = try? TLE(name: name, line1: a, line2: b) { out.append(tle) }
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }
}
