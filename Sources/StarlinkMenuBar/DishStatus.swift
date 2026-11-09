import Foundation

/// Decoded subset of SpaceX.API.Device.DishGetStatusResponse.
/// Field numbers verified against dish firmware 2026.10.09 via gRPC reflection.
struct DishStatus: Sendable {
    // DeviceInfo (1) / DeviceState (2)
    var id = ""
    var hardwareVersion = ""
    var softwareVersion = ""
    var countryCode = ""
    var bootcount: Int32 = 0
    var uptimeS: UInt64 = 0

    // Link
    var popPingDropRate: Float = 0          // 1003, 0…1
    var popPingLatencyMs: Float = 0         // 1009
    var downlinkBps: Float = 0              // 1007
    var uplinkBps: Float = 0                // 1008
    var signalQuality: Float?               // 1057, 0…1 (absent on older firmware or when 0)
    var isSnrAboveNoiseFloor = false        // 1018
    var isSnrPersistentlyLow = false        // 1022
    var ethSpeedMbps: Int32 = 0             // 1016
    var stowRequested = false               // 1010
    var secondsToFirstNonemptySlot: Float = 0 // 1002

    var obstruction = Obstruction()         // 1004
    var alerts: [Alert] = []                // 1005 (only the active ones)
    var outage: Outage?                     // 1014
    var gps = GPS()                         // 1015
    var alignment = Alignment()             // 1027 (falls back to 1011/1012)
    var readyStates: [String: Bool] = [:]   // 1019

    var mobilityClass = ""                  // 1017
    var classOfService = ""                 // 1020
    var softwareUpdateState = ""            // 1021
    var disablementCode: Int = 0            // 1024 (1 = OKAY)
    var connectedRouters: [String] = []     // 1040
    var nedToDishQuaternion: (w: Float, x: Float, y: Float, z: Float)? // 1049

    struct Obstruction: Sendable {
        var fractionObstructed: Float = 0        // 1
        var validS: Float = 0                    // 4
        var currentlyObstructed = false          // 5
        var avgProlongedDurationS: Float = .nan  // 6
        var avgProlongedIntervalS: Float = .nan  // 7
        var avgProlongedValid = false            // 8
        var timeObstructed: Float = 0            // 9 (fraction of time, 0…1)
        var patchesValid: UInt32 = 0             // 10
    }

    struct Alert: Sendable, Hashable {
        let field: Int
        let key: String
        let title: String
        let kind: Kind
        enum Kind: Sendable { case alignment, thermal, hardware, network, info }
    }

    struct Outage: Sendable {
        var cause: Int
        var startNs: Int64
        var durationNs: UInt64
        var causeName: String { Self.causes[cause] ?? "UNKNOWN(\(cause))" }
        static let causes: [Int: String] = [
            0: "Unknown", 1: "Booting", 2: "Stowed", 3: "Thermal shutdown", 4: "No schedule",
            5: "No satellites", 6: "Obstructed", 7: "No downlink", 8: "No pings",
            9: "Actuator activity", 10: "Cable test", 11: "Sleeping", 13: "Sky search", 14: "RF inhibited",
        ]
    }

    struct GPS: Sendable {
        var valid = false
        var sats: UInt32 = 0
    }

    struct Alignment: Sendable {
        var hasActuators = 0              // 0 unknown, 1 yes, 2 no
        var actuatorState = 0
        var tiltAngleDeg: Float = 0
        var azimuthDeg: Float = 0
        var elevationDeg: Float = 0
        var attitudeState = 0             // 2 = FILTER_CONVERGED
        var attitudeUncertaintyDeg: Float = 0
        var desiredAzimuthDeg: Float?
        var desiredElevationDeg: Float?

        var attitudeConverged: Bool { attitudeState == 2 }

        /// Great-circle angle between where the dish points and where it wants to point.
        var errorDeg: Double? {
            guard let daz = desiredAzimuthDeg, let del = desiredElevationDeg else { return nil }
            func vec(_ az: Float, _ el: Float) -> (Double, Double, Double) {
                let a = Double(az) * .pi / 180, e = Double(el) * .pi / 180
                return (cos(e) * sin(a), cos(e) * cos(a), sin(e))
            }
            let p = vec(azimuthDeg, elevationDeg), q = vec(daz, del)
            let dot = max(-1, min(1, p.0 * q.0 + p.1 * q.1 + p.2 * q.2))
            return acos(dot) * 180 / .pi
        }

        /// Signed rotation needed (+ = clockwise seen from above), normalized to ±180°.
        var azimuthCorrectionDeg: Double? {
            guard let daz = desiredAzimuthDeg else { return nil }
            var d = Double(daz - azimuthDeg).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }

        /// + = raise boresight toward zenith, − = lower toward horizon.
        var elevationCorrectionDeg: Double? {
            desiredElevationDeg.map { Double($0 - elevationDeg) }
        }

        static let actuatorStates = [
            0: "Idle", 1: "Full tilt", 2: "Rotating", 3: "Tilting", 4: "Unwrap +", 5: "Unwrap −",
            6: "Tilting to stow", 7: "Faulted", 8: "Waiting until static", 9: "Driving to mobile position",
            10: "Mobile wait",
        ]
        static let attitudeStates = [0: "Reset", 1: "Unconverged", 2: "Converged", 3: "Faulted", 4: "Invalid"]
    }

    var isDisabled: Bool { disablementCode > 1 }

    static let disablementCodes = [
        0: "Unknown", 1: "OK", 2: "No active account", 3: "Too far from service address", 4: "In ocean",
        6: "Blocked country", 7: "Data overage", 8: "Cell disabled", 10: "Roaming restricted",
        11: "Unknown location", 12: "Account disabled", 13: "Unsupported version",
        14: "Moving too fast for plan", 15: "Aviation flyover limits", 16: "Blocked area",
        17: "Outside home region",
    ]

    // DishAlerts field number → (key, human title, kind)
    static let alertDefs: [Int: (String, String, Alert.Kind)] = [
        1: ("motors_stuck", "Motors stuck", .hardware),
        2: ("thermal_shutdown", "Thermal shutdown", .thermal),
        3: ("thermal_throttle", "Thermal throttling", .thermal),
        4: ("unexpected_location", "Unexpected location", .info),
        5: ("mast_not_near_vertical", "Mast not near vertical", .alignment),
        6: ("slow_ethernet_speeds", "Slow Ethernet speeds", .network),
        8: ("install_pending", "Software install pending", .info),
        9: ("is_heating", "Snow melt heating", .info),
        10: ("power_supply_thermal_throttle", "Power supply thermal throttle", .thermal),
        11: ("is_power_save_idle", "Power-save idle", .info),
        14: ("dbf_telem_stale", "Beamformer telemetry stale", .hardware),
        16: ("low_motor_current", "Low motor current", .hardware),
        17: ("lower_signal_than_predicted", "Lower signal than predicted", .alignment),
        18: ("slow_ethernet_speeds_100", "Ethernet limited to 100 Mbps", .network),
        19: ("obstruction_map_reset", "Obstruction map reset", .info),
        20: ("dish_water_detected", "Water detected in dish", .hardware),
        21: ("router_water_detected", "Water detected in router", .hardware),
        22: ("upsu_router_port_slow", "Router port slow", .network),
        23: ("no_ethernet_link", "No Ethernet link", .network),
    ]

    init() {}

    init(_ m: ProtoMessage) {
        if let di = m.message(1) {
            id = di.string(1) ?? ""
            hardwareVersion = di.string(2) ?? ""
            softwareVersion = di.string(3) ?? ""
            countryCode = di.string(4) ?? ""
            bootcount = di.int32(8) ?? 0
        }
        uptimeS = m.message(2)?.uint(1) ?? 0

        secondsToFirstNonemptySlot = m.float(1002) ?? 0
        popPingDropRate = m.float(1003) ?? 0
        downlinkBps = m.float(1007) ?? 0
        uplinkBps = m.float(1008) ?? 0
        popPingLatencyMs = m.float(1009) ?? 0
        stowRequested = m.bool(1010)
        ethSpeedMbps = m.int32(1016) ?? 0
        isSnrAboveNoiseFloor = m.bool(1018)
        isSnrPersistentlyLow = m.bool(1022)
        signalQuality = m.float(1057)
        disablementCode = Int(m.uint(1024) ?? 0)
        connectedRouters = m.strings(1040)

        mobilityClass = [0: "Stationary", 1: "Nomadic", 2: "Mobile"][Int(m.uint(1017) ?? 0)] ?? "?"
        classOfService = [0: "Unknown", 1: "Consumer", 2: "Business", 3: "Business+", 4: "Aviation"][Int(m.uint(1020) ?? 0)] ?? "?"
        softwareUpdateState = [0: "Unknown", 1: "Idle", 2: "Fetching", 3: "Pre-check", 4: "Writing",
                               5: "Post-check", 6: "Reboot required", 7: "Disabled", 8: "Faulted"][Int(m.uint(1021) ?? 0)] ?? "?"

        if let o = m.message(1004) {
            obstruction.fractionObstructed = o.float(1) ?? 0
            obstruction.validS = o.float(4) ?? 0
            obstruction.currentlyObstructed = o.bool(5)
            obstruction.avgProlongedDurationS = o.float(6) ?? .nan
            obstruction.avgProlongedIntervalS = o.float(7) ?? .nan
            obstruction.avgProlongedValid = o.bool(8)
            obstruction.timeObstructed = o.float(9) ?? 0
            obstruction.patchesValid = UInt32(truncatingIfNeeded: o.uint(10) ?? 0)
        }

        if let a = m.message(1005) {
            alerts = Self.alertDefs.keys.sorted().compactMap { f in
                guard a.bool(f), let d = Self.alertDefs[f] else { return nil }
                return Alert(field: f, key: d.0, title: d.1, kind: d.2)
            }
            // Surface alerts newer than this build knows about, rather than silently dropping them.
            for f in a.fields.keys.sorted() where Self.alertDefs[f] == nil && a.bool(f) {
                alerts.append(Alert(field: f, key: "alert_\(f)", title: "Alert #\(f)", kind: .info))
            }
        }

        if let o = m.message(1014) {
            outage = Outage(cause: Int(o.uint(1) ?? 0), startNs: o.int(2) ?? 0, durationNs: o.uint(3) ?? 0)
        }

        if let g = m.message(1015) {
            gps.valid = g.bool(1)
            gps.sats = UInt32(truncatingIfNeeded: g.uint(2) ?? 0)
        }

        if let r = m.message(1019) {
            for (f, name) in [(1, "cady"), (2, "scp"), (3, "l1l2"), (4, "xphy"), (5, "aap"), (6, "rf")] {
                readyStates[name] = r.bool(f)
            }
        }

        if let al = m.message(1027) {
            alignment.hasActuators = Int(al.uint(1) ?? 0)
            alignment.actuatorState = Int(al.uint(2) ?? 0)
            alignment.tiltAngleDeg = al.float(3) ?? 0
            alignment.azimuthDeg = al.float(4) ?? 0
            alignment.elevationDeg = al.float(5) ?? 0
            alignment.attitudeState = Int(al.uint(6) ?? 0)
            alignment.attitudeUncertaintyDeg = al.float(7) ?? 0
            alignment.desiredAzimuthDeg = al.float(8)
            alignment.desiredElevationDeg = al.float(9)
        } else {
            alignment.azimuthDeg = m.float(1011) ?? 0
            alignment.elevationDeg = m.float(1012) ?? 0
        }

        if let q = m.message(1049) {
            nedToDishQuaternion = (q.float(1) ?? 0, q.float(2) ?? 0, q.float(3) ?? 0, q.float(4) ?? 0)
        }
    }
}

/// SpaceX.API.Device.DishGetObstructionMapResponse — a polar sky map, rows×cols, centred on
/// the dish boresight (FRAME_UT) or zenith (FRAME_EARTH). Values: −1 = no data,
/// otherwise 0…1 where 1 = clear line of sight.
struct ObstructionMap: Sendable {
    var rows = 0
    var cols = 0
    var snr: [Float] = []
    var maxThetaDeg: Float = 0
    var referenceFrame = 0  // 1 earth, 2 UT

    init(_ m: ProtoMessage) {
        rows = Int(m.uint(1) ?? 0)
        cols = Int(m.uint(2) ?? 0)
        snr = m.floats(3)
        maxThetaDeg = m.float(5) ?? 0
        referenceFrame = Int(m.uint(6) ?? 0)
    }
}

extension DishStatus {
    /// No internet through the dish right now: an outage is reported, or every PoP ping is lost (the
    /// reported latency is then stale, not a measurement).
    var linkBroken: Bool { outage != nil || popPingDropRate >= 0.99 }
}
