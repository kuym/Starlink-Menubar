import Foundation
import XCTest
@testable import Orbits

/// Runs the SGP4 port against the official verification set: every satellite in SGP4-VER.TLE, propagated over
/// the start/stop/step range given after its line 2, must reproduce the position and velocity in tcppver.out
/// (the output of Vallado's C++ reference) to within 2e-7 km and km/s, the tolerance the python-sgp4 project
/// uses for the same check, and must fail with the same errors at the same points.
final class SGP4VerificationTests: XCTestCase {
    private func resource(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        return try String(contentsOf: url, encoding: .ascii).replacingOccurrences(of: "\r", with: "")
    }

    /// One data line of tcppver.out: minutes since epoch, r (km), v (km/s).
    private struct Row { var t: Double; var r: SIMD3<Double>; var v: SIMD3<Double> }

    func testAgainstTcppver() throws {
        // Expected output, grouped per satellite ("<satnum> xx" headers).
        var expected: [(satnum: Int, rows: [Row])] = []
        for line in try resource("tcppver.out").split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 2, f[1] == "xx", let n = Int(f[0]) {
                expected.append((n, []))
            } else if f.count >= 7 {
                let d = f.prefix(7).compactMap { Double($0) }
                XCTAssertEqual(d.count, 7)
                expected[expected.count - 1].rows.append(Row(t: d[0], r: SIMD3(d[1], d[2], d[3]),
                                                             v: SIMD3(d[4], d[5], d[6])))
            }
        }

        // Regenerate the same lines (the rules of the reference test driver), comparing as we go.
        let tleLines = try resource("SGP4-VER.TLE").split(separator: "\n").map(String.init)
        var errors: [Int] = []
        var satIndex = 0
        var maxR = 0.0, maxV = 0.0, compared = 0
        var i = 0
        while i < tleLines.count {
            let line1 = tleLines[i]
            guard line1.hasPrefix("1") else { i += 1; continue }
            let line2 = tleLines[i + 1]
            i += 2
            let tle = try TLE(line1: line1, line2: line2)
            let sat = SGP4(tle: tle)
            XCTAssertLessThan(satIndex, expected.count)
            let exp = expected[satIndex]
            XCTAssertEqual(exp.satnum, tle.satnum, "satellite order")
            satIndex += 1

            var produced: [Row?] = []        // nil = "use previous data line" (initialisation failed)
            func emit(_ t: Double) -> Bool {
                let o = sat.propagate(minutes: t)
                if let e = o.error { errors.append(e.rawValue); return false }   // any error ends this satellite
                produced.append(Row(t: t, r: o.r!, v: o.v!))
                return true
            }
            // The epoch line: printed if the position isn't NaN (only fatal errors suppress it).
            let first = sat.propagate(minutes: 0)
            if let r = first.r, let v = first.v {
                produced.append(Row(t: 0, r: r, v: v))
                let fields = line2.dropFirst(69).split(separator: " ").compactMap { Double($0) }
                XCTAssertEqual(fields.count, 3)
                let (start, stop, step) = (fields[0], fields[1], fields[2])
                var t = start
                var stopped = false
                while t <= stop {
                    if t == start && start == 0 { t += step; continue }
                    if !emit(t) { stopped = true; break }
                    t += step
                }
                if !stopped && t - stop < step - 1e-6 { _ = emit(stop) }   // don't miss the last line
            } else {
                errors.append(first.error!.rawValue)
                produced.append(nil)
            }

            XCTAssertEqual(produced.count, exp.rows.count, "line count for \(tle.satnum)")
            for (p, e) in zip(produced, exp.rows) {
                guard let p else { continue }      // reference prints the previous satellite's line here
                XCTAssertEqual(p.t, e.t, accuracy: 1e-6)
                let dr = p.r - e.r, dv = p.v - e.v
                let er = max(abs(dr.x), abs(dr.y), abs(dr.z)), ev = max(abs(dv.x), abs(dv.y), abs(dv.z))
                maxR = max(maxR, er)
                maxV = max(maxV, ev)
                compared += 1
                XCTAssertLessThan(er, 2e-7, "position of \(tle.satnum) at \(p.t) min: \(p.r) vs \(e.r)")
                XCTAssertLessThan(ev, 2e-7, "velocity of \(tle.satnum) at \(p.t) min: \(p.v) vs \(e.v)")
            }
        }
        XCTAssertEqual(satIndex, expected.count)
        XCTAssertEqual(errors, [1, 1, 6, 6, 4, 3, 6], "the reference's expected error sequence")
        print(String(format: "SGP4 verification: %d states compared, max |Δr| %.2e km, max |Δv| %.2e km/s",
                     compared, maxR, maxV))
    }

    /// Spot check of the TLE parser on the Vanguard test case's fields.
    func testParse() throws {
        let tle = try TLE(line1: "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
                          line2: "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667")
        XCTAssertEqual(tle.satnum, 5)
        XCTAssertEqual(tle.epochYear, 2000)
        XCTAssertEqual(tle.bstar, 0.28098e-4, accuracy: 1e-15)
        XCTAssertEqual(tle.eccentricity, 0.1859667, accuracy: 1e-12)
        XCTAssertEqual(tle.meanMotion, 10.82419157, accuracy: 1e-9)
        XCTAssertEqual(TLE.alpha5("A0001"), 100001)
        XCTAssertEqual(TLE.alpha5("Z9999"), 339999)
    }
}
