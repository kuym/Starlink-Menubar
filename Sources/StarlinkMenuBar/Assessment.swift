import Foundation

/// Turns raw dish telemetry into the single state the menu bar icon shows.
/// Every threshold lives here so it is easy to tune.
enum Thresholds {
    /// Pointing error (actual vs. desired boresight) that flips the icon to "misaligned".
    static let misalignedDeg = 10.0
    /// Pointing error that shows a softer warning in the popup only.
    static let alignmentWarnDeg = 5.0
    /// Keep the obstruction icon up this long after the last obstructed sample, so brief
    /// obstructions are visible instead of flickering for one 2-second poll.
    static let obstructionHoldSeconds: TimeInterval = 20
    /// Sky fraction obstructed that shows a warning in the popup.
    static let fractionObstructedWarn: Float = 0.05
}

enum IconState: Equatable {
    case notOnStarlink            // dish not reachable — we are not behind a Starlink dish
    case searching                // reachable but no service yet (booting, sky search, no sats…)
    case disabled                 // account / location disablement
    case obstructed
    case misaligned
    case hardwareFault(String)    // thermal shutdown, motors stuck, water…
    case bars(Int)                // 0…4
}

struct Assessment {
    var icon: IconState
    var headline: String
    var detail: String?

    static func evaluate(_ s: DishStatus, recentlyObstructed: Bool) -> Assessment {
        if s.isDisabled {
            return .init(icon: .disabled, headline: "Service disabled",
                         detail: DishStatus.disablementCodes[s.disablementCode])
        }
        if let fault = s.alerts.first(where: { $0.key == "thermal_shutdown" || $0.key == "motors_stuck"
                                               || $0.key == "dish_water_detected" }) {
            return .init(icon: .hardwareFault(fault.key), headline: fault.title, detail: nil)
        }
        if let o = s.outage {
            if o.cause == 6 {
                return .init(icon: .obstructed, headline: "Offline — obstructed", detail: nil)
            }
            return .init(icon: .searching, headline: "Offline — \(o.causeName.lowercased())", detail: nil)
        }
        if s.obstruction.currentlyObstructed || recentlyObstructed {
            return .init(icon: .obstructed, headline: "Obstructed",
                         detail: s.obstruction.currentlyObstructed ? "Sky view blocked right now" : "Obstructed in the last \(Int(Thresholds.obstructionHoldSeconds))s")
        }
        if s.alerts.contains(where: { $0.key == "mast_not_near_vertical" }) {
            return .init(icon: .misaligned, headline: "Misaligned", detail: "Mast not near vertical")
        }
        if s.alignment.attitudeConverged, let err = s.alignment.errorDeg, err >= Thresholds.misalignedDeg {
            return .init(icon: .misaligned, headline: "Misaligned",
                         detail: String(format: "Pointing %.1f° from optimal", err))
        }
        let n = bars(s)
        let label = ["No signal", "Poor", "Fair", "Good", "Excellent"][n]
        return .init(icon: .bars(n), headline: "Connected — \(label)", detail: nil)
    }

    /// 0…4 bars, primarily from the dish's own `signal_quality`, then penalised by what the
    /// user actually feels: packet loss to the PoP and latency.
    static func bars(_ s: DishStatus) -> Int {
        var b: Int
        if let q = s.signalQuality {
            switch q {
            case 0.9...: b = 4
            case 0.7..<0.9: b = 3
            case 0.45..<0.7: b = 2
            case 0.15..<0.45: b = 1
            default: b = 0
            }
        } else {
            // Older firmware: no explicit quality, infer from SNR flags.
            b = s.isSnrAboveNoiseFloor ? 4 : 1
        }
        if s.isSnrPersistentlyLow { b = min(b, 2) }
        if !s.isSnrAboveNoiseFloor { b = min(b, 1) }

        let drop = s.popPingDropRate
        if drop >= 0.99 { return 0 }
        if drop > 0.10 { b -= 2 } else if drop > 0.02 { b -= 1 }
        if s.popPingLatencyMs > 150 { b -= 2 } else if s.popPingLatencyMs > 80 { b -= 1 }
        return max(0, min(4, b))
    }
}
