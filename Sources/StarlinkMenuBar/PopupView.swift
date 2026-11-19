import Orbits
import SwiftUI

/// The popup: the whole window is the 3D sky view, with a heads-up display over it. Without a dish it
/// shrinks to a short "not connected" panel.
struct PopupView: View {
    @Bindable var monitor: DishMonitor
    var catalog = SatelliteCatalog.shared
    var location = ObserverLocation.shared
    /// Outlives the popup's open/close cycles so the scene isn't rebuilt and the orbit angle is kept.
    @State private var sky = SkyScene()
    @State private var contentSize: CGSize = .zero

    static let width: CGFloat = 400
    static let skyHeight: CGFloat = 435
    /// Corner radius before the window's own is known; replaced by the window's radius once shown.
    static let cornerRadius: CGFloat = 6
    @State private var cornerRadius = PopupView.cornerRadius

    var body: some View {
        Group {
            if let s = monitor.status {
                ZStack {
                    // The SCNView only exists while the popup is on screen: that stops its display link and
                    // all GPU work when hidden, rather than relying on SceneKit to go quiet by itself.
                    if monitor.isPopupOpen {
                        SkySceneView(sky: sky, status: s, map: monitor.obstructionMap,
                                     constellation: catalog.constellation, observer: location.observer,
                                     onRefresh: refresh)
                    } else {
                        Color(nsColor: SkyScene.background)
                    }
                    SkyHUD(status: s, history: monitor.history, location: location, onToggleZoom: { sky.toggleZoom?() })
                }
                .frame(width: Self.width, height: Self.skyHeight)
            } else {
                NotConnectedPanel(monitor: monitor, onRefresh: refresh)
                    .frame(width: Self.width)
            }
        }
        .background(Color(nsColor: SkyScene.background))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .circular))   // as the window mask
        .fixedSize(horizontal: false, vertical: true)
        // MenuBarExtra grows its window for taller content but doesn't shrink it again, which left a large
        // empty region when the dish disappeared. Size the window to the content explicitly.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .background(WindowSizer(contentSize: contentSize) { r in if r != cornerRadius { cornerRadius = r } })
        // MenuBarExtra keeps this view alive while the popup is closed, and onAppear/onDisappear don't
        // reliably track it, so watch the hosting window's visibility instead.
        .background(WindowVisibilityReader(waitsForScene: { [monitor] in monitor.hasDish }) { monitor.isPopupOpen = $0 })
        .background {
            Button("Quit") { NSApplication.shared.terminate(nil) }   // ⌘Q; also in the right-click menu
                .keyboardShortcut("q")
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func refresh() {
        Task { await monitor.poll(); await monitor.refreshMap() }
    }
}

// MARK: - HUD

/// Everything drawn over the 3D view. Only the signal meter, location and settings buttons take clicks; the rest lets drags through to
/// the scene.
struct SkyHUD: View {
    let status: DishStatus
    let history: [DishMonitor.Sample]
    var location = ObserverLocation.shared
    /// The satellite and signal meter zoom to the Earth view and back, like a double-click on the view.
    var onToggleZoom: () -> Void = {}

    static let textSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button { onToggleZoom() } label: {
                    HStack(alignment: .center, spacing: 2) {
                        SatelliteGlyph()
                            .fill(Self.accent, style: FillStyle(eoFill: true))
                            .frame(width: 23, height: 23)
                        Image(systemName: "cellularbars", variableValue: Double(Assessment.bars(status)) / 4)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Signal: \(Assessment.bars(status)) of 4 bars. Click to zoom out to the Earth view, or back in")
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    LocationButton(location: location)
                    Button { SettingsWindow.show() } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Self.accent)
                            .font(.system(size: 15))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings: open at login, the dish's web UI, quit")
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                LatencyGraph(samples: history)
                    .frame(height: 34)
                HStack(alignment: .firstTextBaseline) {
                    latencyText
                    Spacer(minLength: 8)
                    Text("ꜛ\(Self.rate(status.uplinkBps))  ꜜ\(Self.rate(status.downlinkBps))")
                        .multilineTextAlignment(.trailing)
                }
                .font(.system(size: Self.textSize).monospacedDigit())
                .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
        .padding(14)
    }

    static let accent = Color(red: 0.45, green: 0.72, blue: 1)

    /// "23ms  MAX 80  AVG 42": current, max and median over the graph's window ("-ms" while the link is down).
    private var latencyText: some View {
        let measured = history.filter { !$0.broken }.map(\.latencyMs).sorted()
        let current = status.linkBroken ? "-" : "\(Int(status.popPingLatencyMs.rounded()))"
        let small = Font.system(size: Self.textSize * 0.66, weight: .medium)
        func n(_ v: Float?) -> String { v.map { "\(Int($0.rounded()))" } ?? "-" }
        let median: Float? = measured.isEmpty ? nil : measured.count % 2 == 1
            ? measured[measured.count / 2] : (measured[measured.count / 2 - 1] + measured[measured.count / 2]) / 2
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(current)ms")
            Text("  ")
            Text("MAX").font(small)
            Text(" \(n(measured.last))  ")
            Text("AVG").font(small)
            Text(" \(n(median))")
        }
    }

    /// "%3.1f" plus kbps / mbps / gbps, chosen per value.
    static func rate(_ bps: Float) -> String {
        switch bps {
        case 1e9...: String(format: "%3.1fgbps", bps / 1e9)
        case 1e6...: String(format: "%3.1fmbps", bps / 1e6)
        default: String(format: "%3.1fkbps", bps / 1e3)
        }
    }
}

/// A satellite, for beside the signal meter (SF Symbols has none): a body with a dish antenna and a solar
/// panel either side, each split into two cells, turned 135° clockwise. Fill it even-odd.
struct SatelliteGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn upright on a 24 × 24 grid, then turned about the centre and fitted to `rect`.
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 9.5, y: 8.5, width: 5, height: 7), cornerSize: CGSize(width: 1, height: 1))
        for side in [-1.0, 1.0] {
            let x0 = side < 0 ? 1.0 : 16.0                      // panel's outer cells, 7 wide, a 1.5 gap from the body
            p.addRect(CGRect(x: x0, y: 9, width: 3.2, height: 6))
            p.addRect(CGRect(x: x0 + 3.8, y: 9, width: 3.2, height: 6))
            p.addRect(CGRect(x: side < 0 ? 8 : 14.5, y: 11.4, width: 1.5, height: 1.2))   // strut to the body
        }
        p.addRect(CGRect(x: 11.4, y: 6, width: 1.2, height: 2.5))                       // antenna mast
        p.move(to: CGPoint(x: 8.5, y: 3)); p.addQuadCurve(to: CGPoint(x: 15.5, y: 3), control: CGPoint(x: 12, y: 8.6))
        p.closeSubpath()                                                                   // the dish
        let fit = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(translationX: -12, y: -12)
            .concatenating(CGAffineTransform(rotationAngle: 3 * .pi / 4))     // clockwise (y down)
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
}

/// The observer position used for the satellite beams, as a small button: Cupertino until clicked, then
/// wherever macOS Location Services says the Mac is (asking permission the first time).
struct LocationButton: View {
    let location: ObserverLocation

    var body: some View {
        Button { location.requestSystemLocation() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(location.state == .denied ? .orange : SkyHUD.accent)
                Text(Self.coordinates(location.latitude, location.longitude))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .opacity(location.state == .locating ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(location.state == .locating)
        .help(help)
    }

    private var icon: String {
        switch location.state {
        case .denied: "location.slash"
        case .failed: "location"
        case .idle, .locating: location.isFromSystem ? "location.fill" : "location"
        }
    }

    private var help: String {
        switch location.state {
        case .denied: "Location access is off for Starlink Menu Bar (System Settings › Privacy & Security › Location Services)"
        case .failed: "Couldn't get the location; click to try again"
        case .locating: "Locating…"
        case .idle: location.isFromSystem
            ? "Satellites are shown for this location (from Location Services); click to update it"
            : "Satellites are shown for Cupertino, CA; click to use this Mac's location"
        }
    }

    static func coordinates(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.2f°%@ %.2f°%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }
}

/// Latency over the recent history. Orange bands = packet loss above 1%, red = above 10%. The line breaks
/// wherever the link was down, since there's no latency to plot there.
struct LatencyGraph: View {
    let samples: [DishMonitor.Sample]

    static let line = Color(red: 1, green: 0.62, blue: 0.08)
    static let warn = Color(red: 1, green: 0.55, blue: 0.0)
    static let bad = Color(red: 1, green: 0.1, blue: 0.08)
    /// A pause between samples longer than this (e.g. the Mac slept) also breaks the line.
    static let maxGap: TimeInterval = 20

    var body: some View {
        Canvas { ctx, size in
            guard let first = samples.first?.date, let last = samples.last?.date else { return }
            let span = max(last.timeIntervalSince(first), 1)
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(first) / span) * size.width }

            // Loss bands: each sample covers half-way to its neighbours; runs of the same level merge into
            // one rectangle (adjacent ones would leave anti-aliasing seams).
            func level(_ s: DishMonitor.Sample) -> Int { s.broken || s.dropRate > 0.10 ? 2 : s.dropRate > 0.01 ? 1 : 0 }
            var i = 0
            while i < samples.count {
                let lv = level(samples[i])
                var j = i
                while j + 1 < samples.count, level(samples[j + 1]) == lv { j += 1 }
                if lv > 0 {
                    let lo = i > 0 ? (x(samples[i - 1].date) + x(samples[i].date)) / 2 : 0
                    let hi = j < samples.count - 1 ? (x(samples[j].date) + x(samples[j + 1].date)) / 2 : size.width
                    ctx.fill(Path(CGRect(x: lo, y: 0, width: max(hi - lo, 2), height: size.height)),
                             with: .color(lv == 2 ? Self.bad.opacity(0.85) : Self.warn.opacity(0.45)))
                }
                i = j + 1
            }

            let maxL = CGFloat(max(60, samples.filter { !$0.broken }.map(\.latencyMs).max() ?? 60)) * 1.15
            var path = Path()
            var penDown = false
            var prev: Date?
            for s in samples {
                defer { prev = s.date }
                if s.broken || prev.map({ s.date.timeIntervalSince($0) > Self.maxGap }) == true { penDown = false }
                guard !s.broken else { continue }
                let pt = CGPoint(x: x(s.date), y: size.height - 3 - CGFloat(s.latencyMs) / maxL * (size.height - 6))
                if penDown { path.addLine(to: pt) } else { path.move(to: pt) }
                penDown = true
            }
            // Dark halo first, so the line stays distinct where it crosses a loss band.
            ctx.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: .color(Self.line), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Not connected

private struct NotConnectedPanel: View {
    let monitor: DishMonitor
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: StatusIcon.image(for: monitor.icon))
                    .renderingMode(.original)
                    .scaleEffect(1.5)
                    .frame(width: 32, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.assessment?.headline ?? "Checking…").font(.headline)
                    if let d = monitor.assessment?.detail {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac's traffic doesn't appear to be going through a Starlink dish.")
                    .font(.callout)
                Text("The app looks for the dish's local API at 192.168.100.1:9201. That address answers on any network downstream of a Starlink dish — including through a third‑party router in bypass mode — as long as the router doesn't block it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let i = monitor.networkInterface {
                    LabeledContent("Active interface", value: i).font(.caption)
                }
                if let e = monitor.lastError {
                    Text(e).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Divider()
            HStack {
                Link("Open dish web UI", destination: URL(string: "http://192.168.100.1")!)
                    .font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
    }
}

enum Fmt {
    static func rate(_ bps: Float) -> String {
        switch bps {
        case 1e6...: String(format: "%.1f Mbps", bps / 1e6)
        case 1e3...: String(format: "%.0f kbps", bps / 1e3)
        default: String(format: "%.0f bps", bps)
        }
    }

    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 86400 ? [.day, .hour] : s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: s) ?? "—"
    }

    static func az(_ deg: Float) -> String {
        let d = (Double(deg).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return String(format: "%.0f° %@", d, dirs[Int((d + 11.25) / 22.5) % 16])
    }
}

/// Resizes the hosting window to exactly fit `contentSize`, keeping its top edge (under the menu bar) fixed.
/// Also hides the system panel backdrop (so no grey can show around the content) and reports the window's
/// own corner radius, so the content can be clipped to exactly the window's shape.
private struct WindowSizer: NSViewRepresentable {
    let contentSize: CGSize
    let onCornerRadius: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        let size = contentSize
        DispatchQueue.main.async { [onCornerRadius] in   // not during SwiftUI's layout pass
            guard let w = v.window else { return }
            Self.hideBackdrop(of: w)
            if let r = Self.cornerRadius(of: w) { onCornerRadius(r) }
            guard size.width > 0, size.height > 0 else { return }
            let current = w.contentRect(forFrameRect: w.frame).size
            guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
            var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
            w.setFrame(f, display: true, animate: false)
            w.invalidateShadow()
        }
    }

    /// MenuBarExtra draws its material with backdrop layers in the hosting view; the content covers the
    /// whole window, so hide them rather than let them show at the anti-aliased corners.
    private static func hideBackdrop(of w: NSWindow) {
        guard let host = w.contentView?.layer else { return }
        var changed = false
        for l in host.sublayers ?? [] {
            let name = String(describing: type(of: l))
            if (name.contains("Backdrop") || name.contains("Chameleon")) && !l.isHidden {
                l.isHidden = true
                changed = true
            }
        }
        if changed { w.invalidateShadow() }
    }

    /// The window server clips the panel with this resizable corner mask (radius 6 on macOS 26). Private,
    /// so it's looked up defensively; without it the content keeps its default radius.
    private static func cornerRadius(of w: NSWindow) -> CGFloat? {
        let sel = Selector(("_cornerMask"))
        guard w.responds(to: sel), let mask = w.perform(sel)?.takeUnretainedValue() as? NSImage else { return nil }
        let r = mask.capInsets.top
        return r > 0 && r < 40 ? r : nil
    }
}

/// Reports whether the hosting window is actually on screen (ordered in and not fully occluded).
private struct WindowVisibilityReader: NSViewRepresentable {
    /// Whether the popup will show the 3D view (there's a dish), so it should wait for its first frame before
    /// fading in. Asked as the window appears: the popup's published state only catches up after that.
    let waitsForScene: () -> Bool
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let v = VisibilityView()
        v.onChange = onChange
        v.waitsForScene = waitsForScene
        return v
    }

    func updateNSView(_ v: VisibilityView, context: Context) {
        v.onChange = onChange
        v.waitsForScene = waitsForScene
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        var waitsForScene: () -> Bool = { false }
        static let fadeInSeconds: TimeInterval = 0.05
        /// Fade in anyway if the scene hasn't drawn by then (the very first frame after launch takes ~0.3 s,
        /// while SceneKit sets up; later ones ~50 ms).
        static let firstFrameTimeout: TimeInterval = 1.0
        /// After hiding, the system's fade-out (~0.15 s) runs on the window; only then is it made transparent.
        static let clearAfterHiding: TimeInterval = 0.3
        private var pendingFadeIn: DispatchWorkItem?
        private var pendingClear: DispatchWorkItem?
        // Removed when the view leaves its window (viewDidMoveToWindow with nil); closures hold self weakly.
        private var observers: [NSObjectProtocol] = []
        private var visibleKVO: NSKeyValueObservation?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            visibleKVO = nil
            if let w = window {
                w.animationBehavior = .none          // the first opening is instant too (see `report`)
                if !w.isVisible { w.alphaValue = 0 }   // and starts transparent
                observers.append(NotificationCenter.default.addObserver(forName: .skySceneDidRenderFirstFrame, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fadeIn() }
                })
                visibleKVO = w.observe(\.isVisible) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.report() }
                }
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                             NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
                }
            }
            report()
        }

        private func report() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            guard visible != last else { return }
            last = visible
            // Like the system's own menu bar menus (battery, Wi-Fi…): appear at once, fade out when dismissed.
            // The window is reused, so set how it should animate next: instant ordering in while hidden, the
            // standard fade for ordering out while shown.
            window?.animationBehavior = visible ? .utilityWindow : .none
            // Opening: the window is ordered in fully transparent; it fades in over 50 ms once the scene has
            // rendered a whole frame, so the half-built first frames (background, then the scene) never show.
            if let w = window {
                pendingClear?.cancel(); pendingClear = nil
                pendingFadeIn?.cancel(); pendingFadeIn = nil
                if visible {
                    if w.alphaValue < 1 {
                        let fallback = DispatchWorkItem { [weak self] in self?.fadeIn() }
                        pendingFadeIn = fallback
                        DispatchQueue.main.asyncAfter(deadline: .now() + (waitsForScene() ? Self.firstFrameTimeout : 0), execute: fallback)
                    }
                } else {
                    let clear = DispatchWorkItem { [weak w] in if let w, !w.isVisible { w.alphaValue = 0 } }
                    pendingClear = clear
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearAfterHiding, execute: clear)
                }
            }
            // Defer: this can fire during a SwiftUI update pass.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        private func fadeIn() {
            pendingFadeIn?.cancel(); pendingFadeIn = nil
            guard let w = window, w.isVisible, w.alphaValue < 1 else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInSeconds
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
        }
    }
}
