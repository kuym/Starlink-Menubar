import AppKit
import Orbits
import SceneKit
import simd

/// Phased-array beams from the centre of the dish's face toward every Starlink satellite in its field of view:
/// thin glowing quads, turned about their own axis to face the camera, running out past the edge of the view.
/// The closest satellite's beam is white at full strength and bright enough to bloom. The others go from 33%
/// on the boresight down to 0% at the edge of the 67.5° field-of-view cone.
///
/// Simulation, three levels of work:
/// * every 30 s, a pass over the whole constellation picks the candidates: satellites within range of the
///   horizon for the next 30 s (a few hundred of ~10,000);
/// * every second, the candidates' positions are computed for the next whole second;
/// * every frame, the visible ones are interpolated between those update points, so they glide smoothly.
///
/// `renderFrame` runs on SceneKit's render thread (from `AutoOrbit`); the inputs are set from the main thread
/// and handed over under a lock.
final class SatelliteBeams: @unchecked Sendable {
    let root = SCNNode()

    static let maxBeams = 64
    static let width: Float = 0.05
    /// Beam length in scene units (dome radius 1, camera ~4.4 away): far past every edge of the viewport at any
    /// orbit angle or zoom, so the beams look endless, and still inside the camera's far plane (50).
    static let length: Float = 40
    /// Opacity of the other beams on the boresight; it falls linearly with the angle off the boresight, to
    /// zero at the edge of the field-of-view cone.
    static let dimLevel: Float = 0.33
    /// Extra emission on the closest beam, taking it over the camera's bloom threshold (1.0) so it glows.
    /// The others are alpha-blended at ≤ 1.0, so however many overlap they never bloom.
    static let bloomBoost: Float = 3.0
    /// How far ahead the candidate pass looks, and how far a satellite can be and still be a candidate:
    /// the slant range to the horizon from Starlink's highest shells (~2,800 km) plus 30 s of travel.
    static let candidateInterval: TimeInterval = 30
    static let candidateRadiusKm: Double = 3300
    static let levelEaseSeconds: Float = 0.3
    /// Starlink terminals only link to satellites at least ~25° above the horizon (the minimum elevation in
    /// SpaceX's FCC filings; the dish's obstruction map shows no recorded passes below it either). Below
    /// that a satellite is outside the dish's field of view however the antenna is tilted.
    static let minElevationDeg: Float = 25

    // Inputs (main thread → render thread).
    private let lock = NSLock()
    private var constellation: Constellation?
    private var observer: Observer?
    private var boresight: SIMD3<Float>?
    private var inputsVersion = 0

    // Render-thread state.
    private var seenVersion = -1
    private var candidates: [Int] = []
    private var candidatesTime: TimeInterval = -.infinity
    private struct Sample { var dir: SIMD3<Float>; var range: Float }
    private var prev: [Int: Sample] = [:]
    private var next: [Int: Sample] = [:]
    private var prevTime: TimeInterval = -.infinity
    private var lastFrameTime: TimeInterval?
    private struct Beam { let node: SCNNode; var level: Float }
    private var beams: [Int: Beam] = [:]
    private var pool: [SCNNode] = []
    /// The beams drawn in the last frame (render thread only), for the Earth view to draw the same.
    private(set) var frameBeams: [(dir: SIMD3<Float>, range: Float, opacity: Float, boost: Float)] = []
    /// Satellites in view after the last frame (for the snapshot tool's report).
    private(set) var lastVisible: [(satnum: Int, elevationDeg: Float, rangeKm: Float, closest: Bool)] = []

    init() {
        root.renderingOrder = 20                    // after the dome dots
        let texture = Self.texture()
        for _ in 0..<Self.maxBeams {
            // One material per beam: the closest one's emission is raised to make it bloom.
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = texture
            material.diffuse.mipFilter = .linear            // the far end recedes to a few pixels wide
            material.emission.mipFilter = .linear
            material.emission.contents = texture
            material.emission.intensity = 0
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = true        // hidden behind the terminal
            material.isDoubleSided = true
            let plane = SCNPlane(width: 1, height: 1)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.isHidden = true
            node.renderingOrder = 20
            root.addChildNode(node)
            pool.append(node)
        }
    }

    // MARK: Inputs

    func setConstellation(_ c: Constellation?) {
        lock.lock(); defer { lock.unlock() }
        guard c?.referenceDate != constellation?.referenceDate || c?.count != constellation?.count else { return }
        constellation = c
        inputsVersion += 1
    }

    func setObserver(_ o: Observer) {
        lock.lock(); defer { lock.unlock() }
        guard o != observer else { return }
        observer = o
        inputsVersion += 1
    }

    /// The antenna face's normal in scene coordinates; nil while there's no dish.
    func setBoresight(_ b: SIMD3<Float>?) {
        lock.lock(); defer { lock.unlock() }
        boresight = b
    }

    /// The constellation and observer currently in use (for the Earth view).
    var inputs: (Constellation?, Observer?) {
        lock.lock(); defer { lock.unlock() }
        return (constellation, observer)
    }

    /// True when there is something to draw (and so the view should keep rendering to animate it).
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return constellation != nil && observer != nil && boresight != nil
    }

    // MARK: Frame

    func renderFrame(cameraPosition cam: SIMD3<Float>, date: Date = Date()) {
        lock.lock()
        let (constellation, observer, boresight, version) = (self.constellation, self.observer, self.boresight, inputsVersion)
        lock.unlock()
        guard let constellation, let observer, let boresight else { hideAll(); return }

        let now = date.timeIntervalSinceReferenceDate
        if version != seenVersion {
            seenVersion = version
            candidatesTime = -.infinity
            prev = [:]; next = [:]
            prevTime = -.infinity
        }
        if now - candidatesTime > Self.candidateInterval || now < candidatesTime {
            candidates = Self.candidates(constellation, observer, at: now)
            candidatesTime = now
        }
        // Advance the 1 s update points; after a gap (popup reopened) start over from now.
        let nextTime = prevTime + 1
        if now >= nextTime || now < prevTime {
            if now < nextTime + 1, now >= prevTime, !next.isEmpty {
                prev = next
                prevTime = nextTime
            } else {
                prevTime = now.rounded(.down)
                prev = sample(constellation, observer, at: prevTime)
            }
            next = sample(constellation, observer, at: prevTime + 1)
        }
        let f = Float(max(0, min(1, now - prevTime)))
        let dt = Float(min(0.25, max(0, now - (lastFrameTime ?? now))))
        lastFrameTime = now

        // Interpolated directions, weighted by how far inside the field of view they are.
        var visible: [(id: Int, dir: SIMD3<Float>, range: Float, weight: Float)] = []
        for (id, a) in prev {
            let b = next[id] ?? a
            let dir = simd_normalize(simd_mix(a.dir, b.dir, SIMD3(repeating: f)))
            let w = Self.fieldOfViewWeight(dir, boresight: boresight)
            if w > 0.001 { visible.append((id, dir, a.range + (b.range - a.range) * f, w)) }
        }
        let closest = (visible.filter { $0.weight > 0.5 }.min { $0.range < $1.range }
                       ?? visible.min { $0.range < $1.range })?.id

        let origin = SkyScene.terminalCenter + boresight * (SkyScene.terminalThickness / 2)
        var shown = Set<Int>()
        frameBeams.removeAll(keepingCapacity: true)
        for v in visible {
            let target: Float = v.id == closest ? 1 : Self.dimLevel * Self.boresightFalloff(v.dir, boresight)
            var beam: Beam
            if let b = beams[v.id] {
                beam = b
                beam.level += (target - beam.level) * (1 - exp(-dt / Self.levelEaseSeconds))
            } else {
                guard let node = pool.popLast() else { continue }
                beam = Beam(node: node, level: target)
            }
            beams[v.id] = beam
            shown.insert(v.id)
            place(beam.node, origin: origin, dir: v.dir, camera: cam)
            beam.node.opacity = CGFloat(beam.level * v.weight)
            // Bloom fades in with the level: none at the dim level, full on the closest beam.
            let boost = Self.bloomBoost * max(0, (beam.level - Self.dimLevel) / (1 - Self.dimLevel))
            if let m = beam.node.geometry?.firstMaterial, abs(m.emission.intensity - CGFloat(boost)) > 0.01 {
                m.emission.intensity = CGFloat(boost)
            }
            frameBeams.append((v.dir, v.range, beam.level * v.weight, boost))
            if beam.node.isHidden { beam.node.isHidden = false }
        }
        for (id, b) in beams where !shown.contains(id) {
            b.node.isHidden = true
            pool.append(b.node)
            beams[id] = nil
        }
        lastVisible = visible.map { v in
            (constellation.satnums[v.id], asin(max(-1, min(1, v.dir.y))) * 180 / .pi, v.range, v.id == closest)
        }.sorted { $0.rangeKm < $1.rangeKm }
    }

    private func hideAll() {
        for (_, b) in beams { b.node.isHidden = true; pool.append(b.node) }
        beams = [:]
        lastVisible = []
        frameBeams = []
    }

    /// A long quad from the dish face along `dir`, turned about that axis to face the camera (at the point of
    /// the beam nearest the camera, where its width matters most).
    private func place(_ node: SCNNode, origin: SIMD3<Float>, dir: SIMD3<Float>, camera: SIMD3<Float>) {
        let length = Self.length
        let mid = origin + dir * (length / 2)
        let nearest = origin + dir * max(0, min(length, simd_dot(camera - origin, dir)))
        var side = simd_cross(dir, camera - nearest)
        if simd_length_squared(side) < 1e-8 { side = simd_cross(dir, SIMD3(0, 1, 0)) }
        if simd_length_squared(side) < 1e-8 { side = SIMD3(1, 0, 0) }
        side = simd_normalize(side)
        let normal = simd_cross(side, dir)
        // The plane is 1×1 in its local x/y: x spans the width, y runs from the dish (−½) to the far end (+½).
        node.simdTransform = simd_float4x4(columns: (SIMD4(side * Self.width, 0), SIMD4(dir * length, 0),
                                                     SIMD4(normal, 0), SIMD4(mid, 1)))
    }


    /// 1 on the boresight, falling linearly with the angle off it to 0 at the edge of the field-of-view cone.
    static func boresightFalloff(_ dir: SIMD3<Float>, _ boresight: SIMD3<Float>) -> Float {
        let coneDeg = 90 - SkyScene.fieldOfViewMinElevationDeg               // 67.5°
        let offDeg = acos(max(-1, min(1, simd_dot(dir, boresight)))) * 180 / .pi
        return max(0, 1 - offDeg / coneDeg)
    }

    /// 1 well inside the dish's field of view (the cone the dome's dots use, and at least `minElevationDeg`
    /// up), fading to 0 across its edges (~2°), so satellites slide in and out instead of popping.
    static func fieldOfViewWeight(_ dir: SIMD3<Float>, boresight: SIMD3<Float>) -> Float {
        let edge = sin(SkyScene.fieldOfViewMinElevationDeg * .pi / 180)
        let floor = sin(minElevationDeg * .pi / 180)
        return smoothstep(edge, edge + 0.035, simd_dot(dir, boresight)) * smoothstep(floor - 0.035, floor, dir.y)
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Orbits

    private static func gmstAndOffset(_ c: Constellation, at t: TimeInterval) -> (gmst: Double, dt: Double) {
        let date = Date(timeIntervalSinceReferenceDate: t)
        return (SGP4.gstime(SGP4.julianDate(date)), date.timeIntervalSince(c.referenceDate))
    }

    /// Satellites close enough to come into view before the next candidate pass.
    private static func candidates(_ c: Constellation, _ o: Observer, at t: TimeInterval) -> [Int] {
        let (gmst, dt) = gmstAndOffset(c, at: t)
        let r2 = candidateRadiusKm * candidateRadiusKm
        var out: [Int] = []
        for (i, orbit) in c.orbits.enumerated() where simd_length_squared(orbit.positionECEF(dt: dt, gmst: gmst) - o.ecef) < r2 {
            out.append(i)
        }
        return out
    }

    /// Directions (scene frame: x east, y up, z south) and ranges of the candidates above the horizon.
    private func sample(_ c: Constellation, _ o: Observer, at t: TimeInterval) -> [Int: Sample] {
        let (gmst, dt) = Self.gmstAndOffset(c, at: t)
        var out: [Int: Sample] = [:]
        for i in candidates {
            let enu = o.enu(c.orbits[i].positionECEF(dt: dt, gmst: gmst))
            let range = simd_length(enu)
            guard enu.z > 0.3 * range else { continue }      // ~17°: a little below the floor, so they fade in
            let d = SIMD3(Float(enu.x), Float(enu.z), Float(-enu.y)) / Float(range)
            out[i] = Sample(dir: d, range: Float(range))
        }
        return out
    }

    // MARK: Look

    /// White, bright along a thin core with a soft halo across the width. Along the beam (in scene units from
    /// the dish): fades in over the first 0.3, so the overlapping beams don't pile up into a blob on the dish,
    /// then dims only gently, so it carries on past the dome and off the edge of the view. Row 0 (top of the
    /// image) is the far end; 2048 rows over `length` gives ~0.02 units per row.
    private static func texture() -> CGImage? {
        let w = 32, h = 2048
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let d = (1 - (Float(y) + 0.5) / Float(h)) * length      // distance from the dish
            let along = smoothstep(0.02, 0.3, d) / (1 + 0.12 * d) * (1 - smoothstep(0.85 * length, length, d))
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w) * 2 - 1        // −1…1 across
                let across = exp(-(u / 0.14) * (u / 0.14)) + 0.2 * exp(-(u / 0.45) * (u / 0.45))
                let v = UInt8(max(0, min(255, (along * across / 1.2 * 255).rounded())))
                let i = (y * w + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = v      // white, alpha v (premultiplied)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
