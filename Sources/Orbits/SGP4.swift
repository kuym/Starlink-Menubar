import Foundation

// A Swift port of David Vallado's reference SGP4/SDP4 implementation (sgp4unit.cpp, as published with
// "Revisiting Spacetrack Report #3", Vallado, Crawford, Hujsak & Kelso, AIAA 2006-6753; ported from its
// line-for-line Python translation in the `sgp4` package). Only the "improved" operation mode is ported
// (opsmode 'i', the default; AFSPC mode 'a' differs only in two angle-wrapping details and the epoch's
// sidereal time). Verified against the official SGP4-VER.TLE / tcppver.out test vectors: see
// Tests/OrbitsTests. Variable names follow the original so the two can be compared side by side.

/// Earth gravity model constants used by SGP4.
public struct GravityConstants: Sendable {
    public let tumin, mu, radiusEarthKm, xke, j2, j3, j4, j3oj2: Double

    /// WGS-72: the model TLEs are generated with, and the one to use with them.
    public static let wgs72: GravityConstants = {
        let mu = 398600.8, re = 6378.135
        let xke = 60.0 / (re * re * re / mu).squareRoot()
        let j2 = 0.001082616, j3 = -0.00000253881, j4 = -0.00000165597
        return GravityConstants(tumin: 1 / xke, mu: mu, radiusEarthKm: re, xke: xke, j2: j2, j3: j3, j4: j4,
                                j3oj2: j3 / j2)
    }()
}

public struct SGP4: Sendable {
    /// Vallado's error codes (5 is no longer produced).
    public enum Failure: Int, Error, Sendable {
        case meanEccentricity = 1, negativeMeanMotion = 2, perturbedEccentricity = 3, negativeSemiLatusRectum = 4
        case decayed = 6
    }

    /// Singly averaged ("mean") elements at a given time, before SGP4 adds its periodic terms.
    public struct MeanElements: Sendable {
        /// Semi-major axis (earth radii), eccentricity, inclination, RAAN, argument of perigee, mean anomaly
        /// (radians), mean motion (radians/minute).
        public var am, em, im, node, argp, mm, nm: Double
    }

    public struct Output: Sendable {
        /// TEME position (km) and velocity (km/s). nil when the error is fatal (all but `.decayed`).
        public var r: SIMD3<Double>?
        public var v: SIMD3<Double>?
        public var mean: MeanElements?
        public var error: Failure?
    }

    public let satnum: Int
    /// Julian date of the element set's epoch.
    public let jdEpoch: Double
    let g: GravityConstants

    // Elements (radians, rad/min), as adjusted by initialisation.
    var bstar = 0.0, ecco = 0.0, argpo = 0.0, inclo = 0.0, mo = 0.0, noKozai = 0.0, nodeo = 0.0
    public private(set) var noUnkozai = 0.0
    var isimp = 0
    public private(set) var isDeepSpace = false

    // Near-earth coefficients.
    var aycof = 0.0, con41 = 0.0, cc1 = 0.0, cc4 = 0.0, cc5 = 0.0, d2 = 0.0, d3 = 0.0, d4 = 0.0
    var delmo = 0.0, eta = 0.0, argpdot = 0.0, omgcof = 0.0, sinmao = 0.0
    var t2cof = 0.0, t3cof = 0.0, t4cof = 0.0, t5cof = 0.0, x1mth2 = 0.0, x7thm1 = 0.0
    var mdot = 0.0, nodedot = 0.0, xlcof = 0.0, xmcof = 0.0, nodecf = 0.0

    // Deep-space coefficients.
    var irez = 0
    var d2201 = 0.0, d2211 = 0.0, d3210 = 0.0, d3222 = 0.0, d4410 = 0.0, d4422 = 0.0
    var d5220 = 0.0, d5232 = 0.0, d5421 = 0.0, d5433 = 0.0
    var dedt = 0.0, del1 = 0.0, del2 = 0.0, del3 = 0.0, didt = 0.0, dmdt = 0.0, dnodt = 0.0, domdt = 0.0
    var e3 = 0.0, ee2 = 0.0, peo = 0.0, pgho = 0.0, pho = 0.0, pinco = 0.0, plo = 0.0
    var se2 = 0.0, se3 = 0.0, sgh2 = 0.0, sgh3 = 0.0, sgh4 = 0.0, sh2 = 0.0, sh3 = 0.0
    var si2 = 0.0, si3 = 0.0, sl2 = 0.0, sl3 = 0.0, sl4 = 0.0
    public private(set) var gsto = 0.0
    var xfact = 0.0, xgh2 = 0.0, xgh3 = 0.0, xgh4 = 0.0, xh2 = 0.0, xh3 = 0.0
    var xi2 = 0.0, xi3 = 0.0, xl2 = 0.0, xl3 = 0.0, xl4 = 0.0, xlamo = 0.0, zmol = 0.0, zmos = 0.0
    var xli = 0.0, xni = 0.0

    /// Error from the propagation to the epoch that initialisation ends with (as `sgp4init` reports it).
    public private(set) var initError: Failure?

    private static let twopi = 2.0 * Double.pi
    private static let deg2rad = Double.pi / 180

    /// `twoline2rv` + `sgp4init`.
    public init(tle: TLE, gravity: GravityConstants = .wgs72) {
        let xpdotp = 1440.0 / (2.0 * Double.pi)          // rev/day → rad/min
        g = gravity
        satnum = tle.satnum
        jdEpoch = tle.epochJD
        bstar = tle.bstar
        ecco = tle.eccentricity
        argpo = tle.argumentOfPerigee * Self.deg2rad
        inclo = tle.inclination * Self.deg2rad
        mo = tle.meanAnomaly * Self.deg2rad
        noKozai = tle.meanMotion / xpdotp
        nodeo = tle.raan * Self.deg2rad
        initialize(epoch: jdEpoch - 2433281.5)
        initError = propagate(minutes: 0).error
    }

    // MARK: - sgp4init

    private mutating func initialize(epoch: Double) {
        let temp4 = 1.5e-12
        let ss = 78.0 / g.radiusEarthKm + 1.0
        let qzms2ttemp = (120.0 - 78.0) / g.radiusEarthKm
        let qzms2t = qzms2ttemp * qzms2ttemp * qzms2ttemp * qzms2ttemp
        let x2o3 = 2.0 / 3.0

        // ---- initl ----
        let eccsq = ecco * ecco
        let omeosq = 1.0 - eccsq
        let rteosq = omeosq.squareRoot()
        let cosio = cos(inclo)
        let cosio2 = cosio * cosio
        let ak = pow(g.xke / noKozai, x2o3)
        let d1 = 0.75 * g.j2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1.0 - del * del - del * (1.0 / 3.0 + 134.0 * del * del / 81.0))
        del = d1 / (adel * adel)
        noUnkozai = noKozai / (1.0 + del)
        let ao = pow(g.xke / noUnkozai, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1.0 - 5.0 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1.0 - ecco)
        gsto = Self.gstime(epoch + 2433281.5)

        guard omeosq >= 0.0 || noUnkozai >= 0.0 else { return }
        isimp = 0
        if rp < 220.0 / g.radiusEarthKm + 1.0 { isimp = 1 }
        var sfour = ss
        var qzms24 = qzms2t
        let perige = (rp - 1.0) * g.radiusEarthKm
        if perige < 156.0 {
            sfour = perige - 78.0
            if perige < 98.0 { sfour = 20.0 }
            let qzms24temp = (120.0 - sfour) / g.radiusEarthKm
            qzms24 = qzms24temp * qzms24temp * qzms24temp * qzms24temp
            sfour = sfour / g.radiusEarthKm + 1.0
        }
        let pinvsq = 1.0 / posq
        let tsi = 1.0 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1.0 - etasq)
        let coef = qzms24 * pow(tsi, 4.0)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * noUnkozai * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
            + 0.375 * g.j2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
        cc1 = bstar * cc2
        var cc3 = 0.0
        if ecco > 1.0e-4 { cc3 = -2.0 * coef * tsi * g.j3oj2 * noUnkozai * sinio / ecco }
        x1mth2 = 1.0 - cosio2
        cc4 = 2.0 * noUnkozai * coef1 * ao * omeosq * (eta * (2.0 + 0.5 * etasq) + ecco * (0.5 + 2.0 * etasq)
            - g.j2 * tsi / (ao * psisq) * (-3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
                + 0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)))
        cc5 = 2.0 * coef1 * ao * omeosq * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * g.j2 * pinvsq * noUnkozai
        let temp2 = 0.5 * temp1 * g.j2 * pinvsq
        let temp3 = -0.46875 * g.j4 * pinvsq * pinvsq * noUnkozai
        mdot = noUnkozai + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13.0 - 78.0 * cosio2 + 137.0 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7.0 - 114.0 * cosio2 + 395.0 * cosio4)
            + temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2) + 2.0 * temp3 * (3.0 - 7.0 * cosio2)) * cosio
        let xpidot = argpdot + nodedot
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = 0.0
        if ecco > 1.0e-4 { xmcof = -x2o3 * coef * bstar / eeta }
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        xlcof = abs(cosio + 1.0) > 1.5e-12
            ? -0.25 * g.j3oj2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio)
            : -0.25 * g.j3oj2 * sinio * (3.0 + 5.0 * cosio) / temp4
        aycof = -0.5 * g.j3oj2 * sinio
        let delmotemp = 1.0 + eta * cos(mo)
        delmo = delmotemp * delmotemp * delmotemp
        sinmao = sin(mo)
        x7thm1 = 7.0 * cosio2 - 1.0

        // Deep space: period of 225 minutes or more.
        if 2.0 * .pi / noUnkozai >= 225.0 {
            isDeepSpace = true
            isimp = 1
            let tc = 0.0
            let inclm = inclo
            let ds = dscom(epoch: epoch, ep: ecco, argpp: argpo, tc: tc, inclp: inclo, nodep: nodeo, np: noUnkozai)
            // dpper with init = 'y' leaves the elements unchanged (its periodics are only applied later).
            dsinit(ds: ds, t: 0, tc: tc, xpidot: xpidot, eccsq: eccsq, inclm: inclm)
        }

        if isimp != 1 {
            let cc1sq = cc1 * cc1
            d2 = 4.0 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3.0
            d3 = (17.0 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour) * cc1
            t3cof = d2 + 2.0 * cc1sq
            t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * cc1sq))
            t5cof = 0.2 * (3.0 * d4 + 12.0 * cc1 * d3 + 6.0 * d2 * d2 + 15.0 * cc1sq * (2.0 * d2 + cc1sq))
        }
    }

    // MARK: - sgp4

    /// Propagates to `minutes` after the epoch.
    public func propagate(minutes t: Double) -> Output {
        let twopi = Self.twopi
        let x2o3 = 2.0 / 3.0
        let temp4 = 1.5e-12
        let vkmpersec = g.radiusEarthKm * g.xke / 60.0

        // ---- update for secular gravity and atmospheric drag ----
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1.0 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2
        if isimp != 1 {
            let delomg = omgcof * t
            let delmtemp = 1.0 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }
        var nm = noUnkozai
        var em = ecco
        var inclm = inclo
        if isDeepSpace {
            dspace(t: t, tc: t, em: &em, argpm: &argpm, inclm: &inclm, mm: &mm, nodem: &nodem, nm: &nm)
        }
        if nm <= 0.0 { return Output(error: .negativeMeanMotion) }
        let am = pow(g.xke / nm, x2o3) * tempa * tempa
        nm = g.xke / pow(am, 1.5)
        em = em - tempe
        if em >= 1.0 || em < -0.001 { return Output(error: .meanEccentricity) }
        if em < 1.0e-6 { em = 1.0e-6 }
        mm = mm + noUnkozai * templ
        var xlm = mm + argpm + nodem
        nodem = fmod(nodem, twopi)
        argpm = fmod(argpm, twopi)
        xlm = fmod(xlm, twopi)
        mm = fmod(xlm - argpm - nodem, twopi)
        let mean = MeanElements(am: am, em: em, im: inclm, node: nodem, argp: argpm, mm: mm, nm: nm)

        // ---- compute extra mean quantities ----
        let sinim = sin(inclm)
        let cosim = cos(inclm)

        // ---- add lunar-solar periodics ----
        var ep = em
        var xincp = inclm
        var argpp = argpm
        var nodep = nodem
        var mp = mm
        var sinip = sinim
        var cosip = cosim
        var aycof = self.aycof, xlcof = self.xlcof
        var con41 = self.con41, x1mth2 = self.x1mth2, x7thm1 = self.x7thm1
        if isDeepSpace {
            dpper(t: t, ep: &ep, inclp: &xincp, nodep: &nodep, argpp: &argpp, mp: &mp)
            if xincp < 0.0 {
                xincp = -xincp
                nodep = nodep + .pi
                argpp = argpp - .pi
            }
            if ep < 0.0 || ep > 1.0 { return Output(mean: mean, error: .perturbedEccentricity) }
            // ---- long period periodics ----
            sinip = sin(xincp)
            cosip = cos(xincp)
            aycof = -0.5 * g.j3oj2 * sinip
            xlcof = abs(cosip + 1.0) > 1.5e-12
                ? -0.25 * g.j3oj2 * sinip * (3.0 + 5.0 * cosip) / (1.0 + cosip)
                : -0.25 * g.j3oj2 * sinip * (3.0 + 5.0 * cosip) / temp4
        }
        let axnl = ep * cos(argpp)
        var temp = 1.0 / (am * (1.0 - ep * ep))
        let aynl = ep * sin(argpp) + temp * aycof
        let xl = mp + argpp + nodep + temp * xlcof * axnl

        // ---- solve kepler's equation ----
        let u = fmod(xl - nodep, twopi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1.0e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0.0 ? 0.95 : -0.95 }
            eo1 = eo1 + tem5
            ktr += 1
        }

        // ---- short period preliminary quantities ----
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1.0 - el2)
        if pl < 0.0 { return Output(mean: mean, error: .negativeSemiLatusRectum) }
        let rl = am * (1.0 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1.0 - el2).squareRoot()
        temp = esine / (1.0 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1.0 - 2.0 * sinu * sinu
        temp = 1.0 / pl
        let temp1 = 0.5 * g.j2 * temp
        let temp2 = temp1 * temp

        // ---- update for short period periodics ----
        if isDeepSpace {
            let cosisq = cosip * cosip
            con41 = 3.0 * cosisq - 1.0
            x1mth2 = 1.0 - cosisq
            x7thm1 = 7.0 * cosisq - 1.0
        }
        let mrt = rl * (1.0 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su = su - 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodep + 1.5 * temp2 * cosip * sin2u
        let xinc = xincp + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / g.xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / g.xke

        // ---- orientation vectors ----
        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        // ---- position and velocity (in km and km/sec) ----
        let mr = mrt * g.radiusEarthKm
        let r = SIMD3(mr * ux, mr * uy, mr * uz)
        let v = SIMD3((mvt * ux + rvdot * vx) * vkmpersec, (mvt * uy + rvdot * vy) * vkmpersec,
                      (mvt * uz + rvdot * vz) * vkmpersec)
        // sgp4fix: the satellite has decayed (still reported, flagged).
        return Output(r: r, v: v, mean: mean, error: mrt < 1.0 ? .decayed : nil)
    }

    // MARK: - Deep space

    /// Locals of `dscom` that `dsinit` needs.
    private struct DSCom {
        var sinim = 0.0, cosim = 0.0, em = 0.0, emsq = 0.0, nm = 0.0
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0
        var ss1 = 0.0, ss2 = 0.0, ss3 = 0.0, ss4 = 0.0, ss5 = 0.0
        var sz1 = 0.0, sz3 = 0.0, sz11 = 0.0, sz13 = 0.0, sz21 = 0.0, sz23 = 0.0, sz31 = 0.0, sz33 = 0.0
        var z1 = 0.0, z3 = 0.0, z11 = 0.0, z13 = 0.0, z21 = 0.0, z23 = 0.0, z31 = 0.0, z33 = 0.0
    }

    /// Deep space common items (lunar and solar terms) used by both the secular and periodic routines.
    private mutating func dscom(epoch: Double, ep: Double, argpp: Double, tc: Double, inclp: Double,
                                nodep: Double, np: Double) -> DSCom {
        let twopi = Self.twopi
        let zes = 0.01675, zel = 0.0549, c1ss = 2.9864797e-6, c1l = 4.7968065e-7
        let zsinis = 0.39785416, zcosis = 0.91744867, zcosgs = 0.1945905, zsings = -0.98088458

        var o = DSCom()
        o.nm = np
        o.em = ep
        let snodm = sin(nodep), cnodm = cos(nodep)
        let sinomm = sin(argpp), cosomm = cos(argpp)
        o.sinim = sin(inclp)
        o.cosim = cos(inclp)
        let emsq = o.em * o.em
        o.emsq = emsq
        let betasq = 1.0 - emsq
        let rtemsq = betasq.squareRoot()

        // ---- initialize lunar solar terms ----
        peo = 0; pinco = 0; plo = 0; pgho = 0; pho = 0
        let day = epoch + 18261.5 + tc / 1440.0
        let xnodce = fmod(4.5236020 - 9.2422029e-4 * day, twopi)
        let stem = sin(xnodce), ctem = cos(xnodce)
        let zcosil = 0.91375164 - 0.03568096 * ctem
        let zsinil = (1.0 - zcosil * zcosil).squareRoot()
        let zsinhl = 0.089683511 * stem / zsinil
        let zcoshl = (1.0 - zsinhl * zsinhl).squareRoot()
        let gam = 5.8351514 + 0.0019443680 * day
        var zx = 0.39785416 * stem / zsinil
        let zy = zcoshl * ctem + 0.91744867 * zsinhl * stem
        zx = atan2(zx, zy)
        zx = gam + zx - xnodce
        let zcosgl = cos(zx), zsingl = sin(zx)

        // ---- do solar terms, then lunar terms ----
        var zcosg = zcosgs, zsing = zsings, zcosi = zcosis, zsini = zsinis
        var zcosh = cnodm, zsinh = snodm
        var cc = c1ss
        let xnoi = 1.0 / o.nm
        let sinim = o.sinim, cosim = o.cosim, em = o.em

        var z1 = 0.0, z2 = 0.0, z3 = 0.0, z11 = 0.0, z12 = 0.0, z13 = 0.0, z21 = 0.0, z22 = 0.0, z23 = 0.0
        var z31 = 0.0, z32 = 0.0, z33 = 0.0
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0
        var ss1 = 0.0, ss2 = 0.0, ss3 = 0.0, ss4 = 0.0, ss5 = 0.0, ss6 = 0.0, ss7 = 0.0
        var sz1 = 0.0, sz2 = 0.0, sz3 = 0.0, sz11 = 0.0, sz12 = 0.0, sz13 = 0.0
        var sz21 = 0.0, sz22 = 0.0, sz23 = 0.0, sz31 = 0.0, sz32 = 0.0, sz33 = 0.0

        for lsflg in 1...2 {
            let a1 = zcosg * zcosh + zsing * zcosi * zsinh
            let a3 = -zsing * zcosh + zcosg * zcosi * zsinh
            let a7 = -zcosg * zsinh + zsing * zcosi * zcosh
            let a8 = zsing * zsini
            let a9 = zsing * zsinh + zcosg * zcosi * zcosh
            let a10 = zcosg * zsini
            let a2 = cosim * a7 + sinim * a8
            let a4 = cosim * a9 + sinim * a10
            let a5 = -sinim * a7 + cosim * a8
            let a6 = -sinim * a9 + cosim * a10

            let x1 = a1 * cosomm + a2 * sinomm
            let x2 = a3 * cosomm + a4 * sinomm
            let x3 = -a1 * sinomm + a2 * cosomm
            let x4 = -a3 * sinomm + a4 * cosomm
            let x5 = a5 * sinomm
            let x6 = a6 * sinomm
            let x7 = a5 * cosomm
            let x8 = a6 * cosomm

            z31 = 12.0 * x1 * x1 - 3.0 * x3 * x3
            z32 = 24.0 * x1 * x2 - 6.0 * x3 * x4
            z33 = 12.0 * x2 * x2 - 3.0 * x4 * x4
            z1 = 3.0 * (a1 * a1 + a2 * a2) + z31 * emsq
            z2 = 6.0 * (a1 * a3 + a2 * a4) + z32 * emsq
            z3 = 3.0 * (a3 * a3 + a4 * a4) + z33 * emsq
            z11 = -6.0 * a1 * a5 + emsq * (-24.0 * x1 * x7 - 6.0 * x3 * x5)
            z12 = -6.0 * (a1 * a6 + a3 * a5) + emsq * (-24.0 * (x2 * x7 + x1 * x8) - 6.0 * (x3 * x6 + x4 * x5))
            z13 = -6.0 * a3 * a6 + emsq * (-24.0 * x2 * x8 - 6.0 * x4 * x6)
            z21 = 6.0 * a2 * a5 + emsq * (24.0 * x1 * x5 - 6.0 * x3 * x7)
            z22 = 6.0 * (a4 * a5 + a2 * a6) + emsq * (24.0 * (x2 * x5 + x1 * x6) - 6.0 * (x4 * x7 + x3 * x8))
            z23 = 6.0 * a4 * a6 + emsq * (24.0 * x2 * x6 - 6.0 * x4 * x8)
            z1 = z1 + z1 + betasq * z31
            z2 = z2 + z2 + betasq * z32
            z3 = z3 + z3 + betasq * z33
            s3 = cc * xnoi
            s2 = -0.5 * s3 / rtemsq
            s4 = s3 * rtemsq
            s1 = -15.0 * em * s4
            s5 = x1 * x3 + x2 * x4
            s6 = x2 * x3 + x1 * x4
            s7 = x2 * x4 - x1 * x3

            // ---- do lunar terms ----
            if lsflg == 1 {
                ss1 = s1; ss2 = s2; ss3 = s3; ss4 = s4; ss5 = s5; ss6 = s6; ss7 = s7
                sz1 = z1; sz2 = z2; sz3 = z3
                sz11 = z11; sz12 = z12; sz13 = z13
                sz21 = z21; sz22 = z22; sz23 = z23
                sz31 = z31; sz32 = z32; sz33 = z33
                zcosg = zcosgl
                zsing = zsingl
                zcosi = zcosil
                zsini = zsinil
                zcosh = zcoshl * cnodm + zsinhl * snodm
                zsinh = snodm * zcoshl - cnodm * zsinhl
                cc = c1l
            }
        }

        zmol = fmod(4.7199672 + 0.22997150 * day - gam, twopi)
        zmos = fmod(6.2565837 + 0.017201977 * day, twopi)

        // ---- do solar terms ----
        se2 = 2.0 * ss1 * ss6
        se3 = 2.0 * ss1 * ss7
        si2 = 2.0 * ss2 * sz12
        si3 = 2.0 * ss2 * (sz13 - sz11)
        sl2 = -2.0 * ss3 * sz2
        sl3 = -2.0 * ss3 * (sz3 - sz1)
        sl4 = -2.0 * ss3 * (-21.0 - 9.0 * emsq) * zes
        sgh2 = 2.0 * ss4 * sz32
        sgh3 = 2.0 * ss4 * (sz33 - sz31)
        sgh4 = -18.0 * ss4 * zes
        sh2 = -2.0 * ss2 * sz22
        sh3 = -2.0 * ss2 * (sz23 - sz21)

        // ---- do lunar terms ----
        ee2 = 2.0 * s1 * s6
        e3 = 2.0 * s1 * s7
        xi2 = 2.0 * s2 * z12
        xi3 = 2.0 * s2 * (z13 - z11)
        xl2 = -2.0 * s3 * z2
        xl3 = -2.0 * s3 * (z3 - z1)
        xl4 = -2.0 * s3 * (-21.0 - 9.0 * emsq) * zel
        xgh2 = 2.0 * s4 * z32
        xgh3 = 2.0 * s4 * (z33 - z31)
        xgh4 = -18.0 * s4 * zel
        xh2 = -2.0 * s2 * z22
        xh3 = -2.0 * s2 * (z23 - z21)

        o.s1 = s1; o.s2 = s2; o.s3 = s3; o.s4 = s4; o.s5 = s5
        o.ss1 = ss1; o.ss2 = ss2; o.ss3 = ss3; o.ss4 = ss4; o.ss5 = ss5
        o.sz1 = sz1; o.sz3 = sz3; o.sz11 = sz11; o.sz13 = sz13; o.sz21 = sz21; o.sz23 = sz23
        o.sz31 = sz31; o.sz33 = sz33
        o.z1 = z1; o.z3 = z3; o.z11 = z11; o.z13 = z13; o.z21 = z21; o.z23 = z23; o.z31 = z31; o.z33 = z33
        return o
    }

    /// Deep space long-period periodic contributions to the mean elements (`dpper` with init = 'n').
    private func dpper(t: Double, ep: inout Double, inclp: inout Double, nodep: inout Double,
                       argpp: inout Double, mp: inout Double) {
        let zns = 1.19459e-5, zes = 0.01675, znl = 1.5835218e-4, zel = 0.0549

        // ---- calculate time varying periodics ----
        var zm = zmos + zns * t
        var zf = zm + 2.0 * zes * sin(zm)
        var sinzf = sin(zf)
        var f2 = 0.5 * sinzf * sinzf - 0.25
        var f3 = -0.5 * sinzf * cos(zf)
        let ses = se2 * f2 + se3 * f3
        let sis = si2 * f2 + si3 * f3
        let sls = sl2 * f2 + sl3 * f3 + sl4 * sinzf
        let sghs = sgh2 * f2 + sgh3 * f3 + sgh4 * sinzf
        let shs = sh2 * f2 + sh3 * f3
        zm = zmol + znl * t
        zf = zm + 2.0 * zel * sin(zm)
        sinzf = sin(zf)
        f2 = 0.5 * sinzf * sinzf - 0.25
        f3 = -0.5 * sinzf * cos(zf)
        let sel = ee2 * f2 + e3 * f3
        let sil = xi2 * f2 + xi3 * f3
        let sll = xl2 * f2 + xl3 * f3 + xl4 * sinzf
        let sghl = xgh2 * f2 + xgh3 * f3 + xgh4 * sinzf
        let shll = xh2 * f2 + xh3 * f3
        let pe = ses + sel - peo
        let pinc = sis + sil - pinco
        let pl = sls + sll - plo
        var pgh = sghs + sghl - pgho
        var ph = shs + shll - pho
        inclp = inclp + pinc
        ep = ep + pe
        let sinip = sin(inclp)
        let cosip = cos(inclp)

        // ---- apply periodics directly (sgp4fix: Lyddane choice uses the perturbed inclination) ----
        if inclp >= 0.2 {
            ph /= sinip
            pgh -= cosip * ph
            argpp += pgh
            nodep += ph
            mp += pl
        } else {
            // ---- apply periodics with lyddane modification ----
            let sinop = sin(nodep), cosop = cos(nodep)
            var alfdp = sinip * sinop
            var betdp = sinip * cosop
            let dalf = ph * cosop + pinc * cosip * sinop
            let dbet = -ph * sinop + pinc * cosip * cosop
            alfdp = alfdp + dalf
            betdp = betdp + dbet
            nodep = fmod(nodep, Self.twopi)
            let xls = mp + argpp + pl + pgh + (cosip - pinc * sinip) * nodep
            let xnoh = nodep
            nodep = atan2(alfdp, betdp)
            if abs(xnoh - nodep) > .pi {
                nodep = nodep < xnoh ? nodep + Self.twopi : nodep - Self.twopi
            }
            mp += pl
            argpp = xls - mp - cosip * nodep
        }
    }

    /// Deep space resonance terms (12 h and 24 h orbits), at initialisation.
    private mutating func dsinit(ds: DSCom, t: Double, tc: Double, xpidot: Double, eccsq: Double, inclm: Double) {
        let q22 = 1.7891679e-6, q31 = 2.1460748e-6, q33 = 2.2123015e-7
        let root22 = 1.7891679e-6, root44 = 7.3636953e-9, root54 = 2.1765803e-9
        let rptim = 4.37526908801129966e-3, root32 = 3.7393792e-7, root52 = 1.1428639e-7
        let x2o3 = 2.0 / 3.0, znl = 1.5835218e-4, zns = 1.19459e-5
        let cosim = ds.cosim, sinim = ds.sinim, nm = ds.nm, em = ds.em, emsq = ds.emsq

        // ---- deep space initialization ----
        irez = 0
        if nm < 0.0052359877 && nm > 0.0034906585 { irez = 1 }
        if nm >= 8.26e-3 && nm <= 9.24e-3 && em >= 0.5 { irez = 2 }

        // ---- do solar terms ----
        let ses = ds.ss1 * zns * ds.ss5
        let sis = ds.ss2 * zns * (ds.sz11 + ds.sz13)
        let sls = -zns * ds.ss3 * (ds.sz1 + ds.sz3 - 14.0 - 6.0 * emsq)
        let sghs = ds.ss4 * zns * (ds.sz31 + ds.sz33 - 6.0)
        var shs = -zns * ds.ss2 * (ds.sz21 + ds.sz23)
        // sgp4fix for 180 deg incl
        if inclm < 5.2359877e-2 || inclm > .pi - 5.2359877e-2 { shs = 0.0 }
        if sinim != 0.0 { shs = shs / sinim }
        let sgs = sghs - cosim * shs

        // ---- do lunar terms ----
        dedt = ses + ds.s1 * znl * ds.s5
        didt = sis + ds.s2 * znl * (ds.z11 + ds.z13)
        dmdt = sls - znl * ds.s3 * (ds.z1 + ds.z3 - 14.0 - 6.0 * emsq)
        let sghl = ds.s4 * znl * (ds.z31 + ds.z33 - 6.0)
        var shll = -znl * ds.s2 * (ds.z21 + ds.z23)
        if inclm < 5.2359877e-2 || inclm > .pi - 5.2359877e-2 { shll = 0.0 }
        domdt = sgs + sghl
        dnodt = shs
        if sinim != 0.0 {
            domdt = domdt - cosim / sinim * shll
            dnodt = dnodt + shll / sinim
        }

        // ---- calculate deep space resonance effects ----
        let theta = fmod(gsto + tc * rptim, Self.twopi)
        // (The mean elements advanced here by dedt·t etc. are discarded by sgp4init; t = 0 anyway.)

        guard irez != 0 else { return }
        let aonv = pow(nm / g.xke, x2o3)

        // ---- geopotential resonance for 12 hour orbits ----
        if irez == 2 {
            let cosisq = cosim * cosim
            let em = ecco
            let emsq = eccsq
            let eoc = em * emsq
            let g201 = -0.306 - (em - 0.64) * 0.440
            var g211: Double, g310: Double, g322: Double, g410: Double, g422: Double, g520: Double
            var g521: Double, g532: Double, g533: Double
            if em <= 0.65 {
                g211 = 3.616 - 13.2470 * em + 16.2900 * emsq
                g310 = -19.302 + 117.3900 * em - 228.4190 * emsq + 156.5910 * eoc
                g322 = -18.9068 + 109.7927 * em - 214.6334 * emsq + 146.5816 * eoc
                g410 = -41.122 + 242.6940 * em - 471.0940 * emsq + 313.9530 * eoc
                g422 = -146.407 + 841.8800 * em - 1629.014 * emsq + 1083.4350 * eoc
                g520 = -532.114 + 3017.977 * em - 5740.032 * emsq + 3708.2760 * eoc
            } else {
                g211 = -72.099 + 331.819 * em - 508.738 * emsq + 266.724 * eoc
                g310 = -346.844 + 1582.851 * em - 2415.925 * emsq + 1246.113 * eoc
                g322 = -342.585 + 1554.908 * em - 2366.899 * emsq + 1215.972 * eoc
                g410 = -1052.797 + 4758.686 * em - 7193.992 * emsq + 3651.957 * eoc
                g422 = -3581.690 + 16178.110 * em - 24462.770 * emsq + 12422.520 * eoc
                g520 = em > 0.715
                    ? -5149.66 + 29936.92 * em - 54087.36 * emsq + 31324.56 * eoc
                    : 1464.74 - 4664.75 * em + 3763.64 * emsq
            }
            if em < 0.7 {
                g533 = -919.22770 + 4988.6100 * em - 9064.7700 * emsq + 5542.21 * eoc
                g521 = -822.71072 + 4568.6173 * em - 8491.4146 * emsq + 5337.524 * eoc
                g532 = -853.66600 + 4690.2500 * em - 8624.7700 * emsq + 5341.4 * eoc
            } else {
                g533 = -37995.780 + 161616.52 * em - 229838.20 * emsq + 109377.94 * eoc
                g521 = -51752.104 + 218913.95 * em - 309468.16 * emsq + 146349.42 * eoc
                g532 = -40023.880 + 170470.89 * em - 242699.48 * emsq + 115605.82 * eoc
            }
            let sini2 = sinim * sinim
            let f220 = 0.75 * (1.0 + 2.0 * cosim + cosisq)
            let f221 = 1.5 * sini2
            let f321 = 1.875 * sinim * (1.0 - 2.0 * cosim - 3.0 * cosisq)
            let f322 = -1.875 * sinim * (1.0 + 2.0 * cosim - 3.0 * cosisq)
            let f441 = 35.0 * sini2 * f220
            let f442 = 39.3750 * sini2 * sini2
            let f522 = 9.84375 * sinim * (sini2 * (1.0 - 2.0 * cosim - 5.0 * cosisq)
                + 0.33333333 * (-2.0 + 4.0 * cosim + 6.0 * cosisq))
            let f523 = sinim * (4.92187512 * sini2 * (-2.0 - 4.0 * cosim + 10.0 * cosisq)
                + 6.56250012 * (1.0 + 2.0 * cosim - 3.0 * cosisq))
            let f542 = 29.53125 * sinim * (2.0 - 8.0 * cosim + cosisq * (-12.0 + 8.0 * cosim + 10.0 * cosisq))
            let f543 = 29.53125 * sinim * (-2.0 - 8.0 * cosim + cosisq * (12.0 + 8.0 * cosim - 10.0 * cosisq))
            let xno2 = nm * nm
            let ainv2 = aonv * aonv
            var temp1 = 3.0 * xno2 * ainv2
            var temp = temp1 * root22
            d2201 = temp * f220 * g201
            d2211 = temp * f221 * g211
            temp1 = temp1 * aonv
            temp = temp1 * root32
            d3210 = temp * f321 * g310
            d3222 = temp * f322 * g322
            temp1 = temp1 * aonv
            temp = 2.0 * temp1 * root44
            d4410 = temp * f441 * g410
            d4422 = temp * f442 * g422
            temp1 = temp1 * aonv
            temp = temp1 * root52
            d5220 = temp * f522 * g520
            d5232 = temp * f523 * g532
            temp = 2.0 * temp1 * root54
            d5421 = temp * f542 * g521
            d5433 = temp * f543 * g533
            xlamo = fmod(mo + nodeo + nodeo - theta - theta, Self.twopi)
            xfact = mdot + dmdt + 2.0 * (nodedot + dnodt - rptim) - noUnkozai
        }

        // ---- synchronous resonance terms ----
        if irez == 1 {
            let g200 = 1.0 + emsq * (-2.5 + 0.8125 * emsq)
            let g310 = 1.0 + 2.0 * emsq
            let g300 = 1.0 + emsq * (-6.0 + 6.60937 * emsq)
            let f220 = 0.75 * (1.0 + cosim) * (1.0 + cosim)
            let f311 = 0.9375 * sinim * sinim * (1.0 + 3.0 * cosim) - 0.75 * (1.0 + cosim)
            var f330 = 1.0 + cosim
            f330 = 1.875 * f330 * f330 * f330
            del1 = 3.0 * nm * nm * aonv * aonv
            del2 = 2.0 * del1 * f220 * g200 * q22
            del3 = 3.0 * del1 * f330 * g300 * q33 * aonv
            del1 = del1 * f311 * g310 * q31 * aonv
            xlamo = fmod(mo + nodeo + argpo - theta, Self.twopi)
            xfact = mdot + xpidot - rptim + dmdt + domdt + dnodt - noUnkozai
        }

        // ---- for sgp4, initialize the integrator ----
        xli = xlamo
        xni = noUnkozai
    }

    /// Deep space secular effects and resonance integration (`dspace`). Integrates from the epoch on every
    /// call (stateless), which gives the same result as the original's cached integrator.
    private func dspace(t: Double, tc: Double, em: inout Double, argpm: inout Double, inclm: inout Double,
                        mm: inout Double, nodem: inout Double, nm: inout Double) {
        let fasx2 = 0.13130908, fasx4 = 2.8843198, fasx6 = 0.37448087
        let g22 = 5.7686396, g32 = 0.95240898, g44 = 1.8014998, g52 = 1.0508330, g54 = 4.4108898
        let rptim = 4.37526908801129966e-3
        let stepp = 720.0, stepn = -720.0, step2 = 259200.0

        // ---- calculate deep space resonance effects ----
        let theta = fmod(gsto + tc * rptim, Self.twopi)
        em = em + dedt * t
        inclm = inclm + didt * t
        argpm = argpm + domdt * t
        nodem = nodem + dnodt * t
        mm = mm + dmdt * t

        guard irez != 0 else { return }
        // ---- update resonances: numerical (euler-maclaurin) integration, from the epoch ----
        var atime = 0.0
        var xni = noUnkozai
        var xli = xlamo
        let delt = t > 0.0 ? stepp : stepn
        var ft = 0.0
        var xndt = 0.0, xldot = 0.0, xnddt = 0.0
        while true {
            // ---- dot terms calculated ----
            if irez != 2 {
                // near-synchronous resonance terms
                xndt = del1 * sin(xli - fasx2) + del2 * sin(2.0 * (xli - fasx4)) + del3 * sin(3.0 * (xli - fasx6))
                xldot = xni + xfact
                xnddt = del1 * cos(xli - fasx2) + 2.0 * del2 * cos(2.0 * (xli - fasx4))
                    + 3.0 * del3 * cos(3.0 * (xli - fasx6))
                xnddt = xnddt * xldot
            } else {
                // near-half-day resonance terms
                let xomi = argpo + argpdot * atime
                let x2omi = xomi + xomi
                let x2li = xli + xli
                xndt = d2201 * sin(x2omi + xli - g22) + d2211 * sin(xli - g22)
                    + d3210 * sin(xomi + xli - g32) + d3222 * sin(-xomi + xli - g32)
                    + d4410 * sin(x2omi + x2li - g44) + d4422 * sin(x2li - g44)
                    + d5220 * sin(xomi + xli - g52) + d5232 * sin(-xomi + xli - g52)
                    + d5421 * sin(xomi + x2li - g54) + d5433 * sin(-xomi + x2li - g54)
                xldot = xni + xfact
                xnddt = d2201 * cos(x2omi + xli - g22) + d2211 * cos(xli - g22)
                    + d3210 * cos(xomi + xli - g32) + d3222 * cos(-xomi + xli - g32)
                    + d5220 * cos(xomi + xli - g52) + d5232 * cos(-xomi + xli - g52)
                    + 2.0 * (d4410 * cos(x2omi + x2li - g44) + d4422 * cos(x2li - g44)
                        + d5421 * cos(xomi + x2li - g54) + d5433 * cos(-xomi + x2li - g54))
                xnddt = xnddt * xldot
            }
            // ---- integrator ----
            if abs(t - atime) >= stepp {
                xli = xli + xldot * delt + xndt * step2
                xni = xni + xndt * delt + xnddt * step2
                atime = atime + delt
            } else {
                ft = t - atime
                break
            }
        }
        nm = xni + xndt * ft + xnddt * ft * ft * 0.5
        let xl = xli + xldot * ft + xndt * ft * ft * 0.5
        if irez != 1 {
            mm = xl - 2.0 * nodem + 2.0 * theta
        } else {
            mm = xl - nodem - argpm + theta
        }
        let dndt = nm - noUnkozai
        nm = noUnkozai + dndt
    }

    // MARK: - Time

    /// Greenwich mean sidereal time (radians, 0..<2π) for a UT1 Julian date (Vallado eq. 3-45).
    public static func gstime(_ jdut1: Double) -> Double {
        let tut1 = (jdut1 - 2451545.0) / 36525.0
        var temp = -6.2e-6 * tut1 * tut1 * tut1 + 0.093104 * tut1 * tut1
            + (876600.0 * 3600 + 8640184.812866) * tut1 + 67310.54841     // seconds
        temp = fmod(temp * deg2rad / 240.0, twopi)                         // 360/86400 = 1/240, to deg, to rad
        if temp < 0.0 { temp += twopi }
        return temp
    }

    /// Julian date (UTC) of a `Date`.
    public static func julianDate(_ date: Date) -> Double {
        2440587.5 + date.timeIntervalSince1970 / 86400.0
    }
}
