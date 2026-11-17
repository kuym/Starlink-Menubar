import AppKit
import Metal
import Orbits
import SceneKit
import SwiftUI

struct StarlinkMenuBarApp: App {
    @State private var monitor = DishMonitor()

    init() {
        // Menu-bar-only app, even when run straight from `swift run` without an Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)
        SatelliteCatalog.shared.start()      // weekly TLE fetch, daily orbit fit
    }

    var body: some Scene {
        MenuBarExtra {
            PopupView(monitor: monitor)
        } label: {
            Image(nsImage: StatusIcon.image(for: monitor.icon))
        }
        .menuBarExtraStyle(.window)
    }
}

/// `StarlinkMenuBar --dump` prints one decoded status + assessment and exits (handy for debugging
/// field mappings after a firmware update).
if CommandLine.arguments.contains("--dump") {
    Task {
        do {
            let client = DishClient()
            let s = try await client.getStatus()
            let a = Assessment.evaluate(s, recentlyObstructed: false)
            print("assessment:", a.icon, "—", a.headline, a.detail ?? "")
            print("bars:", Assessment.bars(s), " signal_quality:", s.signalQuality.map { String($0) } ?? "nil")
            print(String(format: "latency %.1f ms  drop %.2f%%  down %@  up %@", s.popPingLatencyMs,
                         s.popPingDropRate * 100, Fmt.rate(s.downlinkBps), Fmt.rate(s.uplinkBps)))
            let o = s.obstruction
            print(String(format: "obstruction: now=%@ fraction=%.2f%% time=%.4f%% valid=%.0fs patches=%d",
                         o.currentlyObstructed ? "yes" : "no", o.fractionObstructed * 100,
                         o.timeObstructed * 100, o.validS, o.patchesValid))
            let al = s.alignment
            print(String(format: "alignment: az %.2f el %.2f tilt %.2f  desired az %.2f el %.2f  error %.2f°  attitude=%@",
                         al.azimuthDeg, al.elevationDeg, al.tiltAngleDeg, al.desiredAzimuthDeg ?? .nan,
                         al.desiredElevationDeg ?? .nan, al.errorDeg ?? .nan,
                         DishStatus.Alignment.attitudeStates[al.attitudeState] ?? "?"))
            if let q = s.nedToDishQuaternion { print("ned2dish quaternion: w \(q.w) x \(q.x) y \(q.y) z \(q.z)") }
            print("alerts:", s.alerts.map(\.key), " outage:", s.outage?.causeName ?? "none")
            print("device:", s.hardwareVersion, s.softwareVersion, "uptime", s.uptimeS, "s  gps", s.gps.sats,
                  "sats  eth", s.ethSpeedMbps, "Mbps ", s.classOfService, s.mobilityClass)
            let m = try await client.getObstructionMap()
            let known = m.snr.filter { $0 >= 0 }
            print("obstruction map: \(m.rows)x\(m.cols), frame \(m.referenceFrame == 2 ? "UT" : m.referenceFrame == 1 ? "earth" : "?"), max θ \(m.maxThetaDeg)°, \(known.count) cells with data, \(known.filter { $0 < 1 }.count) obstructed")
            exit(0)
        } catch {
            print("error:", error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
} else if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    /// `--snapshot <dir>` renders the popup and every icon state to PNGs (for docs / visual checks).
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    Task { @MainActor in
        let monitor = DishMonitor()
        await monitor.poll()
        await monitor.refreshMap()
        monitor.publish()
        // The 3D sky view is an SCNView, which ImageRenderer can't capture; render it offscreen instead.
        let sky = SkyScene()
        sky.update(status: monitor.status, map: monitor.obstructionMap, animated: false)
        // Satellite beams, from the cached TLEs (run the app once to download them).
        let constellation = SatelliteCatalog.loadCached()
        sky.beams.setConstellation(constellation)
        sky.beams.setObserver(ObserverLocation.shared.observer)
        print("satellites:", constellation.map { "\($0.count) in the cached catalogue" } ?? "no cached TLEs at \(SatelliteCatalog.cacheURL.path)")
        let scnView = SCNView(frame: CGRect(x: 0, y: 0, width: PopupView.width * 2, height: PopupView.skyHeight * 2),
                              options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        scnView.scene = sky.scene
        scnView.pointOfView = sky.cameraNode
        scnView.antialiasingMode = .multisampling4X
        let first = { SkyScene.applyLensShift(to: sky.cameraNode, viewport: scnView.bounds.size); sky.beams.renderFrame(cameraPosition: sky.cameraNode.simdWorldPosition); return scnView.snapshot() }()                         // the view as it first appears
        for v in sky.beams.lastVisible {
            print(String(format: "  in view: %6d  el %5.1f°  %6.0f km%@", v.satnum, v.elevationDeg, v.rangeKm, v.closest ? "  ← closest" : ""))
        }
        if let tiff = first.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("sky-initial.png"))
        }
        // The popup: ImageRenderer can't capture an SCNView, so composite the HUD over the snapshot.
        if let s = monitor.status {
            let popup = ZStack {
                Image(nsImage: first).resizable()
                SkyHUD(status: s, history: monitor.history)
            }
            .frame(width: PopupView.width, height: PopupView.skyHeight)
            .clipShape(RoundedRectangle(cornerRadius: PopupView.cornerRadius))
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: popup)
            r.scale = 2
            if let tiff = r.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("popup.png"))
            }
        }
        let views: [(String, Float, Float)] = [("south", 200, 34), ("west", 290, 30), ("north", 20, 30), ("top", 180, 88)]
        for (name, az, el) in views {
            sky.orbit(azimuthDeg: az, elevationDeg: el)
            let img = { SkyScene.applyLensShift(to: sky.cameraNode, viewport: scnView.bounds.size); sky.beams.renderFrame(cameraPosition: sky.cameraNode.simdWorldPosition); return scnView.snapshot() }()
            if let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("sky-\(name).png"))
            }
        }
        if var aligned = monitor.status {
            // Same scene with the target nudged to within tolerance, to check the "aligned" glow.
            aligned.alignment.desiredAzimuthDeg = aligned.alignment.azimuthDeg + 3
            aligned.alignment.desiredElevationDeg = aligned.alignment.elevationDeg - 2
            sky.update(status: aligned, map: monitor.obstructionMap, animated: false)
            sky.orbit(azimuthDeg: 200, elevationDeg: 34)
            if let tiff = { SkyScene.applyLensShift(to: sky.cameraNode, viewport: scnView.bounds.size); sky.beams.renderFrame(cameraPosition: sky.cameraNode.simdWorldPosition); return scnView.snapshot() }().tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("sky-aligned.png"))
            }
            // Far off (alignment mode): dimmed dots, camera parked facing the ideal orientation.
            var off = aligned
            off.alignment.desiredAzimuthDeg = aligned.alignment.azimuthDeg + 40
            off.alignment.desiredElevationDeg = aligned.alignment.elevationDeg + 12
            sky.update(status: off, map: monitor.obstructionMap, animated: false)
            if let az = sky.alignmentFocusAzimuthDeg {
                sky.orbit(azimuthDeg: az, elevationDeg: AutoOrbit.elevationDeg)
                if let tiff = { SkyScene.applyLensShift(to: sky.cameraNode, viewport: scnView.bounds.size); sky.beams.renderFrame(cameraPosition: sky.cameraNode.simdWorldPosition); return scnView.snapshot() }().tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("sky-alignment-mode.png"))
                }
            }
        }
        // Latency graph on synthetic data: clean, >1% loss (orange), >10% loss (red), link down (gap).
        let t0 = Date()
        let demo = (0..<150).map { i -> DishMonitor.Sample in
            let loss: Float = (40..<46).contains(i) ? 0.04 : (80..<84).contains(i) ? 0.3 : (110..<118).contains(i) ? 1 : 0
            return DishMonitor.Sample(date: t0.addingTimeInterval(Double(i) * 2), latencyMs: 30 + 12 * sin(Float(i) / 9),
                                      dropRate: loss, downBps: 0, upBps: 0, obstructed: false, broken: loss >= 1)
        }
        let g = ImageRenderer(content: LatencyGraph(samples: demo).frame(width: 372, height: 34).padding(8)
            .background(Color(nsColor: SkyScene.background)))
        g.scale = 2
        if let tiff = g.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("graph-demo.png"))
        }
        let states: [(String, IconState)] = [("bars0", .bars(0)), ("bars1", .bars(1)), ("bars2", .bars(2)),
            ("bars3", .bars(3)), ("bars4", .bars(4)), ("obstructed", .obstructed), ("misaligned", .misaligned),
            ("searching", .searching), ("disabled", .disabled), ("thermal", .hardwareFault("thermal_shutdown")),
            ("fault", .hardwareFault("motors_stuck")), ("not-starlink", .notOnStarlink)]
        let strip = HStack(spacing: 18) {
            ForEach(states, id: \.0) { name, s in
                VStack(spacing: 4) {
                    Image(nsImage: StatusIcon.image(for: s)).renderingMode(.original).foregroundStyle(.black)
                    Text(name).font(.system(size: 8))
                }
            }
        }.padding(10).background(Color.white)
        let r = ImageRenderer(content: strip)
        r.scale = 3
        if let tiff = r.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("icons.png"))
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    StarlinkMenuBarApp.main()
}
