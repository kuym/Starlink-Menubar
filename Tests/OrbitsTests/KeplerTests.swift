import Foundation
import simd
import XCTest
@testable import Orbits

final class KeplerTests: XCTestCase {
    private func sample() throws -> [TLE] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "starlink-sample", withExtension: "tle",
                                                  subdirectory: "Resources"))
        return TLE.parseFile(try String(contentsOf: url, encoding: .ascii))
    }

    /// TEME → Earth-fixed via sidereal time.
    private func ecef(_ r: SIMD3<Double>, jd: Double) -> SIMD3<Double> {
        let g = SGP4.gstime(jd)
        return SIMD3(r.x * cos(g) + r.y * sin(g), -r.x * sin(g) + r.y * cos(g), r.z)
    }

    /// The full chain (SGP4 → Earth-fixed → topocentric) against Skyfield, an independent implementation:
    /// look angles from Cupertino at 2026-11-17 20:00 UTC, computed with skyfield 1.x from the same TLEs.
    func testLookAnglesMatchSkyfield() throws {
        let tles = try sample()
        let observer = Observer(latitudeDeg: 37.3230, longitudeDeg: -122.0322)
        let date = Date(timeIntervalSince1970: 1794945600)
        let reference: [(Int, Double, Double, Double)] = [   // satnum, azimuth, elevation, range (km)
            (44714, 155.3222, -43.4262, 9255.300),
            (44718, 11.6553, -66.2748, 12075.857),
            (44723, 313.1437, -22.6297, 5893.919),
            (44725, 71.2869, -79.9948, 12904.646),
            (44744, 218.1660, -84.3311, 13135.322),
        ]
        let jd = SGP4.julianDate(date)
        for (satnum, az, el, range) in reference {
            let tle = try XCTUnwrap(tles.first { $0.satnum == satnum })
            let sat = SGP4(tle: tle)
            let r = try XCTUnwrap(sat.propagate(minutes: (jd - sat.jdEpoch) * 1440).r)
            let look = observer.lookAngles(ecef(r, jd: jd))
            // Skyfield also applies UT1−UTC and the equation of the equinoxes; both are well under 0.01° here.
            XCTAssertEqual(look.azimuth, az, accuracy: 0.02, "azimuth of \(satnum)")
            XCTAssertEqual(look.elevation, el, accuracy: 0.02, "elevation of \(satnum)")
            XCTAssertEqual(look.range, range, accuracy: 2, "range of \(satnum)")
        }
    }

    /// The Kepler model against full SGP4, over the day it is fitted for (it is refitted daily), for every satellite in the sample.
    func testKeplerTracksSGP4() throws {
        let tles = try sample()
        let ref = Date(timeIntervalSince1970: 1794945600)
        let constellation = Constellation(tles: tles, at: ref)
        XCTAssertEqual(constellation.count, tles.count)
        var worstKm = 0.0, worstAngleDeg = 0.0
        for (i, orbit) in constellation.orbits.enumerated() {
            let sat = SGP4(tle: try XCTUnwrap(tles.first { $0.satnum == constellation.satnums[i] }))
            for dt in stride(from: 0.0, through: 86400, by: 1800) {
                let jd = SGP4.julianDate(ref.addingTimeInterval(dt))
                let r = try XCTUnwrap(sat.propagate(minutes: (jd - sat.jdEpoch) * 1440).r)
                let exact = ecef(r, jd: jd)
                let approx = orbit.positionECEF(dt: dt, gmst: SGP4.gstime(jd))
                let err = simd_distance(exact, approx)
                worstKm = max(worstKm, err)
                // As seen from directly below at 550 km, the closest any satellite gets: the worst case.
                worstAngleDeg = max(worstAngleDeg, atan(err / 550) * 180 / .pi)
            }
        }
        print(String(format: "Kepler vs SGP4 over 24 h, %d satellites: max error %.1f km (≤ %.2f° seen from the ground)",
                     constellation.count, worstKm, worstAngleDeg))
        XCTAssertLessThan(worstKm, 25)
    }

    /// Full-catalogue cost of one update, to keep the per-second update cheap.
    func testUpdateCost() throws {
        let tles = try sample()
        let c = Constellation(tles: Array(repeating: tles, count: 250).flatMap { $0 }, at: Date())   // ~10k
        let start = Date()
        var acc = SIMD3<Double>()
        let g = SGP4.gstime(SGP4.julianDate(Date()))
        for o in c.orbits { acc += o.positionECEF(dt: 12.5, gmst: g) }
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "%d positions in %.2f ms (debug build)", c.count, ms), acc.x > 0 ? "" : " ")
    }
}
