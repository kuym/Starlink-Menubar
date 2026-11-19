import Foundation
import Network
import Observation

/// Polls the dish and publishes state for both the menu bar icon and the popup.
@MainActor
@Observable
final class DishMonitor {
    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let latencyMs: Float
        let dropRate: Float
        let downBps: Float
        let upBps: Float
        let obstructed: Bool
        /// No connectivity at this sample: its latency isn't a measurement.
        let broken: Bool
    }

    // What the popup shows. Published only while the popup is open (and once as it opens), so the hidden
    // popup's SwiftUI views aren't invalidated and re-laid-out on every poll.
    private(set) var status: DishStatus?
    private(set) var assessment: Assessment?
    private(set) var lastError: String?
    private(set) var lastUpdate: Date?
    private(set) var history: [Sample] = []
    private(set) var obstructionMap: ObstructionMap?
    private(set) var networkInterface: String?

    /// The menu bar icon: always current, but only assigned when it actually changes.
    private(set) var icon: IconState = .notOnStarlink

    /// Latest data, always current but not observed; copied to the published properties by `publish()`.
    @ObservationIgnored private var live = Live()
    private struct Live {
        var status: DishStatus?
        var assessment: Assessment?
        var lastError: String?
        var lastUpdate: Date?
        var history: [Sample] = []
        var obstructionMap: ObstructionMap?
    }

    /// Whether a dish is answering right now (unobserved, so current even while the popup is closed).
    var hasDish: Bool { live.status != nil }

    var isPopupOpen = false {
        didSet {
            guard isPopupOpen != oldValue else { return }
            if isPopupOpen {
                publish()
                lastMapFetch = .distantPast     // and fetch a fresh map
            }
            start()                             // poll now, at the new cadence
        }
    }

    private let client = DishClient()
    private var lastObstructedAt: Date?
    private var lastMapFetch: Date = .distantPast
    private var pollTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()

    /// Poll fast while the popup is showing live numbers; slower when only the menu bar icon needs to be
    /// current (still well inside the 20 s obstruction hold); back off when the dish is unreachable.
    private let openInterval: Duration = .seconds(2)
    private let idleInterval: Duration = .seconds(5)
    private let disconnectedInterval: Duration = .seconds(15)
    private let historyWindow: TimeInterval = 5 * 60

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let name = path.availableInterfaces.first?.name
            Task { @MainActor in
                guard let self else { return }
                let changed = self.networkInterface != name
                self.networkInterface = name
                if changed { await self.poll() }   // network switched: re-check immediately
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        start()
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                // While open, keep the map fresh. While closed, fetch it once (retrying rarely) so the
                // first open can render the complete scene on its first frame.
                let mapAge = Date().timeIntervalSince(self.lastMapFetch)
                if self.isPopupOpen ? mapAge > 30 : (self.live.obstructionMap == nil && mapAge > 300) {
                    await self.refreshMap()
                }
                let interval = self.live.status == nil ? self.disconnectedInterval
                    : self.isPopupOpen ? self.openInterval : self.idleInterval
                // Tolerance lets the OS coalesce this wakeup with others when idle.
                try? await Task.sleep(for: interval, tolerance: self.isPopupOpen ? .milliseconds(100) : .seconds(2))
            }
        }
    }

    func poll() async {
        do {
            let s = try await client.getStatus()
            let now = Date()
            if s.obstruction.currentlyObstructed || s.outage?.cause == 6 { lastObstructedAt = now }
            let recent = lastObstructedAt.map { now.timeIntervalSince($0) < Thresholds.obstructionHoldSeconds } ?? false
            live.status = s
            live.assessment = Assessment.evaluate(s, recentlyObstructed: recent)
            live.lastError = nil
            live.lastUpdate = now
            live.history.append(Sample(date: now, latencyMs: s.popPingLatencyMs, dropRate: s.popPingDropRate,
                                       downBps: s.downlinkBps, upBps: s.uplinkBps,
                                       obstructed: s.obstruction.currentlyObstructed, broken: s.linkBroken))
            live.history.removeAll { now.timeIntervalSince($0.date) > historyWindow }
        } catch {
            live.status = nil
            live.obstructionMap = nil
            live.history.removeAll()
            live.assessment = Assessment(icon: .notOnStarlink, headline: "Not connected via Starlink",
                                         detail: "No dish answering at 192.168.100.1")
            live.lastError = error.localizedDescription
            live.lastUpdate = Date()
        }
        let newIcon = live.assessment?.icon ?? .notOnStarlink
        if newIcon != icon { icon = newIcon }
        if isPopupOpen { publish() }
    }

    func refreshMap() async {
        guard live.status != nil else { return }
        lastMapFetch = Date()
        live.obstructionMap = try? await client.getObstructionMap()
        if isPopupOpen { publish() }
    }

    /// Copies the live data to the observed properties the popup reads.
    func publish() {
        status = live.status
        assessment = live.assessment
        lastError = live.lastError
        lastUpdate = live.lastUpdate
        history = live.history
        obstructionMap = live.obstructionMap
    }
}
