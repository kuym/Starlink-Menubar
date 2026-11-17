import Foundation
import Observation
import Orbits

/// The Starlink constellation for the sky view's beams.
///
/// * TLEs come from CelesTrak (no account needed), fetched at most once a week and cached as a plain text
///   file (`~/Library/Caches/StarlinkMenuBar/starlink.tle`). A failed fetch keeps the old file and retries
///   after an hour.
/// * At launch and every 24 h after, every TLE is run through SGP4 once and reduced to Kepler elements fitted
///   for the following day (`Constellation`), so the per-second updates are cheap closed-form maths.
@MainActor
@Observable
final class SatelliteCatalog {
    static let shared = SatelliteCatalog()

    private(set) var constellation: Constellation?

    nonisolated static let source = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=tle")!
    static let refetchInterval: TimeInterval = 7 * 86400
    static let rebuildInterval: TimeInterval = 86400
    static let retryInterval: TimeInterval = 3600
    /// A real download has thousands of satellites; anything much smaller is an error page or a truncation.
    nonisolated static let minimumSatellites = 100

    nonisolated static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("StarlinkMenuBar", isDirectory: true).appendingPathComponent("starlink.tle")
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastFetchAttempt: Date = .distantPast

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sleep = await self.tick()
                // Wake at least hourly, so a Mac that slept through a due time catches up soon after.
                try? await Task.sleep(for: .seconds(min(max(sleep, 60), 3600)), tolerance: .seconds(300))
            }
        }
    }

    /// Fetches and rebuilds whatever is due; returns the seconds until something is next due.
    private func tick() async -> TimeInterval {
        let now = Date()
        var downloaded = false
        let age = Self.cacheAge(now: now)
        if (age ?? .infinity) > Self.refetchInterval, now.timeIntervalSince(lastFetchAttempt) > Self.retryInterval {
            lastFetchAttempt = now
            downloaded = await Self.download()
        }
        let built = constellation?.referenceDate
        if downloaded || built.map({ now.timeIntervalSince($0) > Self.rebuildInterval }) ?? true {
            if let c = await Self.buildFromCache(at: Date()) { constellation = c }
        }
        let nextFetch = (Self.cacheAge(now: now).map { Self.refetchInterval - $0 } ?? 0)
        let nextRetry = Self.retryInterval - now.timeIntervalSince(lastFetchAttempt)
        let nextBuild = constellation.map { Self.rebuildInterval - now.timeIntervalSince($0.referenceDate) } ?? Self.retryInterval
        return min(max(nextFetch, nextRetry), nextBuild)
    }

    /// Seconds since the cache file was written, nil if there is none.
    nonisolated static func cacheAge(now: Date = Date()) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(modified)
    }

    /// Downloads the catalogue and replaces the cache if it looks complete.
    nonisolated static func download() async -> Bool {
        var request = URLRequest(url: source, timeoutInterval: 30)
        request.setValue("StarlinkMenuBar (macOS menu bar app; weekly fetch)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
                  TLE.parseFile(text).count >= minimumSatellites else { return false }
            let dir = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Parses the cache and fits every satellite's Kepler orbit from `date` (off the main thread).
    nonisolated static func buildFromCache(at date: Date) async -> Constellation? {
        await Task.detached(priority: .utility) { loadCached(at: date) }.value
    }

    /// Synchronous version, for the snapshot tool.
    nonisolated static func loadCached(at date: Date = Date()) -> Constellation? {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }
        let c = Constellation(tles: TLE.parseFile(text), at: date)
        return c.count > 0 ? c : nil
    }
}
