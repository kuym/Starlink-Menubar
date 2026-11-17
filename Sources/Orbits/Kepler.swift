import Foundation
import simd

/// A satellite orbit reduced to Keplerian elements with constant secular rates, fitted to SGP4 at a reference
/// time. Positions are then a cheap closed-form function of time (and of Greenwich sidereal time, to turn the
/// orbit into Earth-fixed coordinates). Within ~15 km of full SGP4 over the day it is fitted for (tested),
/// about 1° as seen from the ground: it keeps SGP4's secular terms and drag, and leaves out the short-period
/// ones, which the sky view doesn't need.
public struct KeplerOrbit: Sendable {
    /// Semi-major axis (km) and eccentricity.
    public var a: Double
    public var e: Double
    var sqrt1me2: Double
    var cosI: Double
    var sinI: Double
    /// Right ascension of the ascending node, argument of perigee and mean anomaly at the reference time
    /// (radians), and their rates (radians/second): J2 precession, drag and mean motion, as SGP4 models them.
    public var raan0: Double, raanRate: Double
    public var argp0: Double, argpRate: Double
    public var m0: Double, mRate: Double
    /// Drag makes the mean anomaly accelerate (radians/second²): for the low, decaying satellites this is
    /// what dominates the error of a linear model, hundreds of km after a day.
    public var mAccel: Double

    /// Fits the orbit to `sgp4` from `jd` (Julian date) over the following `span` seconds: SGP4's mean
    /// elements at `jd`, the node and perigee rates from a ±5 minute central difference, and a quadratic for
    /// the mean argument of latitude (M + ω) through `jd`, mid-span and the end of the span. nil if SGP4
    /// can't propagate the satellite (e.g. it has decayed).
    public init?(_ sgp4: SGP4, at jd: Double, span: Double = 86400) {
        let t = (jd - sgp4.jdEpoch) * 1440
        let h = 5.0                                       // minutes
        let half = span / 2 / 60                          // minutes
        let o = sgp4.propagate(minutes: t)
        guard o.error == nil, let m = o.mean,
              let lo = sgp4.propagate(minutes: t - h).mean, let hi = sgp4.propagate(minutes: t + h).mean,
              let mid = sgp4.propagate(minutes: t + half).mean, let end = sgp4.propagate(minutes: t + 2 * half).mean
        else { return nil }
        let re = GravityConstants.wgs72.radiusEarthKm
        func rate(_ a: Double, _ b: Double) -> Double { remainder(b - a, 2 * .pi) / (2 * h * 60) }
        self.a = m.am * re
        self.e = m.em
        sqrt1me2 = (1 - m.em * m.em).squareRoot()
        cosI = cos(m.im)
        sinI = sin(m.im)
        raan0 = m.node
        argp0 = m.argp
        m0 = m.mm
        raanRate = rate(lo.node, hi.node)
        argpRate = rate(lo.argp, hi.argp)
        // M + ω stays well defined for near-circular orbits. Its short-baseline rate (~0.66 rad per 10 min,
        // under π, so it unwraps correctly) predicts the later samples to within a fraction of a radian,
        // which unwraps those in turn.
        let u0 = m.mm + m.argp
        let r0 = rate(lo.mm + lo.argp, hi.mm + hi.argp)
        let H = half * 60                                  // seconds
        func unwrap(_ u: Double, at s: Double) -> Double { u0 + r0 * s + remainder(u - (u0 + r0 * s), 2 * .pi) }
        let u1 = unwrap(mid.mm + mid.argp, at: H)
        let u2 = unwrap(end.mm + end.argp, at: 2 * H)
        // Quadratic through (0, u0), (H, u1), (2H, u2).
        let uRate = (-3 * u0 + 4 * u1 - u2) / (2 * H)
        mAccel = (u0 - 2 * u1 + u2) / (H * H)
        mRate = uRate - argpRate
    }

    /// Earth-fixed (TEME rotated by sidereal time, i.e. pseudo-Earth-fixed) position in km, `dt` seconds
    /// after the reference time, where Greenwich mean sidereal time is `gmst` (radians).
    @inline(__always)
    public func positionECEF(dt: Double, gmst: Double) -> SIMD3<Double> {
        let mAnom = m0 + (mRate + 0.5 * mAccel * dt) * dt
        // Kepler's equation; Starlink orbits are nearly circular (e ~ 1e-4), so two Newton steps from E = M
        // converge to machine precision. A third covers more eccentric objects.
        var ecc = mAnom
        for _ in 0..<3 { ecc -= (ecc - e * sin(ecc) - mAnom) / (1 - e * cos(ecc)) }
        let xp = a * (cos(ecc) - e)
        let yp = a * sqrt1me2 * sin(ecc)
        let w = argp0 + argpRate * dt
        let cw = cos(w), sw = sin(w)
        let x1 = xp * cw - yp * sw
        let y1 = xp * sw + yp * cw
        // Tilt by the inclination, then turn by the node's longitude relative to Greenwich.
        let y2 = y1 * cosI
        let z2 = y1 * sinI
        let lon = raan0 + raanRate * dt - gmst
        let cl = cos(lon), sl = sin(lon)
        return SIMD3(x1 * cl - y2 * sl, x1 * sl + y2 * cl, z2)
    }
}

/// Every satellite of a TLE catalogue as a `KeplerOrbit`, fitted at one reference time.
public struct Constellation: Sendable {
    public let referenceDate: Date
    public let orbits: [KeplerOrbit]
    public let satnums: [Int]
    public let names: [String?]

    public init(tles: [TLE], at date: Date) {
        let jd = SGP4.julianDate(date)
        var orbits: [KeplerOrbit] = [], satnums: [Int] = [], names: [String?] = []
        orbits.reserveCapacity(tles.count)
        for tle in tles {
            // Element sets more than a month off the reference time are too stale to be meaningful.
            guard abs(jd - tle.epochJD) < 30, let o = KeplerOrbit(SGP4(tle: tle), at: jd) else { continue }
            orbits.append(o)
            satnums.append(tle.satnum)
            names.append(tle.name)
        }
        referenceDate = date
        self.orbits = orbits
        self.satnums = satnums
        self.names = names
    }

    public var count: Int { orbits.count }
}

/// A place on the ground and its local East-North-Up frame (WGS-84 ellipsoid).
public struct Observer: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Earth-fixed position, km.
    public let ecef: SIMD3<Double>
    public let east: SIMD3<Double>
    public let north: SIMD3<Double>
    public let up: SIMD3<Double>

    public init(latitudeDeg: Double, longitudeDeg: Double, altitudeKm: Double = 0) {
        latitude = latitudeDeg
        longitude = longitudeDeg
        let phi = latitudeDeg * .pi / 180, lam = longitudeDeg * .pi / 180
        let a = 6378.137, f = 1 / 298.257223563
        let e2 = f * (2 - f)
        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        ecef = SIMD3((n + altitudeKm) * cos(phi) * cos(lam), (n + altitudeKm) * cos(phi) * sin(lam),
                     (n * (1 - e2) + altitudeKm) * sin(phi))
        east = SIMD3(-sin(lam), cos(lam), 0)
        north = SIMD3(-sin(phi) * cos(lam), -sin(phi) * sin(lam), cos(phi))
        up = SIMD3(cos(phi) * cos(lam), cos(phi) * sin(lam), sin(phi))
    }

    /// Line of sight to an Earth-fixed point, as (east, north, up) km.
    @inline(__always)
    public func enu(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - ecef
        return SIMD3(simd_dot(d, east), simd_dot(d, north), simd_dot(d, up))
    }

    /// Azimuth (degrees clockwise from north), elevation (degrees) and range (km) of an Earth-fixed point.
    public func lookAngles(_ p: SIMD3<Double>) -> (azimuth: Double, elevation: Double, range: Double) {
        let v = enu(p)
        let r = simd_length(v)
        var az = atan2(v.x, v.y) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, asin(v.z / r) * 180 / .pi, r)
    }
}
