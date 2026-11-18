import AppKit
import Orbits
import SceneKit
import simd

/// The zoomed-out "Earth view", and the zoom between it and the dish view (double-click toggles).
///
/// A globe with low-poly continents, every Starlink satellite as a small white dot, and beams from the
/// dish's location to the satellites in its field of view. The globe is turned so the dish's location is on
/// top and its local east/up/north line up with the dish view's x/y/−z: the camera's orbit about the vertical
/// then turns the globe exactly as it turns the dish view, and the beams leave the surface in the same
/// directions as the dish view's.
///
/// The zoom is one continuous camera pull-back. `z` runs from 0 (dish view) to 1 (Earth view); the dish
/// scene shrinks geometrically about its ground point while the globe shrinks from a huge radius (where its
/// surface is the dish view's ground) to its final size, both anchored at the dish's location, so the dish
/// stays where it really is on the Earth all the way. Each crossfades as it gets too small or too big to read.
///
/// Everything here runs on SceneKit's render thread, from `renderFrame`; `toggle` is called from the main thread.
final class EarthView: @unchecked Sendable {
    /// Holds the whole dish scene (ground, compass, terminal, dome, beams); scaled for the zoom.
    let dishRoot = SCNNode()
    /// The globe, satellites and beams, in Earth-fixed coordinates (units of Earth radii).
    let earthRoot = SCNNode()

    static let duration: TimeInterval = 1
    /// Globe radius in scene units: with the satellite shell (~1.09 radii) it fits the space above the HUD
    /// that the dome fills in the dish view.
    static let radius: Float = 0.78
    /// The dish scene's scale at the end of the zoom-out (the dome radius as a fraction of the globe's).
    static let dishFinalScale: Float = 0.03
    static let earthRadiusKm = 6371.0
    static let beamWidth: Float = 0.007
    static let satelliteUpdateInterval: TimeInterval = 1

    private let beams: SatelliteBeams
    private let globe = SCNNode()
    private let satellites = SCNNode()
    /// The background stars: centred on the camera (so they're at infinity, with no parallax), in the Earth-fixed
    /// frame turned back by sidereal time, so they hold still against the sky while the globe spins under them.
    let starRoot = SCNNode()
    /// Distance of the star sphere from the camera: well past the globe, inside the far plane (150).
    static let starDistance: Float = 100
    /// The brightest star's grey as a fraction of the satellites' (0.8).
    static let starPeak: Float = 0.8
    /// Brightness compression: grey ∝ flux^γ, with γ chosen so the median star is drawn at this fraction of the
    /// brightest's, putting the brighter half of the stars in the top quarter of the range.
    static let starMedianLevel: Float = 0.75
    /// Point radius (pixels) by magnitude, brightest first: the bright stars cover more pixels.
    static let starSizes: [(brighterThan: Float, radius: CGFloat)] = [(0.5, 4.0), (1.5, 3.2), (2.5, 2.4), (.infinity, 1.7)]
    private let marker = SCNNode()
    private let beamRoot = SCNNode()
    private var beamPool: [SCNNode] = []

    // Zoom state, shared with the main thread.
    private let lock = NSLock()
    private var from: Float = 0
    private var to: Float = 0
    private var start: TimeInterval = 0
    private var span: TimeInterval = 0
    /// Bumped by every `toggle`/`set`, so the render thread knows a new zoom has started.
    private var generation = 0
    /// Turn of the whole world (dish scene and globe) about the vertical through the orbit's centre, degrees
    /// of azimuth. Turning the world is what moves the camera relative to it during a zoom: the camera's own
    /// orbit carries on untouched. Written by the render thread; `yawFrom` is its value as a zoom starts.
    private var yaw: Float = 0
    private var yawFrom: Float = 0
    /// Where the dish view's camera starts (`SkyScene`'s initial view): the zoom in lands there.
    private var homeAzimuthDeg: Float = 0
    /// The Earth view opens with the dish's location this far round to the left (west) of the camera, so the
    /// orbit then carries the camera over it.
    static let observerLeadDeg: Float = 45

    /// The dish view's ground light: its reach and intensity are scaled with the dish scene (lights don't
    /// scale with their node).
    var glowLight: SCNLight? {
        didSet { glowReach = glowLight?.attenuationEndDistance ?? 0; glowIntensity = glowLight?.intensity ?? 0 }
    }
    private var glowReach: CGFloat = 0
    private var glowIntensity: CGFloat = 0

    // Render-thread state.
    private var appliedZ: Float = -1
    private var appliedYaw: Float = 0
    private var seenGeneration = -1
    /// The current zoom's world turn has reached its end and is fixed.
    private var yawSettled = true
    /// How far (eased, 0…1) the current zoom has brought the camera's elevation, distance and field of view
    /// to the next view's defaults.
    private var poseEase: Float = 1
    /// Azimuth of the dish's location over the north-up globe (before the world turn).
    private var observerAzimuthDeg: Float = 180
    private var earthRadius: Float = 1
    private var orientedFor: Observer?
    /// Earth-fixed → scene with the observer on top (east → +x, up → +y, north → −z): how the globe meets
    /// the dish view.
    private var observerUp = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// The tilt that then stands the polar axis upright (about the east-west axis), so in the Earth view the
    /// camera's orbit about the vertical spins the globe about its poles.
    private var poleUpTilt = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// The observer on the unit globe, Earth-fixed.
    private var observerPoint = SIMD3<Float>(0, 0, 1)
    private var satellitesTime: TimeInterval = -.infinity
    private var satellitesFor: Date?

    init(beams: SatelliteBeams) {
        self.beams = beams
        globe.geometry = Self.globeGeometry()
        globe.renderingOrder = -20                   // under the fading dish scene's ground
        earthRoot.addChildNode(globe)

        satellites.renderingOrder = -10
        earthRoot.addChildNode(satellites)

        starRoot.geometry = Self.starGeometry()
        starRoot.renderingOrder = -30                // first: the globe and everything else draws over them
        starRoot.isHidden = true

        let dot = SCNSphere(radius: 1)
        dot.segmentCount = 12
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.emission.contents = NSColor.white
        m.emission.intensity = 1.5                   // over the bloom threshold: a small glow at the dish
        dot.materials = [m]
        marker.geometry = dot
        marker.renderingOrder = -5
        earthRoot.addChildNode(marker)

        let texture = Self.beamTexture()
        for _ in 0..<SatelliteBeams.maxBeams {
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = texture
            mat.emission.contents = texture
            mat.emission.intensity = 0
            mat.writesToDepthBuffer = false
            mat.isDoubleSided = true
            let plane = SCNPlane(width: 1, height: 1)
            plane.materials = [mat]
            let n = SCNNode(geometry: plane)
            n.isHidden = true
            n.renderingOrder = -4
            beamRoot.addChildNode(n)
            beamPool.append(n)
        }
        earthRoot.addChildNode(beamRoot)
        earthRoot.isHidden = true
    }

    // MARK: Zoom (main thread)

    /// Current zoom: 0 = dish view, 1 = Earth view.
    private func z(at now: TimeInterval) -> Float {
        guard span > 0 else { return to }
        let t = Float(max(0, min(1, (now - start) / span)))
        return from + (to - from) * Self.ease(t)
    }

    /// True when zoomed out or zooming either way (the view should keep drawing).
    var isAnimatingOrOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return to > 0 || z(at: ProcessInfo.processInfo.systemUptime) > 0
    }

    /// True when zoomed out, or zooming out.
    var isZoomedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return to > 0.5
    }

    /// Zooms out to the Earth view, or back in to the dish view, from wherever the zoom is now (so a double-
    /// click mid-zoom turns it round). A full zoom takes `duration`; a partial one proportionally less.
    func toggle() {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let current = z(at: now)
        from = current
        to = to > 0.5 ? 0 : 1
        start = now
        span = Self.duration * TimeInterval(abs(to - from))
        yawFrom = yaw
        generation += 1
    }

    /// Jumps straight to a zoom level (back to the dish view on a fresh open; snapshots), unturned.
    func set(_ z: Float) {
        lock.lock(); defer { lock.unlock() }
        from = z; to = z; span = 0
        yaw = 0; yawFrom = 0
        generation += 1
    }

    /// The dish view's initial camera azimuth (kept current by `SkyScene` as the dish moves).
    func setHomeAzimuth(_ deg: Float) {
        lock.lock(); defer { lock.unlock() }
        homeAzimuthDeg = deg
    }

    /// Ease in and out (smootherstep: zero velocity and acceleration at both ends).
    static func ease(_ t: Float) -> Float { AutoOrbit.smootherstep(t) }

    // MARK: Frame (render thread)

    /// Advances the zoom, then animates the dish view's beams and (when it shows) the Earth view.
    func renderFrame(camera: SCNNode, date: Date = Date()) {
        let (constellation, observer) = beams.inputs
        orient(observer)
        let pivot = SkyScene.orbitCenter
        var rel = camera.simdPosition - pivot
        let cameraAz = atan2(rel.x, -rel.z) * 180 / .pi

        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let z = self.z(at: now)
        if generation != seenGeneration {
            seenGeneration = generation
            yawSettled = span == 0
            poseEase = span == 0 ? 1 : 0
        }
        if poseEase < 1 {
            // Either way, the next view opens at its default framing, not wherever the last view's camera was
            // dragged or zoomed: elevation, distance and field of view go to the initial view's (azimuth is
            // the world turn's job, below). Each frame closes the same eased fraction of whatever gap remains,
            // so it lands exactly there whatever else moves the camera meanwhile.
            let e = Self.ease(Float(max(0, min(1, (now - start) / span))))
            let k = (e - poseEase) / (1 - poseEase)
            poseEase = e >= 1 ? 1 : e
            let dist = simd_length(rel)
            if k > 0, dist > 1e-3 {
                let el = asin(max(-1, min(1, rel.y / dist)))
                let newEl = el + (AutoOrbit.elevationDeg * .pi / 180 - el) * k
                let newDist = dist + (SkyScene.cameraDistance - dist) * k
                let flat = SIMD3(rel.x, 0, rel.z)
                let h = simd_length(flat) > 1e-6 ? simd_normalize(flat) : SIMD3<Float>(0, 0, 1)
                rel = (h * cos(newEl) + SIMD3(0, sin(newEl), 0)) * newDist
                camera.simdPosition = pivot + rel
                camera.simdLook(at: pivot, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
                if let lens = camera.camera {
                    lens.fieldOfView += (SkyScene.cameraFieldOfView - lens.fieldOfView) * CGFloat(k)
                }
            }
        }
        if !yawSettled {
            // Turn the world so that, when the zoom ends, the camera is where it should be: out, with the dish's
            // location 45° to its left; in, at the dish view's initial angle. The goal follows the camera (it
            // may be orbiting) until the end, then stays put.
            let t = Float(max(0, min(1, (now - start) / span)))
            let goal = to > 0.5 ? cameraAz + Self.observerLeadDeg - observerAzimuthDeg : cameraAz - homeAzimuthDeg
            yaw = yawFrom + remainder(goal - yawFrom, 360) * Self.ease(t)
            if t >= 1 { yawSettled = true }
        }
        if yawSettled, to == 0, z == 0, yaw != 0 {
            // Back in the dish view: hand the turn over to the camera (turn it back by the same amount, so
            // nothing visibly moves), leaving the dish scene unturned for its compass-based camera moves.
            let q = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0))      // azimuth −yaw
            camera.simdPosition = pivot + q.act(rel)
            camera.simdOrientation = q * camera.simdOrientation
            yaw = 0
        }
        let yaw = self.yaw
        lock.unlock()
        if z != appliedZ || yaw != appliedYaw { applyZoom(z, yaw: yaw) }
        let cam = camera.simdWorldPosition

        let dishCam = simd_mul(simd_inverse(dishRoot.simdTransform), SIMD4(cam, 1))
        beams.renderFrame(cameraPosition: SIMD3(dishCam.x, dishCam.y, dishCam.z), date: date)
        guard !earthRoot.isHidden else { return }
        updateSatellites(constellation, at: date)
        updateStars(camera: cam, date: date)
        let earthCam = simd_mul(simd_inverse(earthRoot.simdTransform), SIMD4(cam, 1))
        updateBeams(observer, camera: SIMD3(earthCam.x, earthCam.y, earthCam.z))
    }

    /// Lays out both scenes for zoom level `z`.
    private func applyZoom(_ z: Float, yaw: Float) {
        appliedZ = z
        appliedYaw = yaw
        let ground = SIMD3<Float>(0, SkyScene.groundY, 0)
        // Geometric (log-scale) zoom: a steady pull-back reads as an equal ratio per unit time.
        let dishScale = pow(Self.dishFinalScale, z)
        let earthRadius = Self.radius / Self.dishFinalScale * dishScale     // keeps their ratio fixed
        // Over the second half the globe tilts from "dish on top" to "north pole up", turning the dish's spot
        // (and the fading dish scene with it) toward the camera's side, at its latitude.
        let tilt = simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), poleUpTilt, AutoOrbit.smootherstep((z - 0.3) / 0.7))
        let orientation = tilt * observerUp
        let observerDir = orientation.act(observerPoint)                    // straight up until the tilt
        let final = SkyScene.orbitCenter + poleUpTilt.act(observerUp.act(observerPoint)) * Self.radius
        let anchor = ground + (final - ground) * z                            // the dish's spot, moving to its place on the globe

        // The world turn about the vertical through the orbit's centre (azimuth +yaw): pivot + turn · (p − pivot).
        let turn = simd_quatf(angle: -yaw * .pi / 180, axis: SIMD3(0, 1, 0))
        let pivot = SkyScene.orbitCenter
        let turnM = simd_float4x4(columns: (SIMD4(turn.act(SIMD3(1, 0, 0)), 0), SIMD4(turn.act(SIMD3(0, 1, 0)), 0),
                                            SIMD4(turn.act(SIMD3(0, 0, 1)), 0), SIMD4(pivot - turn.act(pivot), 1)))

        // anchor + tilt · scale · (p − ground), then turned
        let r = simd_float3x3(tilt) * dishScale
        dishRoot.simdTransform = turnM * simd_float4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0),
                                                                 SIMD4(r.columns.2, 0), SIMD4(anchor - r * ground, 1)))
        let dishOpacity = 1 - Self.smoothstep(0.3, 0.8, z)
        dishRoot.opacity = CGFloat(dishOpacity)
        dishRoot.isHidden = dishOpacity <= 0.001
        glowLight?.attenuationEndDistance = glowReach * CGFloat(dishScale)
        // Physically based shading also falls off with the inverse square of distance, so as the scene shrinks
        // the light would brighten the terminal just above it by 1/scale²: its underside, already ~13,000×
        // white, overflows the half-float HDR buffer (max 65,504) to infinity by z ≈ 0.3, and the bloom blur
        // turns that into NaN, drawn as black screen-aligned blocks. Scaling the intensity with it keeps every
        // lit surface exactly as bright as in the dish view.
        glowLight?.intensity = glowIntensity * CGFloat(dishScale * dishScale)

        // A hair below the dish's ground plane, so the two don't z-fight while both show.
        self.earthRadius = earthRadius
        let e = simd_float3x3(orientation) * earthRadius
        let centre = anchor - observerDir * (earthRadius * 1.0005)
        earthRoot.simdTransform = turnM * simd_float4x4(columns: (SIMD4(e.columns.0, 0), SIMD4(e.columns.1, 0),
                                                                  SIMD4(e.columns.2, 0), SIMD4(centre, 1)))
        let earthOpacity = Self.smoothstep(0.05, 0.55, z)
        earthRoot.opacity = CGFloat(earthOpacity)
        earthRoot.isHidden = earthOpacity <= 0.001
        // The satellites would swarm around the camera while the globe is huge: they come in last.
        satellites.opacity = CGFloat(Self.smoothstep(0.4, 0.9, z))
        starRoot.opacity = satellites.opacity
        starRoot.isHidden = satellites.opacity <= 0.001
        marker.simdScale = SIMD3(repeating: 0.012 / earthRadius)
    }

    /// Works out the globe's orientations for this observer (see `observerUp`, `poleUpTilt`).
    private func orient(_ observer: Observer?) {
        guard let observer, observer != orientedFor else { return }
        orientedFor = observer
        func f(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        observerUp = simd_quatf(simd_float3x3(rows: [f(observer.east), f(observer.up), -f(observer.north)]))
        let pole = observerUp.act(SIMD3(0, 0, 1))                           // the north pole, in the scene
        poleUpTilt = simd_quatf(from: pole, to: SIMD3(0, 1, 0))
        observerPoint = Self.surfacePoint(observer)
        marker.simdPosition = observerPoint
        let d = poleUpTilt.act(observerUp.act(observerPoint))
        observerAzimuthDeg = atan2(d.x, -d.z) * 180 / .pi
        appliedZ = -1                                                       // re-lay out for the new orientation
    }

    /// The observer on the unit globe, Earth-fixed.
    private static func surfacePoint(_ o: Observer) -> SIMD3<Float> {
        let p = simd_normalize(o.ecef)
        return SIMD3(Float(p.x), Float(p.y), Float(p.z))
    }

    /// Every satellite as a dot, recomputed once a second. They move ~0.06°/s round the globe, a fraction of
    /// a pixel at this scale, so stepping them is as smooth as interpolating would be.
    private func updateSatellites(_ c: Constellation?, at date: Date) {
        let now = date.timeIntervalSinceReferenceDate
        guard let c else { satellites.geometry = nil; return }
        if now - satellitesTime < Self.satelliteUpdateInterval, now >= satellitesTime, satellitesFor == c.referenceDate { return }
        satellitesTime = now
        satellitesFor = c.referenceDate
        let gmst = SGP4.gstime(SGP4.julianDate(date))
        let dt = date.timeIntervalSince(c.referenceDate)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(c.count)
        for o in c.orbits {
            let p = o.positionECEF(dt: dt, gmst: gmst) / Self.earthRadiusKm
            // Skip anything that has fallen out of the model (re-entered, or a wild extrapolation).
            let r = simd_length(p)
            if r > 1.01, r < 1.5 { points.append(SIMD3(Float(p.x), Float(p.y), Float(p.z))) }
        }
        let source = points.withUnsafeBufferPointer { buf in
            SCNGeometrySource(data: Data(buffer: buf), semantic: .vertex, vectorCount: buf.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        }
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: points.count, bytesPerIndex: 4)
        element.pointSize = 1
        element.minimumPointScreenSpaceRadius = 1.2
        element.maximumPointScreenSpaceRadius = 1.2
        let geo = SCNGeometry(sources: [source], elements: [element])
        geo.materials = [satelliteMaterial]
        satellites.geometry = geo
    }

    /// Keeps the star sphere on the camera, and turned with the globe less the Earth's rotation since the
    /// vernal equinox crossed Greenwich: Earth-fixed = R_z(−GMST) · inertial.
    private func updateStars(camera: SIMD3<Float>, date: Date) {
        guard !starRoot.isHidden else { return }
        let m = earthRoot.simdTransform
        let rotation = simd_quatf(simd_float3x3(simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                                                simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                                                simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))))
        let gmst = Float(SGP4.gstime(SGP4.julianDate(date)))
        starRoot.simdPosition = camera
        starRoot.simdOrientation = rotation * simd_quatf(angle: -gmst, axis: SIMD3(0, 0, 1))
    }

    /// The catalogue's stars as points on a sphere of radius `starDistance` (inertial: x to the vernal equinox,
    /// z to the north celestial pole), added onto the background in grey levels by magnitude. The brighter
    /// ones are drawn a little larger.
    static func starGeometry() -> SCNGeometry {
        let rows = Stars.encoded.split(separator: ";").map { $0.split(separator: ",").compactMap { Float($0) } }
            .filter { $0.count == 3 }
        let mags = rows.map { $0[2] / 100 }                 // brightest first
        guard let brightest = mags.first else { return SCNGeometry() }
        // Flux relative to the brightest is 10^(−0.4 Δm); solve median^γ = starMedianLevel for γ.
        func flux(_ m: Float) -> Float { pow(10, -0.4 * (m - brightest)) }
        let gamma = log(starMedianLevel) / log(flux(mags[mags.count / 2]))
        // Grey levels as displayed (sRGB, like the satellites' 0.8), made linear: the blend adds light linearly.
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var points: [SIMD3<Float>] = [], colours: [SIMD4<Float>] = []
        for (r, mag) in zip(rows, mags) {
            let ra = r[0] / 100 * .pi / 180, dec = r[1] / 100 * .pi / 180
            points.append(SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec)) * starDistance)
            let level = linear(0.8 * starPeak * pow(flux(mag), gamma))
            colours.append(SIMD4(level, level, level, 1))
        }
        let vertices = points.withUnsafeBufferPointer { buf in
            SCNGeometrySource(data: Data(buffer: buf), semantic: .vertex, vectorCount: buf.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        }
        let colors = colours.withUnsafeBufferPointer { buf in
            SCNGeometrySource(data: Data(buffer: buf), semantic: .color, vectorCount: buf.count,
                              usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        }
        func element(_ range: Range<Int>, radius: CGFloat) -> SCNGeometryElement {
            let indices = range.map { UInt32($0) }
            let e = SCNGeometryElement(indices: indices, primitiveType: .point)
            e.pointSize = 1
            e.minimumPointScreenSpaceRadius = radius
            e.maximumPointScreenSpaceRadius = radius
            return e
        }
        var elements: [SCNGeometryElement] = [], from = 0
        for size in starSizes {
            let to = mags[from...].firstIndex { $0 >= size.brighterThan } ?? mags.count
            if to > from { elements.append(element(from..<to, radius: size.radius)) }
            from = to
        }
        let geo = SCNGeometry(sources: [vertices, colors], elements: elements)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        geo.materials = [m]
        return geo
    }

    private let satelliteMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.8, alpha: 1)
        m.writesToDepthBuffer = false                // occluded by the globe, but never by each other
        return m
    }()

    /// The dish view's beams, from the dish's spot on the globe out to their satellites, at the same strengths.
    private func updateBeams(_ observer: Observer?, camera: SIMD3<Float>) {
        var used = 0
        if let observer {
            let origin = Self.surfacePoint(observer)
            func f(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
            let (e, u, n) = (f(observer.east), f(observer.up), f(observer.north))
            let width = Self.beamWidth / max(earthRadius, 1e-6)          // constant on screen
            for b in beams.frameBeams where used < beamPool.count && b.opacity > 0.002 {
                // Scene direction (east, up, south) → Earth-fixed.
                let dir = simd_normalize(e * b.dir.x + u * b.dir.y - n * b.dir.z)
                let length = b.range / Float(Self.earthRadiusKm)
                let node = beamPool[used]
                used += 1
                Self.place(node, origin: origin, dir: dir, length: length, width: width, camera: camera)
                node.opacity = CGFloat(b.opacity)
                if let m = node.geometry?.firstMaterial, abs(m.emission.intensity - CGFloat(b.boost)) > 0.01 {
                    m.emission.intensity = CGFloat(b.boost)
                }
                if node.isHidden { node.isHidden = false }
            }
        }
        for node in beamPool[used...] where !node.isHidden { node.isHidden = true }
    }

    /// A quad from `origin` along `dir`, turned about its axis to face the camera.
    private static func place(_ node: SCNNode, origin: SIMD3<Float>, dir: SIMD3<Float>, length: Float,
                              width: Float, camera: SIMD3<Float>) {
        let mid = origin + dir * (length / 2)
        var side = simd_cross(dir, camera - mid)
        if simd_length_squared(side) < 1e-12 { side = simd_cross(dir, SIMD3(0, 0, 1)) }
        side = simd_normalize(side)
        node.simdTransform = simd_float4x4(columns: (SIMD4(side * width, 0), SIMD4(dir * length, 0),
                                                     SIMD4(simd_cross(side, dir), 0), SIMD4(mid, 1)))
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Look

    static let ocean = NSColor(white: 0.075, alpha: 1)
    static let land = NSColor(white: 0.2, alpha: 1)
    static let coast = NSColor(white: 0.34, alpha: 1)
    static let graticule = NSColor(white: 0.11, alpha: 1)

    /// A latitude/longitude sphere in Earth-fixed axes (z = north pole), textured with the land map.
    private static func globeGeometry() -> SCNGeometry {
        let lonSteps = 144, latSteps = 72
        var verts: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for j in 0...latSteps {
            let lat = Float.pi / 2 - Float(j) / Float(latSteps) * .pi
            for i in 0...lonSteps {
                let lon = -Float.pi + Float(i) / Float(lonSteps) * 2 * .pi
                let p = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
                verts.append(p)
                normals.append(p)
                uvs.append(SIMD2(Float(i) / Float(lonSteps), Float(j) / Float(latSteps)))
            }
        }
        let row = UInt32(lonSteps + 1)
        for j in 0..<UInt32(latSteps) {
            for i in 0..<UInt32(lonSteps) {
                let a = j * row + i, b = a + row
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        func source<T>(_ a: [T], _ semantic: SCNGeometrySource.Semantic, _ n: Int) -> SCNGeometrySource {
            a.withUnsafeBufferPointer { buf in
                SCNGeometrySource(data: Data(buffer: buf), semantic: semantic, vectorCount: buf.count,
                                  usesFloatComponents: true, componentsPerVector: n, bytesPerComponent: 4,
                                  dataOffset: 0, dataStride: MemoryLayout<T>.stride)
            }
        }
        let geo = SCNGeometry(sources: [source(verts, .vertex, 3), source(normals, .normal, 3), source(uvs, .texcoord, 2)],
                              elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = landMap()
        m.diffuse.mipFilter = .linear
        m.diffuse.wrapS = .repeat
        // A faint cool rim, like an atmosphere seen edge-on.
        m.shaderModifiers = [.fragment: """
            #pragma body
            float facing = saturate(dot(normalize(_surface.normal), normalize(_surface.view)));
            float rim = pow(1.0 - facing, 5.0);
            _output.color.rgb += float3(0.30, 0.48, 0.75) * rim * 0.45;
            """]
        geo.materials = [m]
        return geo
    }

    /// Equirectangular map (u = longitude from −180°, v = latitude from +90°): dark ocean with a faint 15°
    /// graticule, land in dark grey with a lighter coastline, every vertex left visible as a corner.
    static func landMap() -> CGImage? {
        let w = 4096, h = 2048
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let sx = CGFloat(w) / 360, sy = CGFloat(h) / 180
        func pt(_ lon: CGFloat, _ lat: CGFloat) -> CGPoint { CGPoint(x: (lon + 180) * sx, y: (lat + 90) * sy) }
        ctx.setFillColor(ocean.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(graticule.cgColor)
        ctx.setLineWidth(2)
        for lon in stride(from: -180, through: 180, by: 15) {
            ctx.move(to: pt(CGFloat(lon), -90)); ctx.addLine(to: pt(CGFloat(lon), 90))
        }
        for lat in stride(from: -75, through: 75, by: 15) {
            ctx.move(to: pt(-180, CGFloat(lat))); ctx.addLine(to: pt(180, CGFloat(lat)))
        }
        ctx.strokePath()

        let path = CGMutablePath()
        for ring in continentRings() {
            path.addLines(between: ring.map { pt($0.x, $0.y) })
            path.closeSubpath()
        }
        ctx.addPath(path)
        ctx.setFillColor(land.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setLineJoin(.miter)
        ctx.setStrokeColor(coast.cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// Decodes `Continents.encoded` into rings of (longitude, latitude) degrees.
    static func continentRings() -> [[CGPoint]] {
        Continents.encoded.replacingOccurrences(of: "\n", with: "").split(separator: "|").map { ring in
            ring.split(separator: " ").compactMap { v -> CGPoint? in
                let c = v.split(separator: ",")
                guard c.count == 2, let lon = Double(c[0]), let lat = Double(c[1]) else { return nil }
                return CGPoint(x: lon / 10, y: lat / 10)
            }
        }
    }

    /// Gaussian across, full strength along, fading out at the satellite end.
    private static func beamTexture() -> CGImage? {
        let w = 32, h = 256
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let d = 1 - (Float(y) + 0.5) / Float(h)                 // 0 at the dish, 1 at the satellite
            let along = 1 - 0.5 * smoothstep(0.6, 1, d)
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w) * 2 - 1
                let across = exp(-(u / 0.3) * (u / 0.3))
                let v = UInt8(max(0, min(255, (along * across * 255).rounded())))
                let i = (y * w + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
