import SwiftUI

/// The popup: the whole window is the 3D sky view, with a heads-up display over it. Without a dish it
/// shrinks to a short "not connected" panel.
struct PopupView: View {
    @Bindable var monitor: DishMonitor
    /// Outlives the popup's open/close cycles so the scene isn't rebuilt and the orbit angle is kept.
    @State private var sky = SkyScene()
    @State private var contentSize: CGSize = .zero

    static let width: CGFloat = 400
    static let skyHeight: CGFloat = 390
    static let cornerRadius: CGFloat = 14

    var body: some View {
        Group {
            if let s = monitor.status {
                ZStack {
                    // The SCNView only exists while the popup is on screen: that stops its display link and
                    // all GPU work when hidden, rather than relying on SceneKit to go quiet by itself.
                    if monitor.isPopupOpen {
                        SkySceneView(sky: sky, status: s, map: monitor.obstructionMap, onRefresh: refresh)
                    } else {
                        Color(nsColor: SkyScene.background)
                    }
                    SkyHUD(status: s, history: monitor.history)
                }
                .frame(width: Self.width, height: Self.skyHeight)
            } else {
                NotConnectedPanel(monitor: monitor, onRefresh: refresh)
                    .frame(width: Self.width)
            }
        }
        .background(Color(nsColor: SkyScene.background))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .fixedSize(horizontal: false, vertical: true)
        // MenuBarExtra grows its window for taller content but doesn't shrink it again, which left a large
        // empty region when the dish disappeared. Size the window to the content explicitly.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .background(WindowSizer(contentSize: contentSize, cornerRadius: Self.cornerRadius))
        // MenuBarExtra keeps this view alive while the popup is closed, and onAppear/onDisappear don't
        // reliably track it, so watch the hosting window's visibility instead.
        .background(WindowVisibilityReader { monitor.isPopupOpen = $0 })
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

/// Everything drawn over the 3D view. Only the web link takes clicks; the rest lets drags through to
/// the scene.
struct SkyHUD: View {
    let status: DishStatus
    let history: [DishMonitor.Sample]

    static let textSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "cellularbars", variableValue: Double(Assessment.bars(status)) / 4)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .help("Signal: \(Assessment.bars(status)) of 4 bars")
                Spacer()
                Link(destination: URL(string: "http://192.168.100.1")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "link").foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1))
                        Text("Web").foregroundStyle(.white)
                    }
                    .font(.system(size: Self.textSize))
                }
                .help("Open the dish's web UI (192.168.100.1)")
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
        .overlay(alignment: .topLeading) {
            Text("latency · last \(minutes)m")
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 4).padding(.vertical, 2)
        }
    }

    private var minutes: Int {
        guard let f = samples.first?.date, let l = samples.last?.date else { return 0 }
        return max(1, Int((l.timeIntervalSince(f) / 60).rounded()))
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
/// Also makes the window itself invisible apart from the content: the system panel material behind it is
/// masked to the content's rounded shape, so no grey shows at the edges or corners.
private struct WindowSizer: NSViewRepresentable {
    let contentSize: CGSize
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        let size = contentSize
        guard size.width > 0, size.height > 0 else { return }
        DispatchQueue.main.async {                       // not during SwiftUI's layout pass
            guard let w = v.window else { return }
            Self.matchChrome(of: w, cornerRadius: cornerRadius)
            let current = w.contentRect(forFrameRect: w.frame).size
            guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
            var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
            w.setFrame(f, display: true, animate: false)
            w.invalidateShadow()
        }
    }

    private static func matchChrome(of w: NSWindow, cornerRadius r: CGFloat) {
        guard w.backgroundColor != .clear else { return }      // once per window
        w.isOpaque = false
        w.backgroundColor = .clear
        let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        func visit(_ view: NSView) {
            if let e = view as? NSVisualEffectView { e.maskImage = mask }
            view.subviews.forEach(visit)
        }
        if let root = w.contentView?.superview ?? w.contentView { visit(root) }
        w.invalidateShadow()
    }
}

/// Reports whether the hosting window is actually on screen (ordered in and not fully occluded).
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let v = VisibilityView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: VisibilityView, context: Context) { v.onChange = onChange }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
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
            // Defer: this can fire during a SwiftUI update pass.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }
    }
}
