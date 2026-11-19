import AppKit
import SceneKit
import Orbits
import SwiftUI
import simd

/// 3D "sky dome" in the style of the Starlink app: the terminal floats above a compass rose, the
/// obstruction map is projected as dots onto a hemisphere, and an outline shows the ideal orientation.
///
/// World frame: +x = east, +y = up, +z = south (so −z is north). Hemisphere radius = 1.
@MainActor
final class SkyScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// The orbit's centre of rotation: halfway up from the ground to the top of the (unit) dome.
    var cameraTarget: SIMD3<Float> { Self.orbitCenter }
    /// The orbit's centre of rotation, 0.19 above the ground. Together with `lensShiftY`, it keeps the dome
    /// and compass rose centred in the space above the latency graph (equal margins to the window top and
    /// the graph) both looking straight down and at the 30° auto-orbit, with only gentle drift in between.
    nonisolated static let orbitCenter = SIMD3<Float>(0, groundY + 0.19, 0)
    /// The initial view's camera distance from `orbitCenter` and horizontal field of view (both views').
    nonisolated static let cameraDistance: Float = 4.4
    nonisolated static let cameraFieldOfView: CGFloat = 36.85
    /// A constant shift-lens offset (normalised device units, 2 = full height) that moves the pivot's image
    /// from the window's centre up to the centre of the space above the bottom HUD: 70 of 435 pt.
    nonisolated static let lensShiftY: Float = 70.0 / 435.0

    // Layout
    nonisolated static let groundY: Float = -0.12
    nonisolated static let terminalCenter = SIMD3<Float>(0, 0.24, 0)
    nonisolated static let terminalWidth: Float = 0.30
    static let terminalLength: Float = terminalWidth * 1.618
    nonisolated static let terminalThickness: Float = terminalWidth * 0.10
    static let outlineScale: Float = 1.22
    static let alignedToleranceDeg = 5.0
    /// Beyond this error on either axis the view switches to "alignment mode": dimmed dots, and the camera
    /// parks facing the ideal orientation instead of orbiting. (Leaves it 0.5° lower, so jitter can't flap it.)
    static let alignmentModeDeg = 10.0
    static let alignmentModeHysteresisDeg = 0.5
    static let alignmentModeDotOpacity: CGFloat = 0.33
    /// The phased array can't see below this elevation above its own face plane: dots there are hidden.
    nonisolated static let fieldOfViewMinElevationDeg: Float = 22.5

    // Palette
    static let background = NSColor(white: 0.045, alpha: 1)
    static let clearDot = SIMD4<Float>(0.93, 0.93, 0.93, 1)
    static let obstructedDot = SIMD4<Float>(0.93, 0.17, 0.13, 1)
    static let unmappedDot = SIMD4<Float>(0.24, 0.24, 0.24, 1)

    private let terminal = SCNNode()
    private let outline = SCNNode()
    private let outlineMaterial = SCNMaterial()
    private let dome = SCNNode()
    /// Long radial tick on the compass rose at the dish's azimuth, with an "az° ∡el°" label at its end.
    private let azimuthTick = SCNNode()
    private let azimuthLabel = SCNNode()
    private var azimuthLabelText = ""
    static let compassRadius: Float = 1.0
    static let shortTickLength: Float = 0.04
    static let azimuthTickLength: Float = shortTickLength * 4
    private var lastDomeKey: [Float] = []
    private var hasAimedCamera = false
    static let initialSweepOffsetDeg: Float = 45

    /// Re-aims the camera at the next status update (called as the popup opens, before the first frame).
    func resetCameraAim() { hasAimedCamera = false }

    /// Camera motion state. Lives here, not in the view, so it survives the popup closing: the SCNView is
    /// torn down while hidden, and a quick reopen carries on with the same angle and angular velocity.
    private(set) lazy var autoOrbit = AutoOrbit(target: cameraTarget, earth: earth)
    /// Beams to the satellites in the dish's field of view (animated from the render loop).
    let beams = SatelliteBeams()
    /// The zoomed-out globe, and the zoom between it and this dish view (double-click).
    let earth: EarthView
    /// Everything in the dish view hangs off this, so the zoom can shrink it as one.
    private var dishRoot: SCNNode { earth.dishRoot }
    /// When the sky view was last torn down (popup hidden); nil before it has ever been shown.
    var hiddenAt: Date?
    /// Hidden for longer than this → the next open starts over from the initial view.
    static let resetAfterHiddenSeconds: TimeInterval = 30
    private var hasStatus = false
    private var lastAligned: Bool?
    /// Set while far off alignment: the compass azimuth of the ideal orientation's face normal, where the
    /// camera should park. nil = normal mode (auto-orbit).
    private(set) var alignmentFocusAzimuthDeg: Float?
    private var domeOpacity: CGFloat { alignmentFocusAzimuthDeg == nil ? 1 : Self.alignmentModeDotOpacity }

    init() {
        earth = EarthView(beams: beams)
        scene.background.contents = Self.background
        scene.rootNode.addChildNode(earth.earthRoot)
        scene.rootNode.addChildNode(earth.starRoot)
        scene.rootNode.addChildNode(earth.dishRoot)
        buildGround()
        buildCompass()
        buildTerminal()
        buildOutline()
        buildAzimuthTick()
        dome.renderingOrder = 10          // after the opaque terminal, so faded dots blend over it
        dishRoot.addChildNode(dome)
        dishRoot.addChildNode(beams.root)
        buildLightsAndCamera()
    }

    /// True when the dish is within `alignedToleranceDeg` of optimal on both azimuth and elevation.
    static func isAligned(_ a: DishStatus.Alignment) -> Bool? {
        guard let dAz = a.azimuthCorrectionDeg, let dEl = a.elevationCorrectionDeg else { return nil }
        return abs(dAz) <= alignedToleranceDeg && abs(dEl) <= alignedToleranceDeg
    }

    /// True when more than `alignmentModeDeg` off on azimuth or elevation (`wasOn` applies the hysteresis).
    static func needsAlignmentMode(_ a: DishStatus.Alignment, wasOn: Bool = false) -> Bool {
        guard let dAz = a.azimuthCorrectionDeg, let dEl = a.elevationCorrectionDeg else { return false }
        let limit = alignmentModeDeg - (wasOn ? alignmentModeHysteresisDeg : 0)
        return abs(dAz) > limit || abs(dEl) > limit
    }

    // MARK: - Updates

    func update(status: DishStatus?, map: ObstructionMap?, animated: Bool = true) {
        // The first update after there was nothing to show snaps into place; only later changes animate.
        // (Animating the first one would swing the terminal in from a default pose.)
        let snap = !animated || !hasStatus
        hasStatus = status != nil
        SCNTransaction.begin()
        SCNTransaction.animationDuration = snap ? 0 : 0.6
        defer { SCNTransaction.commit() }

        guard let status else {
            alignmentFocusAzimuthDeg = nil
            beams.setBoresight(nil)
            if !terminal.isHidden { terminal.isHidden = true }
            if !azimuthTick.isHidden { azimuthTick.isHidden = true; azimuthLabel.isHidden = true }
            if !outline.isHidden { outline.isHidden = true }
            if dome.geometry != nil { dome.geometry = nil }
            lastDomeKey = []
            return
        }
        let a = status.alignment
        let axes = Self.dishAxes(status)
        let ideal = Self.idealAxes(axes, alignment: a)
        beams.setBoresight(axes.columns.2)
        let wasFocused = alignmentFocusAzimuthDeg != nil
        alignmentFocusAzimuthDeg = Self.needsAlignmentMode(a, wasOn: wasFocused)
            ? ideal.flatMap(Self.boresightAzimuthDeg) ?? a.desiredAzimuthDeg : nil
        // The initial view (below), which a zoom back in from the Earth view also lands on.
        earth.setHomeAzimuth(alignmentFocusAzimuthDeg ?? (Self.boresightAzimuthDeg(axes) ?? a.azimuthDeg) - Self.initialSweepOffsetDeg)
        if !hasAimedCamera {
            hasAimedCamera = true
            if let focus = alignmentFocusAzimuthDeg {
                aimCamera(azimuthDeg: focus)                     // already where alignment mode parks it
            } else {
                // 45° counter-clockwise of the antenna's sagittal plane: the clockwise orbit then sweeps
                // through the plane (face-on) during its first seconds.
                aimCamera(azimuthDeg: (Self.boresightAzimuthDeg(axes) ?? a.azimuthDeg) - Self.initialSweepOffsetDeg)
            }
        }
        if wasFocused != (alignmentFocusAzimuthDeg != nil), dome.geometry != nil {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = snap ? 0 : 0.8
            dome.opacity = domeOpacity
            SCNTransaction.commit()
        }
        // Only touch the scene graph for visible changes: every mutation makes SceneKit redraw (and animate).
        if terminal.isHidden { terminal.isHidden = false }
        Self.setOrientation(terminal, Self.orientation(axes))
        updateAzimuthTick(a)

        if let ideal {
            if outline.isHidden { outline.isHidden = false }
            Self.setOrientation(outline, Self.orientation(ideal))
            let aligned = Self.isAligned(a) ?? false
            if aligned != lastAligned {
                lastAligned = aligned
                outlineMaterial.emission.contents = aligned ? NSColor.white : NSColor(red: 1, green: 0.12, blue: 0.08, alpha: 1)
                outlineMaterial.emission.intensity = aligned ? 2.2 : 3.4   // red has less luminance; push it harder to glow
            }
        } else if !outline.isHidden {
            outline.isHidden = true
        }

        // The dome only needs rebuilding when the map or the dish attitude (which maps it onto the sky) changes.
        // Without a map every dot would be grey and then recolour, so the dome waits for the map and fades in.
        guard let map else { return }
        let key = Self.domeKey(axes, map)
        if key != lastDomeKey {
            let appearing = dome.geometry == nil
            lastDomeKey = key
            dome.geometry = Self.domeGeometry(map: map, dishAxes: axes)
            if appearing && animated {
                dome.opacity = 0
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.8
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
                dome.opacity = domeOpacity
                SCNTransaction.commit()
            } else if appearing {
                dome.opacity = domeOpacity
            }
        }
    }

    /// Initial view, at the auto-orbit elevation so the orbit starts with no elevation change: 45° counter-
    /// clockwise of the direction the antenna faces, or (in alignment mode) facing the ideal orientation.
    func aimCamera(azimuthDeg: Float) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        orbit(azimuthDeg: azimuthDeg, elevationDeg: AutoOrbit.elevationDeg)
        SCNTransaction.commit()
    }

    /// Compass azimuth of the antenna face's normal, projected onto the ground (nil if it points straight up).
    static func boresightAzimuthDeg(_ axes: simd_float3x3) -> Float? {
        let n = axes.columns.2
        guard n.x * n.x + n.z * n.z > 1e-6 else { return nil }
        return atan2(n.x, -n.z) * 180 / .pi
    }

    /// Sets a node's orientation only if it differs by more than ~0.2°, ignoring sensor jitter.
    private static func setOrientation(_ node: SCNNode, _ q: simd_quatf) {
        let d = abs(simd_dot(node.simdOrientation.vector, q.vector))
        if d < cos(0.1 * Float.pi / 180) { node.simdOrientation = q }
    }

    /// Places the camera on an orbit around the scene (used for snapshots; the user orbits by dragging).
    /// Re-applies the camera's projection with `lensShiftY`, tracking its current field of view (scroll/
    /// pinch zoom changes it) and the viewport's aspect. Called before every rendered frame.
    nonisolated static func applyLensShift(to node: SCNNode, viewport: CGSize) {
        guard let cam = node.camera, viewport.width > 0, viewport.height > 0 else { return }
        // A scratch camera with the same lens computes the unshifted projection (the live camera's own
        // projection is overridden by this, so it can't be asked).
        let lens = SCNCamera()
        lens.projectionDirection = cam.projectionDirection
        lens.fieldOfView = cam.fieldOfView
        lens.zNear = cam.zNear
        lens.zFar = cam.zFar
        let p = simd_float4x4(lens.projectionTransform(withViewportSize: viewport))
        var shift = matrix_identity_float4x4
        shift.columns.3.y = lensShiftY                       // clip y += shift · w  →  NDC y += shift
        cam.projectionTransform = SCNMatrix4(shift * p)
    }

    func orbit(azimuthDeg: Float, elevationDeg: Float, distance: Float = SkyScene.cameraDistance) {
        let d = Self.direction(azDeg: azimuthDeg, elDeg: elevationDeg)
        cameraNode.simdPosition = cameraTarget + d * distance
        cameraNode.simdLook(at: cameraTarget, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    // MARK: - Geometry helpers

    static func direction(azDeg: Float, elDeg: Float) -> SIMD3<Float> {
        let a = azDeg * .pi / 180, e = elDeg * .pi / 180
        return SIMD3(cos(e) * sin(a), sin(e), -cos(e) * cos(a))
    }

    static func fromNED(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.y, -v.z, -v.x) }

    /// Dish body axes in world coordinates: x across the face, y up the face (long side), z = boresight.
    /// Uses the full attitude quaternion when the dish reports it (it maps dish → NED), else azimuth/elevation.
    static func dishAxes(_ s: DishStatus) -> simd_float3x3 {
        if let q = s.nedToDishQuaternion, abs(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z - 1) < 0.05 {
            let r = simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w).normalized
            return simd_float3x3(columns: (fromNED(r.act(SIMD3(1, 0, 0))),
                                           fromNED(r.act(SIMD3(0, 1, 0))),
                                           fromNED(r.act(SIMD3(0, 0, 1)))))
        }
        return axes(azDeg: s.alignment.azimuthDeg, elDeg: s.alignment.elevationDeg)
    }

    static func axes(azDeg: Float, elDeg: Float) -> simd_float3x3 {
        let z = direction(azDeg: azDeg, elDeg: elDeg)
        let y = direction(azDeg: azDeg, elDeg: elDeg + 90)
        return simd_float3x3(columns: (simd_normalize(simd_cross(y, z)), y, z))
    }

    /// The current attitude re-aimed to the desired azimuth/elevation: turned about vertical, then tilted.
    /// Keeps the terminal's roll, so the outline and terminal coincide exactly once aligned.
    static func idealAxes(_ m: simd_float3x3, alignment a: DishStatus.Alignment) -> simd_float3x3? {
        guard let dAz = a.azimuthCorrectionDeg, let dEl = a.elevationCorrectionDeg else { return nil }
        let up = SIMD3<Float>(0, 1, 0)
        let turn = simd_quatf(angle: -Float(dAz) * .pi / 180, axis: up)
        var q = turn
        let b = turn.act(m.columns.2)
        let h = simd_cross(b, up)
        if simd_length(h) > 1e-4 {
            q = simd_quatf(angle: Float(dEl) * .pi / 180, axis: simd_normalize(h)) * turn
        }
        return simd_float3x3(columns: (q.act(m.columns.0), q.act(m.columns.1), q.act(m.columns.2)))
    }

    /// Node orientation for a box whose width is local x, thickness local y and length local z.
    static func orientation(_ m: simd_float3x3) -> simd_quatf {
        simd_quatf(simd_float3x3(columns: (m.columns.0, m.columns.2, -m.columns.1)))
    }

    private static func domeKey(_ axes: simd_float3x3, _ map: ObstructionMap?) -> [Float] {
        // Attitude rounded to ~0.5°, plus a cheap fingerprint of the map contents.
        let att = [axes.columns.0, axes.columns.1, axes.columns.2].flatMap { [$0.x, $0.y, $0.z] }.map { ($0 * 120).rounded() }
        guard let map else { return att }
        var sum: Float = 0, weighted: Float = 0
        for (i, v) in map.snr.enumerated() { sum += v; weighted += v * Float(i % 97) }
        return att + [Float(map.rows), Float(map.referenceFrame), map.maxThetaDeg, sum, weighted]
    }

    /// Looks up the obstruction map value for a world-space direction. nil = no data.
    ///
    /// The map is a polar image: the centre pixel is the map's pole (the boresight in FRAME_UT, zenith in
    /// FRAME_EARTH) and the rim is `maxThetaDeg` away from it. Columns run along the frame's +x axis,
    /// rows down the image run along −y. (Checked on a live FRAME_UT map: with this convention every
    /// recorded satellite pass lands above ~22° elevation, matching Starlink's minimum elevation; the
    /// transposed/flipped alternatives put data down near the horizon.)
    static func sample(_ map: ObstructionMap, worldDir w: SIMD3<Float>, dishAxes m: simd_float3x3) -> Float? {
        let local: SIMD3<Float>
        if map.referenceFrame == 1 {
            local = SIMD3(w.x, -w.z, w.y)               // x = east, y = north, z = up
        } else {
            local = m.transpose * w                      // dish frame
        }
        let theta = acos(max(-1, min(1, local.z))) * 180 / .pi
        guard theta <= map.maxThetaDeg else { return nil }
        let rho = simd_length(SIMD2(local.x, local.y))
        let half = Float(min(map.rows, map.cols)) / 2
        let r = theta / map.maxThetaDeg * half
        let (cx, cy) = (rho > 1e-6 ? local.x / rho : 0, rho > 1e-6 ? local.y / rho : 0)
        let col = Int((Float(map.cols) / 2 + r * cx).rounded(.down))
        let row = Int((Float(map.rows) / 2 - r * cy).rounded(.down))
        guard (0..<map.rows).contains(row), (0..<map.cols).contains(col) else { return nil }
        let v = map.snr[row * map.cols + col]
        return v >= 0 ? v : nil
    }

    /// Dots on rings of constant elevation, each a small disc tangent to the hemisphere.
    static func domeGeometry(map: ObstructionMap?, dishAxes m: simd_float3x3) -> SCNGeometry {
        var verts: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        var indices: [UInt32] = []
        let step: Float = 2.0                            // degrees between rings and between dots
        let stepRad = step * .pi / 180
        let sides = 8
        let usable = map.map { $0.rows > 0 && $0.cols > 0 && $0.snr.count == $0.rows * $0.cols } ?? false
        let boresight = m.columns.2
        let minFacing = sin(fieldOfViewMinElevationDeg * .pi / 180)

        var theta: Float = 0
        while theta <= 90.01 {
            let el = 90 - theta
            let ringCount = theta < 0.01 ? 1 : max(6, Int((2 * .pi * sin(theta * .pi / 180) / stepRad).rounded()))
            let offset: Float = (Float(Int(theta / step)) .truncatingRemainder(dividingBy: 2)) * 0.5
            for k in 0..<ringCount {
                let az = (Float(k) + offset) / Float(ringCount) * 360
                let n = direction(azDeg: az, elDeg: el)
                if simd_dot(n, boresight) < minFacing { continue }   // outside the terminal's field of view
                let value = usable ? sample(map!, worldDir: n, dishAxes: m) : nil
                let color: SIMD4<Float>
                var radius = stepRad * 0.34
                switch value {
                case nil: color = unmappedDot; radius *= 0.72
                case let v? where v < 1: color = obstructedDot; radius *= 1.12
                default: color = clearDot
                }
                // Tangent basis for the disc.
                let t1 = simd_length(simd_cross(n, SIMD3(0, 1, 0))) > 1e-3
                    ? simd_normalize(simd_cross(n, SIMD3(0, 1, 0))) : SIMD3<Float>(1, 0, 0)
                let t2 = simd_cross(n, t1)
                let centre = n + SIMD3(0, groundY, 0)
                let base = UInt32(verts.count)
                verts.append(SCNVector3(centre))
                colors.append(color)
                for s in 0..<sides {
                    let ang = Float(s) / Float(sides) * 2 * .pi
                    verts.append(SCNVector3(centre + (t1 * cos(ang) + t2 * sin(ang)) * radius))
                    colors.append(color)
                    indices += [base, base + 1 + UInt32(s), base + 1 + UInt32((s + 1) % sides)]
                }
            }
            theta += step
        }

        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                            usesFloatComponents: true, componentsPerVector: 4,
                                            bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), colorSource],
                              elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = NSColor.white
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        // Like the Starlink app, fade the near (camera-facing) side of the dome so the terminal and the
        // far sky stay readable from any orbit angle.
        mat.shaderModifiers = [
            .geometry: """
            #pragma varyings
            float facing;
            #pragma body
            // In the dish scene's own coordinates (the node sits at its root), which the zoom scales.
            float3 wp = _geometry.position.xyz;
            float3 cam = (scn_node.inverseModelTransform * float4(scn_frame.inverseViewTransform[3].xyz, 1.0)).xyz;
            float3 centre = float3(0.0, \(groundY), 0.0);
            float2 radial = (wp - centre).xz;              // horizontal: near half vs far half
            float2 toCam = normalize((cam - centre).xz + float2(1e-5, 0.0));
            out.facing = dot(radial, toCam);
            """,
            .fragment: """
            #pragma transparent
            #pragma body
            _output.color *= 1.0 - 0.85 * smoothstep(0.05, 0.65, in.facing);
            """,
        ]
        geo.materials = [mat]
        return geo
    }

    // MARK: - Scene construction

    private static let groundMask = 1 << 1
    private static let objectMask = 1 << 0

    private func buildGround() {
        let plane = SCNPlane(width: 12, height: 12)
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor(white: 0.55, alpha: 1)
        m.emission.contents = Self.background            // unlit ground blends into the background
        // Beyond the light pool the ground is exactly the background colour; fading it out there changes
        // nothing in the dish view, but as the zoom shrinks the scene the globe shows round it, not a square.
        m.transparent.contents = Self.groundMask(fadeFrom: 2.0 / 6, to: 4.5 / 6)
        m.transparencyMode = .rgbZero
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.simdPosition = SIMD3(0, Self.groundY, 0)
        node.categoryBitMask = Self.groundMask
        dishRoot.addChildNode(node)
    }

    /// Transparency mask (`.rgbZero`: black = opaque): opaque inside `fadeFrom`, clear beyond `to` (as
    /// fractions of the half-width), smoothly between.
    private static func groundMask(fadeFrom r0: Float, to r1: Float) -> CGImage? {
        let n = 256
        var px = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let u = (Float(x) + 0.5) / Float(n) * 2 - 1, v = (Float(y) + 0.5) / Float(n) * 2 - 1
                let t = max(0, min(1, ((u * u + v * v).squareRoot() - r0) / (r1 - r0)))
                px[y * n + x] = UInt8((255 * t * t * (3 - 2 * t)).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func buildCompass() {
        let tickMat = SCNMaterial()
        tickMat.lightingModel = .constant
        tickMat.diffuse.contents = NSColor(white: 0.85, alpha: 1)
        let ticks = SCNNode()
        let radius: Float = 1.0
        for i in 0..<120 {
            let az = Float(i) * 3
            let fromCardinal = abs(az.truncatingRemainder(dividingBy: 90) - 45)   // 45 = midway, 0/90 = on a cardinal
            if fromCardinal > 45 - 10 { continue }                               // leave a gap for the letter
            let box = SCNBox(width: 0.007, height: 0.002, length: 0.04, chamferRadius: 0)
            box.materials = [tickMat]
            let tick = SCNNode(geometry: box)
            tick.simdPosition = Self.direction(azDeg: az, elDeg: 0) * radius + SIMD3(0, Self.groundY + 0.002, 0)
            tick.simdEulerAngles.y = -az * .pi / 180
            ticks.addChildNode(tick)
        }
        dishRoot.addChildNode(ticks.flattenedClone())

        for (label, az) in [("N", Float(0)), ("E", 90), ("S", 180), ("W", 270)] {
            let text = SCNText(string: label, extrusionDepth: 0)
            text.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
            text.flatness = 0.05
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColor(white: 0.9, alpha: 1)
            m.isDoubleSided = true
            text.materials = [m]
            let node = SCNNode(geometry: text)
            let (lo, hi) = text.boundingBox
            node.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
            node.scale = SCNVector3(0.014, 0.014, 0.014)
            node.simdPosition = Self.direction(azDeg: az, elDeg: 0) * radius + SIMD3(0, Self.groundY + 0.06, 0)
            node.constraints = [SCNBillboardConstraint()]
            dishRoot.addChildNode(node)
        }
    }

    private func buildTerminal() {
        let box = SCNBox(width: CGFloat(Self.terminalWidth), height: CGFloat(Self.terminalThickness),
                         length: CGFloat(Self.terminalLength), chamferRadius: CGFloat(Self.terminalThickness) * 0.3)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: 0.85, alpha: 1)
        m.roughness.contents = 0.55
        m.metalness.contents = 0.0
        box.materials = [m]
        terminal.geometry = box
        terminal.simdPosition = Self.terminalCenter
        terminal.categoryBitMask = Self.objectMask
        terminal.isHidden = true
        dishRoot.addChildNode(terminal)
    }

    private func buildAzimuthTick() {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.95, alpha: 1)
        // A pivot node turned to the azimuth; the tick and label sit along its local −z (north at az 0).
        let r0 = Self.compassRadius - Self.shortTickLength / 2           // starts where the short ticks start
        let box = SCNBox(width: 0.009, height: 0.002, length: CGFloat(Self.azimuthTickLength), chamferRadius: 0)
        box.materials = [m]
        let tick = SCNNode(geometry: box)
        tick.simdPosition = SIMD3(0, Self.groundY + 0.003, -(r0 + Self.azimuthTickLength / 2))
        azimuthTick.addChildNode(tick)
        azimuthTick.isHidden = true
        dishRoot.addChildNode(azimuthTick)

        azimuthLabel.scale = SCNVector3(0.0085, 0.0085, 0.0085)
        azimuthLabel.constraints = [SCNBillboardConstraint()]
        azimuthLabel.isHidden = true
        dishRoot.addChildNode(azimuthLabel)
    }

    private func updateAzimuthTick(_ a: DishStatus.Alignment) {
        let az = (a.azimuthDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if azimuthTick.isHidden { azimuthTick.isHidden = false; azimuthLabel.isHidden = false }
        let yaw = -az * .pi / 180
        if abs(azimuthTick.simdEulerAngles.y - yaw) > 0.002 { azimuthTick.simdEulerAngles.y = yaw }
        // Label centred just beyond the tick's outer end, so it reads clearly from any orbit angle.
        let end = Self.compassRadius - Self.shortTickLength / 2 + Self.azimuthTickLength
        let pos = Self.direction(azDeg: az, elDeg: 0) * (end + 0.2) + SIMD3(0, Self.groundY + 0.04, 0)
        if simd_distance(azimuthLabel.simdPosition, pos) > 0.002 { azimuthLabel.simdPosition = pos }

        let text = "\(Int(az.rounded()) % 360)° ∡\(Int(a.elevationDeg.rounded()))°"
        guard text != azimuthLabelText else { return }
        azimuthLabelText = text
        let t = SCNText(string: text, extrusionDepth: 0)
        t.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        t.flatness = 0.05
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.95, alpha: 1)
        m.isDoubleSided = true
        t.materials = [m]
        azimuthLabel.geometry = t
        let (lo, hi) = t.boundingBox
        azimuthLabel.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
    }

    private func buildOutline() {
        outlineMaterial.lightingModel = .constant
        outlineMaterial.diffuse.contents = NSColor.black
        outlineMaterial.emission.contents = NSColor.white
        outlineMaterial.emission.intensity = 2.2           // > bloom threshold, so it glows
        let w = Self.terminalWidth * Self.outlineScale, l = Self.terminalLength * Self.outlineScale
        let bar: Float = 0.011
        let sides: [(SIMD3<Float>, SIMD3<Float>)] = [      // (size, position) in terminal-local coordinates
            (SIMD3(w + bar, bar, bar), SIMD3(0, 0, l / 2)), (SIMD3(w + bar, bar, bar), SIMD3(0, 0, -l / 2)),
            (SIMD3(bar, bar, l + bar), SIMD3(w / 2, 0, 0)), (SIMD3(bar, bar, l + bar), SIMD3(-w / 2, 0, 0)),
        ]
        for (size, pos) in sides {
            let b = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
            b.materials = [outlineMaterial]
            let n = SCNNode(geometry: b)
            n.simdPosition = pos
            outline.addChildNode(n)
        }
        outline.simdPosition = Self.terminalCenter
        outline.isHidden = true
        dishRoot.addChildNode(outline)
    }

    private func buildLightsAndCamera() {
        // Point light at the origin, beneath the terminal: lights the ground in a soft pool.
        let glow = SCNLight()
        glow.type = .omni
        glow.color = NSColor(white: 1, alpha: 1)
        glow.intensity = 2600
        glow.attenuationStartDistance = 0
        glow.attenuationEndDistance = 1.7
        glow.attenuationFalloffExponent = 1.3
        glow.categoryBitMask = Self.groundMask | Self.objectMask
        let glowNode = SCNNode()
        glowNode.light = glow
        earth.glowLight = glow
        glowNode.simdPosition = .zero
        dishRoot.addChildNode(glowNode)

        // Soft key and fill light for the terminal only, so its faces read as a solid.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 850
        key.categoryBitMask = Self.objectMask
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdLook(at: SIMD3(0.4, -1, 0.3), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        dishRoot.addChildNode(keyNode)

        // (Not an ambient light: SceneKit applies ambient lights to every node regardless of category mask,
        // which would wash out the ground.)
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 300
        fill.categoryBitMask = Self.objectMask
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdLook(at: SIMD3(-0.5, 0.3, -0.6), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        dishRoot.addChildNode(fillNode)

        let cam = SCNCamera()
        // Horizontal FOV: the scene keeps its scale whatever the popup's height (the window is a fixed width).
        cam.projectionDirection = .horizontal
        cam.fieldOfView = Self.cameraFieldOfView
        cam.zNear = 0.05
        cam.zFar = 150                                   // the globe starts out huge as the zoom-out begins
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        cam.bloomThreshold = 1.0
        cam.bloomIntensity = 1.6
        cam.bloomBlurRadius = 9
        cam.bloomIterationCount = 2
        cam.vignettingIntensity = 0.4
        cam.vignettingPower = 0.6
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        orbit(azimuthDeg: 225, elevationDeg: AutoOrbit.elevationDeg)   // placeholder until the first status
    }
}

// MARK: - SwiftUI wrapper

/// Interactive view of `SkyScene`: drag to orbit, scroll/pinch to zoom.
struct SkySceneView: NSViewRepresentable {
    let sky: SkyScene
    let status: DishStatus?
    let map: ObstructionMap?
    let constellation: Constellation?
    let observer: Observer
    var onRefresh: () -> Void = {}

    func makeCoordinator() -> SkyScene { sky }

    func makeNSView(context: Context) -> OrbitingSCNView {
        let v = OrbitingSCNView(frame: .zero, target: sky.cameraTarget, orbit: sky.autoOrbit, earth: sky.earth)
        v.scene = sky.scene
        v.pointOfView = sky.cameraNode
        v.backgroundColor = SkyScene.background
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = false        // draw only when something changes (camera drag, updates)
        v.isPlaying = false
        v.allowsCameraControl = true
        let c = v.defaultCameraController
        c.interactionMode = .orbitTurntable
        c.target = SCNVector3(sky.cameraTarget)
        // SceneKit's built-in inertia stops abruptly at a fixed (fairly high) speed; AutoOrbit coasts instead.
        c.inertiaEnabled = false
        c.maximumVerticalAngle = AutoOrbit.maxElevationDeg
        v.cameraControlConfiguration.allowsTranslation = false
        v.cameraControlConfiguration.rotationSensitivity = 0.8
        // At launch, or after being hidden a while, start over from the initial view; after a brief close,
        // carry on exactly where the camera was (the motion is frozen while hidden, not simulated).
        v.onRefresh = onRefresh
        let fresh = sky.hiddenAt.map { Date().timeIntervalSince($0) > SkyScene.resetAfterHiddenSeconds } ?? true
        if fresh { sky.resetCameraAim(); sky.earth.set(0) }   // the initial view is the dish view
        v.updateElevationLimit()
        sky.update(status: status, map: map)
        applySatellites(v)
        v.focusAzimuthDeg = sky.alignmentFocusAzimuthDeg
        if fresh { v.restartAutoOrbit() } else { v.resumeAutoOrbit() }
        return v
    }

    func updateNSView(_ v: OrbitingSCNView, context: Context) {
        v.onRefresh = onRefresh
        sky.update(status: status, map: map)
        applySatellites(v)
        v.focusAzimuthDeg = sky.alignmentFocusAzimuthDeg
    }

    private func applySatellites(_ v: OrbitingSCNView) {
        sky.beams.setConstellation(constellation)
        sky.beams.setObserver(observer)
        v.beamsActive = sky.beams.isActive           // the beams move, so keep drawing while they're shown
    }

    static func dismantleNSView(_ v: OrbitingSCNView, coordinator sky: SkyScene) {
        sky.hiddenAt = Date()
        v.suspendAutoOrbit()
        v.isPlaying = false
        v.scene = nil
    }
}

/// SCNView that slowly orbits the camera around the vertical axis when the user isn't interacting:
/// on open, and once the camera has been still for 1 s after a drag/scroll. Releasing a drag lets the
/// camera coast (see `AutoOrbit`) until it's practically stopped. In alignment mode (`focusAzimuthDeg`
/// set) it glides to face the ideal orientation and parks there instead of orbiting. Renders
/// continuously only while moving.
final class OrbitingSCNView: SCNView {
    /// Where to park the camera instead of orbiting (nil = orbit). Takes effect immediately if the camera
    /// is running on its own; after a gesture it applies once the camera comes to rest.
    var focusAzimuthDeg: Float? {
        didSet {
            // Ignore attitude jitter: re-aim only for real changes (or entering/leaving alignment mode).
            switch (focusAzimuthDeg, appliedFocusAzimuthDeg) {
            case (nil, nil): return
            case let (new?, old?) where abs(remainder(new - old, 360)) < 0.5: return
            default: appliedFocusAzimuthDeg = focusAzimuthDeg
            }
            switch orbit.currentMode {
            case .orbit, .focus: startAutoOrbit()
            case .idle where stillTimer == nil && !dragging && window != nil: startAutoOrbit()  // parked
            default: break                                    // user is in control; picked up when still
            }
        }
    }
    private let orbit: AutoOrbit
    private var appliedFocusAzimuthDeg: Float?
    private let earth: EarthView
    /// Satellite beams are showing (they animate).
    var beamsActive = false {
        didSet { if beamsActive != oldValue { refreshRendering() } }
    }
    /// Keep drawing even while the camera is still: beams animating, or the Earth view (zooming or shown).
    var keepsRendering: Bool { beamsActive || earth.isAnimatingOrOut }
    private var zoomTimer: Timer?

    private func refreshRendering() {
        guard window != nil else { return }
        if keepsRendering { rendersContinuously = true }
        else if case .idle = orbit.currentMode { rendersContinuously = false }
    }

    /// Dragging can go below the horizon, to the south pole, only in the Earth view (the dish view stays above
    /// ground). Kept open while zooming in, which brings the camera back up itself.
    func updateElevationLimit() {
        defaultCameraController.minimumVerticalAngle = AutoOrbit.minElevationDeg(earthView: earth.isAnimatingOrOut)
    }

    /// Double-click: zoom out to the Earth view, or back in.
    private func toggleZoom() {
        earth.toggle()
        updateElevationLimit()
        rendersContinuously = true
        // Once the zoom has finished, drop back to drawing on demand if nothing else is moving.
        zoomTimer?.invalidate()
        let t = Timer(timeInterval: EarthView.duration + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoomTimer = nil; self?.updateElevationLimit(); self?.refreshRendering() }
        }
        RunLoop.main.add(t, forMode: .common)
        zoomTimer = t
    }
    var onRefresh: () -> Void = {}
    private let target: SIMD3<Float>
    private var eventMonitor: Any?
    private var dragging = false
    /// The press has become a drag (or caught a coasting camera): plain clicks leave the motion alone, so
    /// a double-click zooms without pausing the orbit.
    private var dragMoved = false
    private var dragSamples: [(time: TimeInterval, az: Float, el: Float)] = []

    // Stillness detection after a gesture.
    private var stillTimer: Timer?
    private var lastPose: (position: SIMD3<Float>, fov: CGFloat)?
    private var stillSince: Date?
    static let stillDelay: TimeInterval = 1
    static let stillCheckInterval: TimeInterval = 0.1
    static let stillAngularSpeed: Float = 0.0025 * .pi / 180   // rad/s: just above the coast cutoff

    init(frame: CGRect, target: SIMD3<Float>, orbit: AutoOrbit, earth: EarthView) {
        self.orbit = orbit
        self.earth = earth
        self.target = target
        super.init(frame: frame, options: nil)
        delegate = orbit
        orbit.onParked = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Parked in alignment mode: stop drawing until something changes.
                    guard let self, case .idle = self.orbit.currentMode else { return }
                    self.rendersContinuously = self.keepsRendering
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func startAutoOrbit() {
        cancelStillWait()
        appliedFocusAzimuthDeg = focusAzimuthDeg
        if let az = focusAzimuthDeg {
            orbit.setMode(.focus(azDeg: az, elDeg: AutoOrbit.elevationDeg))
        } else {
            orbit.setMode(.orbit)
        }
        rendersContinuously = true
    }

    /// Starts over: forgets any previous motion, then orbits (or glides to the alignment view) from rest.
    func restartAutoOrbit() {
        orbit.setMode(.idle)
        startAutoOrbit()
    }

    /// Continues whatever the camera was doing when the popup closed, from the same angle and velocity.
    func resumeAutoOrbit() {
        appliedFocusAzimuthDeg = focusAzimuthDeg
        switch orbit.currentMode {
        case .orbit where focusAzimuthDeg == nil, .focus where focusAzimuthDeg != nil:
            rendersContinuously = true
        case .orbit, .focus:
            startAutoOrbit()                 // alignment mode changed while hidden
        case .coast:
            rendersContinuously = true       // finish the coast, then orbit once still
            waitForStillThenOrbit()
        case .idle:
            rendersContinuously = keepsRendering
            waitForStillThenOrbit()          // was parked, held or settling: resume after it's still
        }
    }

    /// Freezes the motion as-is (popup hidden); `resumeAutoOrbit` picks it up again.
    func suspendAutoOrbit() {
        cancelStillWait()
        orbit.suspend()
        rendersContinuously = false
    }

    func stopAutoOrbit() {
        cancelStillWait()
        pauseOrbit()
    }

    private func pauseOrbit() {
        orbit.setMode(.idle)
        rendersContinuously = keepsRendering
    }

    /// Polls the camera (cheaply, 10×/s, only during this wait) and starts the orbit once it has
    /// barely moved for `stillDelay`.
    private func waitForStillThenOrbit() {
        guard stillTimer == nil else { return }
        lastPose = nil
        stillSince = nil
        let t = Timer(timeInterval: Self.stillCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStill() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        stillTimer = t
    }

    private func cancelStillWait() {
        stillTimer?.invalidate()
        stillTimer = nil
    }

    private func checkStill() {
        guard let cam = pointOfView else { return }
        let pos = cam.presentation.simdWorldPosition
        let fov = cam.camera?.fieldOfView ?? 0
        let now = Date()
        defer { lastPose = (pos, fov) }
        guard let last = lastPose, let since = stillSince else { stillSince = now; return }
        let radius = max(simd_length(pos - target), 1e-3)
        let angularSpeed = simd_length(pos - last.position) / radius / Float(Self.stillCheckInterval)
        if angularSpeed > Self.stillAngularSpeed || abs(fov - last.fov) > 0.01 {
            stillSince = now
        } else if now.timeIntervalSince(since) >= Self.stillDelay {
            startAutoOrbit()
        }
    }

    private func cameraAngles() -> (az: Float, el: Float)? {
        guard let cam = pointOfView else { return nil }
        let rel = cam.simdPosition - target
        let d = simd_length(rel)
        guard d > 1e-3 else { return nil }
        return (atan2(rel.x, -rel.z), asin(max(-1, min(1, rel.y / d))))
    }

    /// Angular velocity (rad/s) over the last ~60 ms of the drag; zero if the pointer had come to rest.
    private func releaseVelocity(at time: TimeInterval) -> (az: Float, el: Float) {
        guard let last = dragSamples.last, time - last.time < 0.08,
              let first = dragSamples.last(where: { last.time - $0.time >= 0.06 }) ?? dragSamples.first,
              last.time - first.time > 0.008 else { return (0, 0) }
        var dAz = last.az - first.az
        if dAz > .pi { dAz -= 2 * .pi }
        if dAz < -.pi { dAz += 2 * .pi }
        let dt = Float(last.time - first.time)
        return (dAz / dt, (last.el - first.el) / dt)
    }

    // The HUD has no buttons for these, so they live in the right-click menu (⌘Q also works).
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Dish Web UI", action: #selector(openWebUI), keyEquivalent: "").target = self
        menu.addItem(withTitle: earth.isZoomedOut ? "Zoom In to Dish" : "Zoom Out to Earth",
                     action: #selector(zoomFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Starlink Menu Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func refreshNow() { onRefresh() }
    @objc private func zoomFromMenu() { toggleZoom() }
    @objc private func openWebUI() { NSWorkspace.shared.open(dishWebUI) }

    // A local event monitor sees gestures regardless of how SceneKit's camera control consumes them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        guard window != nil else { cancelStillWait(); return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? true } ? event : nil
        }
    }

    /// Returns false to swallow the event.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return true }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        switch event.type {
        case .leftMouseDown where inside && event.clickCount == 2:
            // Kept from SceneKit's camera control, which would otherwise treat it as the start of a drag.
            dragging = false
            toggleZoom()
            return false
        case .leftMouseDown:
            guard inside else { return true }
            dragging = true
            dragMoved = false
            dragSamples.removeAll()
            if case .coast = orbit.currentMode {
                dragMoved = true
                stopAutoOrbit()              // caught the spinning camera: hold it until released
            }
        case .leftMouseDragged:
            guard dragging else { return true }
            if !dragMoved {
                dragMoved = true
                stopAutoOrbit()              // holding the camera: don't resume until released
            }
            // The monitor runs before SceneKit handles this event, so this records the pose produced by
            // the previous one; the one-event lag doesn't matter for a velocity estimate.
            guard let a = cameraAngles() else { return true }
            dragSamples.append((event.timestamp, a.az, a.el))
            dragSamples.removeAll { event.timestamp - $0.time > 0.25 }
        case .leftMouseUp:
            guard dragging else { return true }
            dragging = false
            guard dragMoved else { return true }     // a plain click
            if let a = cameraAngles() { dragSamples.append((event.timestamp, a.az, a.el)) }
            let v = releaseVelocity(at: event.timestamp)
            if v.az != 0 || v.el != 0 {
                orbit.setMode(.coast(azRate: v.az, elRate: v.el))
                rendersContinuously = true
            }
            waitForStillThenOrbit()
        case .scrollWheel, .magnify:
            guard inside else { return true }
            pauseOrbit()
            waitForStillThenOrbit()          // keeps running across a stream of scroll events
        default:
            break
        }
        return true
    }
}

/// Drives the camera from SceneKit's render loop, starting from wherever the camera currently is:
///
/// * `.coast`: after a drag is released, the camera keeps turning and slows exponentially. It stops only
///   below `coastCutoffDegPerSec` (0.002°/s, about 1/100 of where SceneKit's own inertia snaps to zero),
///   so the end of the spin is imperceptible.
/// * `.orbit`: eases elevation toward 30° while rotating slowly about the vertical axis. Both motions
///   are scaled by a "smootherstep" envelope (6t⁵ − 15t⁴ + 10t³) over `rampSeconds`, whose first and
///   second derivatives are zero at the start, so the camera leaves rest with no visible kick.
/// * `.focus`: glides to a fixed azimuth/elevation and parks there (alignment mode). A critically damped
///   spring (no overshoot) whose pull is capped, so long moves cruise at a moderate speed; it starts from
///   the camera's current velocity and fades in over `focusRampSeconds`, so leaving the orbit is seamless.
final class AutoOrbit: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    enum Mode { case idle, coast(azRate: Float, elRate: Float), orbit, focus(azDeg: Float, elDeg: Float) }

    static let elevationDeg: Float = 30
    static let speedDegPerSec: Float = 5         // one revolution every 72 s
    static let easeSeconds: Float = 1.2          // elevation easing time constant at full strength
    static let rampSeconds: Float = 3.5          // time to reach full speed
    static let coastSeconds: Float = 0.55        // velocity decay time constant
    static let coastCutoffDegPerSec: Float = 0.002
    static let focusStiffness: Float = 2.0       // spring ω (rad/s): settling time constant 0.5 s
    static let focusMaxPullDeg: Float = 50       // caps cruise speed at ω·pull/2 = 50°/s
    static let focusRampSeconds: Float = 1.0
    static let focusParkDeg: Float = 0.005       // within this (and nearly still) → snap exactly and stop
    static let maxElevationDeg: Float = 88       // same limits as the drag controller
    /// Above the ground in the dish view; down to the south pole in the Earth view.
    static func minElevationDeg(earthView: Bool) -> Float { earthView ? -maxElevationDeg : 4 }

    private let target: SIMD3<Float>
    private let lock = NSLock()
    private var mode = Mode.idle
    /// Time spent in the current mode (sum of rendered frame steps, so it doesn't advance while suspended).
    private var elapsed: Float = 0
    private var lastTime: TimeInterval?
    /// Camera angular velocity (rad/s) as last driven, so a new motion can pick up where the last left off.
    private var azVel: Float = 0
    private var elVel: Float = 0
    /// Called (on the render thread) when `.focus` has parked the camera and gone idle.
    var onParked: (@Sendable () -> Void)?

    /// The zoom, the beams and the Earth view: animated every frame after the camera moves (beams face it).
    private let earth: EarthView?

    init(target: SIMD3<Float>, earth: EarthView? = nil) {
        self.target = target
        self.earth = earth
    }

    var currentMode: Mode {
        lock.lock(); defer { lock.unlock() }
        return mode
    }

    func setMode(_ m: Mode) {
        lock.lock(); defer { lock.unlock() }
        if case .focus = mode, case .focus = m {      // just a new target: keep gliding, no new ramp
            mode = m
            return
        }
        mode = m
        elapsed = 0
        lastTime = nil
        switch m {
        case .idle: azVel = 0; elVel = 0
        case let .coast(azRate, elRate): azVel = azRate; elVel = elRate
        case .orbit, .focus: break
        }
    }

    /// Stops advancing (no frames come while hidden) without changing mode or velocity; the next frame
    /// after resuming takes a zero step instead of jumping by the time spent hidden.
    func suspend() {
        lock.lock(); defer { lock.unlock() }
        lastTime = nil
    }

    static func smootherstep(_ x: Float) -> Float {
        let t = max(0, min(1, x))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let cam = renderer.pointOfView else { return }
        lock.lock()
        SkyScene.applyLensShift(to: cam, viewport: renderer.currentViewport.size)
        let parked = driveCamera(cam, time: time)
        lock.unlock()
        earth?.renderFrame(camera: cam)
        if parked, let onParked { onParked() }
    }

    /// Moves the camera one frame; true when `.focus` has just parked it. Called with `lock` held.
    private func driveCamera(_ cam: SCNNode, time: TimeInterval) -> Bool {
        if case .idle = mode { return false }
        let dt = Float(min(1.0 / 20, time - (lastTime ?? time)))   // cap hitches so they don't jump
        lastTime = time
        elapsed += dt
        guard dt > 0 else { return false }

        let rel = cam.simdPosition - target
        let dist = simd_length(rel)
        guard dist > 1e-3 else { return false }
        let el0 = asin(max(-1, min(1, rel.y / dist)))
        let az0 = atan2(rel.x, -rel.z)
        var el = el0, az = az0
        let rad = Float.pi / 180
        let elRange = Self.minElevationDeg(earthView: earth?.isAnimatingOrOut ?? false) * rad ... Self.maxElevationDeg * rad
        var parked = false

        switch mode {
        case .idle:
            return false
        case .coast(var azRate, var elRate):
            let decay = exp(-dt / Self.coastSeconds)
            azRate *= decay
            elRate *= decay
            mode = (azRate * azRate + elRate * elRate).squareRoot() < Self.coastCutoffDegPerSec * rad
                ? .idle : .coast(azRate: azRate, elRate: elRate)
            az += azRate * dt
            el += elRate * dt
        case .orbit:
            let envelope = Self.smootherstep(elapsed / Self.rampSeconds)
            el += (Self.elevationDeg * rad - el) * (1 - exp(-dt / Self.easeSeconds)) * envelope
            az += Self.speedDegPerSec * rad * envelope * dt
        case let .focus(targetAz, targetEl):
            let envelope = Self.smootherstep(elapsed / Self.focusRampSeconds)
            let w = Self.focusStiffness, pull = Self.focusMaxPullDeg * rad
            var dAz = remainder(targetAz * rad - az, 2 * .pi)          // shortest way round
            var dEl = targetEl * rad - el
            // Spring force is capped (bounded cruise speed); damping keeps it critically damped.
            azVel += envelope * (w * w * max(-pull, min(pull, dAz)) - 2 * w * azVel) * dt
            elVel += envelope * (w * w * max(-pull, min(pull, dEl)) - 2 * w * elVel) * dt
            az += azVel * dt
            el += elVel * dt
            dAz = remainder(targetAz * rad - az, 2 * .pi)
            dEl = targetEl * rad - el
            let near = Self.focusParkDeg * rad
            if abs(dAz) < near, abs(dEl) < near, abs(azVel) < near, abs(elVel) < near {
                az = targetAz * rad
                el = targetEl * rad
                mode = .idle
                parked = true
            }
        }
        el = min(elRange.upperBound, max(elRange.lowerBound, el))
        if case .focus = mode {} else {
            // Remember the velocity actually produced, for a later `.focus` to continue from.
            azVel = remainder(az - az0, 2 * .pi) / dt
            elVel = (el - el0) / dt
        }
        if parked { azVel = 0; elVel = 0 }

        cam.simdPosition = target + SIMD3(cos(el) * sin(az), sin(el), -cos(el) * cos(az)) * dist
        cam.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        return parked
    }
}
