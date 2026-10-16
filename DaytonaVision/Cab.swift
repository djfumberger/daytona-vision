import Foundation
import RealityKit
import UIKit

/// The arcade cabinet in the immersive space.
///
/// A designed cab replaces the placeholder: `Cab.usdz` in the app's resources
/// (model/export_usdz.py makes it from model/daytona_cabinet.blend). Its origin
/// is the floor, Y up, the driver at +Z facing -Z, in metres. The app looks for
/// these entity names:
///
///   EyePoint          where the driver's eyes go (required for a good fit)
///   Screen, CRT_Screen  a model whose material becomes the game screen (UVs 0..1)
///   Wheel             the rim, turned about its own Z axis; its parent is the column
///   SpeakerL/R        where the sound comes from (default: the screen)
///   ShifterLever      tilted into the four gear positions: pivot at its origin,
///                     local Z up the stick, local -Y toward the driver (optional)
///   PedalPivot_Gas/_Brake  the pedal hinges, local +Y up the pad: pressing turns
///                     them about -X, laying the pad down (optional)
///   Button_<name>     tappable: start, coin, view1..view4, test, service
///                     (any case; CoinDoor and CoinEntry_* are coin too)
@MainActor
final class Cab {
    /// Floor-level root, placed under the driver on recenter.
    let root = Entity()

    /// Eye-relative content, lifted to the driver's eye height.
    let rig = Entity()

    private(set) var screen: ModelEntity!

    private(set) var wheel: Entity!
    private(set) var wheelBaseOrientation = simd_quatf(angle: 0, axis: [0, 0, 1])
    private(set) var wheelRadius: Float = 0.18

    private(set) var speakerL: Entity!
    private(set) var speakerR: Entity!

    private var shifterKnob: Entity?
    private var shifterLever: Entity?
    private var shifterLeverRest = simd_quatf(angle: 0, axis: [0, 0, 1])
    private var shifterRest = SIMD3<Float>()

    private var base: ModelEntity?

    /// The pedals' hinges, their rest orientations, and how far down each is (0...1, smoothed).
    private var pedals: [(pivot: Entity, rest: simd_quatf, travel: Float)] = []

    /// The lamp buttons' caps: the game's lamp bit, the cap, its material (the
    /// model's own, only its glow changed) and the colour it glows.
    private var lamps: [(bit: UInt32, cap: ModelEntity, material: PhysicallyBasedMaterial, color: UIColor)] = []
    private var lampBits: UInt32?

    private var eyePoint = SIMD3<Float>()
    private(set) var isCustom = false

    let environment = Entity()

    static let screenSize = SIMD2<Float>(0.66, 0.66 * 384 / 496)

    init() async {
        root.name = "CabRoot"
        root.addChild(rig)

        if let custom = await Self.loadCustom() {
            isCustom = true
            rig.addChild(custom)
            bind(custom)
        } else {
            buildPlaceholder()
        }

        bindLamps()
        buildGripGlows()
        Self.makeTappable(screen, hover: false) // a pinch on the screen shows the toolbar
        footprint = rig.visualBounds(relativeTo: rig) // before any panels are attached
        buildPlacer()
        await buildEnvironment()
        root.addChild(environment)
    }

    /// Whether an entity is (part of) the game screen.
    func isScreen(_ entity: Entity) -> Bool {
        var e: Entity? = entity
        while let current = e {
            if current === screen { return true }
            e = current.parent
        }
        return false
    }

    /// Where the toolbar goes, in the rig's frame: centred under the screen,
    /// a little toward the driver.
    var toolbarPosition: SIMD3<Float> {
        let b = screen.visualBounds(relativeTo: rig)
        return [b.center.x, b.min.y - 0.07, b.max.z + 0.06]
    }

    // MARK: Placement

    /// Puts the cab around the driver: `head` is the device transform in the
    /// immersive space (origin on the floor).
    /// `growingFrom`: the start volume's little cab (its seat, scaled), which
    /// the cab glides and grows from to its place.
    func place(head: simd_float4x4, growingFrom start: simd_float4x4? = nil) {
        let p = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var forward = -SIMD3<Float>(head.columns.2.x, 0, head.columns.2.z)
        if simd_length(forward) < 1e-3 { forward = [0, 0, -1] }
        forward = simd_normalize(forward)

        place(at: [p.x, 0, p.z], yaw: atan2(-forward.x, -forward.z), eyeHeight: max(0.8, p.y))
        glide(from: start)
    }

    /// Puts the driver's seat where `seat` says (a saved spot: on the floor,
    /// its -Z the way the driver faces), gliding there from `start`.
    func place(seat: simd_float4x4, eyeHeight: Float, growingFrom start: simd_float4x4? = nil) {
        place(
            at: [seat.columns.3.x, 0, seat.columns.3.z],
            yaw: atan2(seat.columns.2.x, seat.columns.2.z),
            eyeHeight: eyeHeight
        )
        glide(from: start)
    }

    /// Where the driver's seat is now (the root's resting pose, whatever it is
    /// animating), to save.
    var seatTransform: simd_float4x4 {
        Transform(rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: seatPosition).matrix
    }

    /// Animates the root from `start` to where it is now.
    func glide(from start: simd_float4x4?) {
        guard let start else { return }
        let rest = root.transformMatrix(relativeTo: nil)
        root.setTransformMatrix(start, relativeTo: nil)
        root.move(to: rest, relativeTo: nil, duration: 1.6, timingFunction: .easeInOut)
    }

    private(set) var yaw: Float = 0
    private(set) var eyeHeight: Float = 1.2
    private(set) var seatPosition: SIMD3<Float> = .zero

    /// Puts the driver's seat at `position` on the floor, facing `yaw`
    /// (radians about Y; 0 faces -Z), with their eyes at `eyeHeight`. A designed
    /// cab stands on the floor, so only the placeholder (which floats at eye
    /// level on a pedestal) follows the eye height.
    func place(at position: SIMD3<Float>, yaw: Float, eyeHeight: Float) {
        self.yaw = yaw
        self.eyeHeight = eyeHeight
        seatPosition = [position.x, 0, position.z]
        root.position = seatPosition
        root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        rig.position = isCustom ? [-eyePoint.x, 0, -eyePoint.z] : [0, eyeHeight, 0] - eyePoint

        // The placeholder's pedestal reaches the floor whatever the eye height.
        if let base {
            let top: Float = -0.47 // below the dash, eye-relative
            let height = max(0.1, eyeHeight + top)
            base.scale = [1, height, 1]
            base.position = [0, top - height / 2, -0.75]
        }

        environment.position = [0, 0, 0]
    }

    // MARK: Live state

    /// Turns the wheel: positive is clockwise as the driver sees it.
    func setWheelAngle(_ radians: Float) {
        wheel.orientation = wheelBaseOrientation * simd_quatf(angle: -radians, axis: [0, 0, 1])
    }

    /// Presses the pedals (0 up .. 1 floored), easing towards the new positions.
    func setPedals(gas: Float, brake: Float) {
        for (i, target) in [gas, brake].enumerated() where i < pedals.count {
            let t = max(0, min(1, target))
            pedals[i].travel += (t - pedals[i].travel) * 0.35
            let press = simd_quatf(angle: -Self.pedalTravel * pedals[i].travel, axis: [1, 0, 0])
            pedals[i].pivot.orientation = pedals[i].rest * press
        }
    }

    /// Lights the lamp buttons the game has on (DT_LAMP_* bits) and darkens
    /// the rest. Materials are only touched when a lamp changes.
    func setLamps(_ bits: UInt32) {
        guard bits != lampBits else { return }
        let changed = bits ^ (lampBits ?? ~bits)
        lampBits = bits
        for i in lamps.indices where changed & lamps[i].bit != 0 {
            let on = bits & lamps[i].bit != 0
            lamps[i].material.emissiveColor = .init(color: lamps[i].color)
            lamps[i].material.emissiveIntensity = on ? Self.lampOn : Self.lampOff
            lamps[i].cap.model?.materials = [lamps[i].material]
        }
    }

    /// Lamp glow lit, and unlit (the cap's colour just showing through).
    private static let lampOn: Float = 2.5
    private static let lampOff: Float = 0.04

    private func bindLamps() {
        let bits: [(String, Int)] = [("start", Int(DT_LAMP_START)), ("view1", Int(DT_LAMP_VIEW1)),
                                     ("view2", Int(DT_LAMP_VIEW2)), ("view3", Int(DT_LAMP_VIEW3)),
                                     ("view4", Int(DT_LAMP_VIEW4))]
        var caps: [String: ModelEntity] = [:]
        rig.visit { entity in
            // the cap is the button's mesh (not its housing, whose name doesn't parse)
            if let id = Self.buttonID(entity.name), caps[id] == nil,
               let cap = entity as? ModelEntity ?? entity.children.compactMap({ $0 as? ModelEntity }).first,
               cap.model != nil {
                caps[id] = cap
            }
        }
        for (id, bit) in bits {
            guard let cap = caps[id], let material = cap.model?.materials.first as? PhysicallyBasedMaterial else { continue }
            lamps.append((UInt32(bit), cap, material, material.baseColor.tint))
        }
    }

    /// How far a floored pedal turns about its hinge.
    private static let pedalTravel: Float = 18 * .pi / 180

    func setGear(_ gear: Int32) {
        if let lever = shifterLever {
            // H pattern: 1 and 3 away from the driver (+Y), 1 and 2 to the left (-X).
            let away: Float = gear % 2 == 1 ? -0.4 : 0.4
            let side: Float = gear <= 2 ? -0.25 : 0.25
            lever.orientation = shifterLeverRest * simd_quatf(angle: away, axis: [1, 0, 0])
                * simd_quatf(angle: side, axis: [0, 1, 0])
            return
        }

        guard let knob = shifterKnob else { return }

        // H pattern: 1 up-left, 2 down-left, 3 up-right, 4 down-right.
        let x: Float = gear <= 2 ? -0.035 : 0.035
        let z: Float = gear % 2 == 1 ? -0.04 : 0.04
        knob.position = shifterRest + [x, 0, z]
    }

    /// A hand position in the wheel's own frame (unrotated): x right, y up
    /// across the wheel's face, z towards the driver.
    func wheelLocal(_ world: SIMD3<Float>) -> SIMD3<Float> {
        guard let column = wheel.parent else { return world }
        let p = column.convert(position: world, from: nil) - wheel.position
        return wheelBaseOrientation.inverse.act(p)
    }

    /// The tube: the picture on the phosphor (unlit: it emits its own light),
    /// and in front of it a thin glossy glass shell of the same shape that
    /// catches reflections of the room.
    func setScreenMaterial(_ texture: TextureResource) {
        var phosphor = UnlitMaterial()
        phosphor.color = .init(tint: .white, texture: .init(texture))
        setScreenMaterial(phosphor)
    }

    /// Any material for the picture (the stereo one, StereoScreen.usda), under the glass.
    func setScreenMaterial(_ material: any RealityKit.Material) {
        screen.model?.materials = [material]

        guard let mesh = screen.model?.mesh, glassShell == nil else { return }
        let shell = ModelEntity(mesh: mesh, materials: [Self.glass(opacity: glassOpacity)])
        shell.name = "ScreenGlass"
        shell.position = [0, 0, 0.0015] // the screen's local +Z faces the driver
        screen.addChild(shell)
        glassShell = shell
    }

    /// How strongly the screen's glass shows reflections (its opacity).
    func setGlassOpacity(_ opacity: Float) {
        guard opacity != glassOpacity else { return }
        glassOpacity = opacity
        glassShell?.model?.materials = [Self.glass(opacity: opacity)]
        glassShell?.isEnabled = opacity > 0.001
    }

    private var glassShell: ModelEntity?
    private var glassOpacity: Float = 0.12

    private static func glass(opacity: Float) -> PhysicallyBasedMaterial {
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .black)
        glass.roughness = 0.04
        glass.metallic = 0.0
        glass.specular = 0.6
        glass.clearcoat = 1.0
        glass.clearcoatRoughness = 0.02
        glass.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return glass
    }

    // MARK: Grip feedback

    /// The rim's cross-section: semi-axes across the wheel's face and along
    /// the column (Wheel_RimProfile in a designed cab).
    private var rimRadial: Float = 0.017
    private var rimAxial: Float = 0.017

    /// Shows where each hand (0 left, 1 right) is on the rim: `angle` around
    /// the hub in the wheel's unrotated frame, `reach` 0 (far) to 1 (on the
    /// rim), and whether it is holding.
    func setGrip(hand: Int, angle: Float?, reach: Float, holding: Bool, dt: Float) {
        guard hand < gripGlows.count else { return }

        let glow = gripGlows[hand]
        if let angle {
            glow.orientation = wheelBaseOrientation * simd_quatf(angle: angle, axis: [0, 0, 1])
        }

        let target: Float = angle == nil ? 0 : (holding ? 0.6 : 0.3 * reach)
        let current = glow.components[OpacityComponent.self]?.opacity ?? 0
        let opacity = current + (target - current) * min(1, dt * 14)
        glow.components.set(OpacityComponent(opacity: opacity))
        glow.isEnabled = opacity > 0.01
    }

    private var gripGlows: [Entity] = []

    /// For each hand, a white wash over a stretch of the rim: a skin hugging
    /// the rim's own cross-section, under a millimetre proud of it, whose
    /// opacity texture fades out toward both ends and is strongest on the side
    /// facing the driver. It sits under the column, so it follows the hand,
    /// not the wheel's turn.
    private func buildGripGlows() {
        guard let column = wheel.parent else { return }

        var material = UnlitMaterial(color: .white)
        if let fade = Self.gripFade() {
            material.blending = .transparent(opacity: .init(scale: 1.0, texture: .init(fade)))
        } else {
            material.blending = .transparent(opacity: 0.5)
        }

        let mesh = Self.rimSkin(
            radius: wheelRadius,
            radial: rimRadial + 0.0008,
            axial: rimAxial + 0.0008,
            span: 0.9
        )
        for _ in 0..<2 {
            let glow = ModelEntity(mesh: mesh, materials: [material])
            glow.position = wheel.position
            glow.components.set(OpacityComponent(opacity: 0))
            glow.isEnabled = false
            column.addChild(glow)
            gripGlows.append(glow)
        }
    }

    /// A stretch of elliptical torus in the XY plane around the origin, centred
    /// on +X, `span` radians long. UV u runs along it, v around the tube
    /// (0 the outside edge, 0.25 facing the driver).
    private static func rimSkin(radius: Float, radial: Float, axial: Float, span: Float) -> MeshResource {
        let along = 32, around = 16
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for i in 0...along {
            let u = Float(i) / Float(along)
            let a = (u - 0.5) * span
            let out = SIMD3<Float>(cos(a), sin(a), 0)
            for j in 0...around {
                let v = Float(j) / Float(around)
                let b = v * 2 * .pi
                positions.append(out * (radius + radial * cos(b)) + SIMD3<Float>(0, 0, axial * sin(b)))
                normals.append(simd_normalize(out * (cos(b) / radial) + SIMD3<Float>(0, 0, sin(b) / axial)))
                uvs.append([u, v])
            }
        }

        let row = UInt32(around + 1)
        for i in 0..<UInt32(along) {
            for j in 0..<UInt32(around) {
                let a = i * row + j, b = a + 1, c = a + row, d = c + 1
                indices += [a, c, b, b, c, d] // counter-clockwise seen from outside
            }
        }

        var descriptor = MeshDescriptor(name: "GripGlow")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: radial)
    }

    /// The glow's opacity: a smooth bump along the rim (zero at both ends),
    /// brightest on the side facing the driver, dimmer behind.
    private static func gripFade() -> TextureResource? {
        let w = 128, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h)

        for y in 0..<h {
            // Image rows run top down; texture v runs bottom up.
            let b = (1 - (Float(y) + 0.5) / Float(h)) * 2 * .pi
            let facing = 0.4 + 0.6 * max(0, sin(b)) // v = 0.25: toward the driver
            for x in 0..<w {
                let t = (Float(x) + 0.5) / Float(w)
                let along = pow(sin(.pi * t), 2) // 0 at the ends, 1 in the middle
                pixels[y * w + x] = UInt8(max(0, min(255, along * facing * 255)))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        return try? TextureResource(image: image, options: .init(semantic: .raw))
    }

    // MARK: Placing

    /// The cab's extent in the rig's frame, for the placing footprint.
    private var footprint = BoundingBox()

    /// Shown on the floor around the cab while placing: a ring around the
    /// footprint, its thick stroke broken into quadrants with the front one lit.
    /// Drag inside the ring to move it, drag the ring to turn it; the cab follows
    /// as it goes. Add it to the scene beside `root`. Its origin is the driver (as the root's); the ring
    /// turns about its own centre, the footprint's middle.
    let placer = Entity()

    private(set) var placerYaw: Float = 0

    static let placerBodyName = "PlacerBody", placerTurnName = "PlacerTurn"

    var isPlacing: Bool { placer.isEnabled }

    func beginPlacing() {
        placer.position = seatPosition // where the cab rests, not where an animation has it
        placer.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        placerYaw = yaw
        placer.isEnabled = true
    }

    func endPlacing() { placer.isEnabled = false }

    func movePlacer(to position: SIMD3<Float>) {
        placer.position = [position.x, 0, position.z]
        followPlacer()
    }

    private func followPlacer() { place(at: placer.position, yaw: placerYaw, eyeHeight: eyeHeight) }

    /// The ring's centre on the floor, in the scene.
    var placerCentre: SIMD3<Float> {
        placer.position + simd_quatf(angle: placerYaw, axis: [0, 1, 0]).act(placerCentreLocal)
    }

    /// Turns the placer about the ring's centre, which stays put.
    func setPlacerYaw(_ yaw: Float) {
        let centre = placerCentre
        placerYaw = yaw

        let turn = simd_quatf(angle: yaw, axis: [0, 1, 0])
        placer.orientation = turn
        placer.position = centre - turn.act(placerCentreLocal)
        followPlacer()
    }

    /// Footprint corners in the root's frame: the rig's extent, shifted to
    /// where the rig sits (its x/z offset from the driver's eye point).
    private var footprintRect: (min: SIMD2<Float>, max: SIMD2<Float>) {
        let shift = SIMD2<Float>(-eyePoint.x, -eyePoint.z)
        return (
            SIMD2(footprint.min.x, footprint.min.z) + shift,
            SIMD2(footprint.max.x, footprint.max.z) + shift
        )
    }

    var placerCentreLocal: SIMD3<Float> {
        let (lo, hi) = footprintRect
        let c = (lo + hi) / 2
        return [c.x, 0, c.y]
    }

    private func buildPlacer() {
        placer.name = "Placer"
        placer.isEnabled = false

        let (lo, hi) = footprintRect
        let size = hi - lo

        let ring = Entity()
        ring.position = placerCentreLocal
        placer.addChild(ring)

        let blue = UIColor(red: 0.45, green: 0.8, blue: 1, alpha: 1)
        var dim = UnlitMaterial(color: blue)
        dim.blending = .transparent(opacity: 0.55)
        let lit = UnlitMaterial(color: .white)
        var fill = UnlitMaterial(color: blue)
        fill.blending = .transparent(opacity: 0.1)

        // The ring clears the footprint's corners.
        let stroke: Float = 0.09
        let inner = simd_length(size) / 2 + 0.08, outer = inner + stroke

        // Inside the ring: a faint disc, grabbed to move.
        let disc = ModelEntity(
            mesh: Self.arcMesh(inner: 0, outer: inner, from: 0, to: 2 * .pi),
            materials: [fill]
        )
        disc.name = Self.placerBodyName
        disc.position.y = 0.002
        disc.components.set(InputTargetComponent())
        disc.components.set(HoverEffectComponent())
        disc.components.set(CollisionComponent(shapes: [.generateBox(size: [inner * 1.4, 0.06, inner * 1.4])]))
        ring.addChild(disc)

        // The ring: four quadrants with gaps between them. The one lit is the
        // cab's front, the driver's side (+Z), where the player walks up to it.
        // Angles run from -Z towards -X, as the yaw does.
        let turn = Entity()
        turn.name = Self.placerTurnName
        turn.components.set(InputTargetComponent())
        turn.components.set(HoverEffectComponent())

        let gap: Float = 0.07
        for q in 0..<4 {
            let mid = Float(q) * .pi / 2
            let mesh = Self.arcMesh(inner: inner, outer: outer, from: mid - .pi / 4 + gap, to: mid + .pi / 4 - gap)
            let arc = ModelEntity(mesh: mesh, materials: [q == 2 ? lit : dim])
            arc.position.y = 0.005
            turn.addChild(arc)
        }

        // Collision: short boxes laid round the ring, taller than the stroke so a
        // glance at it from standing height lands.
        let segments = 36, r = (inner + outer) / 2
        turn.components.set(CollisionComponent(shapes: (0..<segments).map { i in
            let a = Float(i) / Float(segments) * 2 * .pi
            return ShapeResource.generateBox(size: [2 * .pi * r / Float(segments) * 1.1, 0.1, stroke + 0.06])
                .offsetBy(
                    rotation: simd_quatf(angle: a, axis: [0, 1, 0]),
                    translation: [-r * sin(a), 0.05, -r * cos(a)]
                )
        }))
        ring.addChild(turn)
    }

    /// A flat annulus sector on the floor (facing up), from angle `from` to `to`
    /// (radians from -Z towards -X).
    private static func arcMesh(inner: Float, outer: Float, from: Float, to: Float) -> MeshResource {
        let steps = max(4, Int((to - from) / (2 * .pi) * 96))
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []

        for i in 0...steps {
            let a = from + (to - from) * Float(i) / Float(steps)
            let d = SIMD3<Float>(-sin(a), 0, -cos(a))
            positions += [d * inner, d * outer]
        }

        for i in 0..<UInt32(steps) {
            let k = i * 2 // inner, outer, next inner, next outer; wound counter-clockwise from above
            indices += [k, k + 1, k + 3, k, k + 3, k + 2]
        }

        var desc = MeshDescriptor(name: "arc")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(Array(repeating: [0, 1, 0], count: positions.count))
        desc.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [desc])) ?? .generatePlane(width: 0.01, depth: 0.01)
    }

    // MARK: Custom cab

    private static func loadCustom() async -> Entity? {
        if let url = Bundle.main.url(forResource: "Cab", withExtension: "usdz"),
           let entity = try? await Entity(contentsOf: url) {
            return entity
        }
        return nil
    }

    private func bind(_ model: Entity) {
        func find(_ name: String) -> Entity? { model.findEntity(named: name) }
        if let eye = find("EyePoint") { eyePoint = eye.position(relativeTo: model) }

        let screenEntity = find("Screen") ?? find("CRT_Screen")
        if let s = screenEntity as? ModelEntity ?? screenEntity?.children.compactMap({ $0 as? ModelEntity }).first {
            screen = s
        } else {
            screen = makeScreen()
            rig.addChild(screen)
        }

        if let w = find("Wheel") {
            wheel = w
            wheelBaseOrientation = w.orientation
            if let profile = find("Wheel_RimProfile") {
                // Its position in the column's frame is the rim's shape (export_usdz.py).
                wheelRadius = profile.position.x
                rimRadial = profile.position.y
                rimAxial = profile.position.z
            } else {
                let bounds = w.visualBounds(relativeTo: w)
                wheelRadius = max(bounds.extents.x, bounds.extents.y) / 2 * 0.92
            }
        } else {
            buildWheel()
        }

        speakerL = find("SpeakerL") ?? screen
        speakerR = find("SpeakerR") ?? screen

        if let lever = find("ShifterLever") {
            shifterLever = lever
            shifterLeverRest = lever.orientation
        } else if let knob = find("ShifterKnob") {
            shifterKnob = knob
            shifterRest = knob.position
        }

        pedals = ["PedalPivot_Gas", "PedalPivot_Brake"].compactMap { name in
            find(name).map { ($0, $0.orientation, 0) }
        }

        model.visit { entity in
            if Self.buttonID(entity.name) != nil { Self.makeTappable(entity) }
        }
    }

    // MARK: Placeholder cab (eye-relative: eyes at the rig origin, facing -Z)

    private func buildPlaceholder() {
        let blue = Self.paint(UIColor(red: 0.05, green: 0.16, blue: 0.55, alpha: 1), roughness: 0.35, metallic: 0.2)
        let darkBlue = Self.paint(UIColor(red: 0.03, green: 0.07, blue: 0.22, alpha: 1), roughness: 0.6)
        let black = Self.paint(UIColor(white: 0.04, alpha: 1), roughness: 0.8)
        let red = Self.paint(UIColor(red: 0.85, green: 0.08, blue: 0.06, alpha: 1), roughness: 0.3)
        let yellow = Self.paint(UIColor(red: 1.0, green: 0.78, blue: 0.05, alpha: 1), roughness: 0.3)

        // Monitor: screen, bezel and housing, tilted back slightly.
        let monitor = Entity()
        monitor.position = [0, -0.10, -1.05]
        monitor.orientation = simd_quatf(angle: -0.12, axis: [1, 0, 0])
        rig.addChild(monitor)
        screen = makeScreen()
        monitor.addChild(screen)
        monitor.addChild(Self.box([0.86, 0.68, 0.03], black, at: [0, 0, -0.02]))
        monitor.addChild(Self.box([1.0, 0.86, 0.7], darkBlue, at: [0, 0, -0.38]))

        // Side panels from the floor up to the marquee.
        for side: Float in [-1, 1] {
            let panel = Self.box([0.06, 2.6, 1.15], blue, at: [side * 0.53, -0.7, -0.92])
            rig.addChild(panel)
            rig.addChild(Self.box([0.065, 0.05, 1.16], yellow, at: [side * 0.53, 0.0, -0.92]))
            rig.addChild(Self.box([0.065, 0.05, 1.16], red, at: [side * 0.53, -0.07, -0.92]))
        }

        // Marquee with its sign.
        let marquee = Self.box([1.12, 0.26, 0.4], blue, at: [0, 0.42, -1.0])
        rig.addChild(marquee)
        rig.addChild(Self.box([1.0, 0.2, 0.02], black, at: [0, 0.42, -0.795]))
        rig.addChild(Self.sign(
            "DAYTONA USA",
            height: 0.075,
            color: UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1),
            at: [0, 0.385, -0.78]
        ))

        // Speakers either side of the marquee.
        speakerL = Self.grille(at: [-0.45, 0.42, -0.78], material: black)
        speakerR = Self.grille(at: [0.45, 0.42, -0.78], material: black)
        rig.addChild(speakerL)
        rig.addChild(speakerR)

        // Dash, wheel and column.
        let dash = Self.box([0.96, 0.1, 0.5], darkBlue, at: [0, -0.43, -0.68])
        dash.orientation = simd_quatf(angle: 0.18, axis: [1, 0, 0])
        rig.addChild(dash)
        rig.addChild(Self.box([0.96, 0.02, 0.02], yellow, at: [0, -0.375, -0.43]))
        buildWheel()

        // Pedestal under the dash, sized to the floor on placement.
        let base = Self.box([0.96, 1, 0.55], blue, at: [0, -1, -0.75])
        rig.addChild(base)
        self.base = base

        // Arcade buttons on the dash: START and the four VIEW buttons.
        let buttons: [(String, UIColor, SIMD3<Float>)] = [
            ("view1", .systemRed, [-0.39, -0.36, -0.5]), ("view2", .systemBlue, [-0.32, -0.36, -0.5]),
            ("view3", .systemYellow, [-0.25, -0.36, -0.5]), ("view4", .systemGreen, [-0.18, -0.36, -0.5]),
            ("start", UIColor(red: 1, green: 0.2, blue: 0.1, alpha: 1), [0.3, -0.36, -0.5]),
        ]

        for (name, color, position) in buttons {
            let button = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.022),
                                     materials: [Self.glow(color)])
            button.name = "Button_\(name)"
            button.position = position
            button.orientation = simd_quatf(angle: 0.18, axis: [1, 0, 0])
            Self.makeTappable(button)
            rig.addChild(button)
        }

        rig.addChild(Self.sign("START", height: 0.018, color: .white, at: [0.3, -0.345, -0.47]))
        rig.addChild(Self.sign("VIEW", height: 0.018, color: .white, at: [-0.285, -0.345, -0.47]))

        // Coin slot on the pedestal front.
        let coin = ModelEntity(mesh: .generateBox(size: [0.08, 0.1, 0.02], cornerRadius: 0.01),
                               materials: [Self.glow(UIColor(red: 1, green: 0.5, blue: 0.1, alpha: 1))])
        coin.name = "Button_coin"
        coin.position = [-0.33, -0.62, -0.47]
        Self.makeTappable(coin)
        rig.addChild(coin)
        rig.addChild(Self.sign("COIN", height: 0.018, color: .white, at: [-0.33, -0.55, -0.465]))

        // Four-speed shifter to the right of the wheel.
        let gate = Self.box([0.12, 0.012, 0.14], black, at: [0.36, -0.48, -0.36])
        rig.addChild(gate)

        let knob = ModelEntity(mesh: .generateSphere(radius: 0.028), materials: [Self.paint(.black, roughness: 0.2)])
        let stick = ModelEntity(mesh: .generateCylinder(height: 0.12, radius: 0.007),
                                materials: [Self.paint(.gray, roughness: 0.3, metallic: 1)])
        stick.position = [0, -0.06, 0]
        knob.addChild(stick)

        shifterRest = [0.36, -0.40, -0.36]
        knob.position = shifterRest
        knob.name = "ShifterKnob"
        rig.addChild(knob)
        shifterKnob = knob
    }

    private func buildWheel() {
        let column = Entity()
        column.name = "WheelColumn"
        column.position = [0, -0.36, -0.42]
        rig.addChild(column)

        let w = Entity()
        w.name = "Wheel"
        // The face tilted back, top away from the driver.
        wheelBaseOrientation = simd_quatf(angle: -0.45, axis: [1, 0, 0])
        w.orientation = wheelBaseOrientation
        column.addChild(w)

        let rim = Self.paint(UIColor(white: 0.08, alpha: 1), roughness: 0.7)
        let metal = Self.paint(UIColor(white: 0.55, alpha: 1), roughness: 0.25, metallic: 1)
        let r = wheelRadius
        let segments = 36
        let length = 2 * .pi * r / Float(segments) * 1.08
        let segmentMesh = MeshResource.generateCylinder(height: length, radius: 0.017)

        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            let seg = ModelEntity(mesh: segmentMesh, materials: [rim])
            seg.position = [r * cos(a), r * sin(a), 0]
            seg.orientation = simd_quatf(angle: a, axis: [0, 0, 1])
            w.addChild(seg)
        }

        // Three spokes (left, right, bottom) and the hub.
        for a: Float in [0, .pi, -.pi / 2] {
            let spoke = ModelEntity(
                mesh: .generateBox(size: [r, 0.035, 0.012], cornerRadius: 0.005),
                materials: [metal]
            )
            spoke.position = [r / 2 * cos(a), r / 2 * sin(a), 0]
            spoke.orientation = simd_quatf(angle: a, axis: [0, 0, 1])
            w.addChild(spoke)
        }

        let hub = ModelEntity(mesh: .generateCylinder(height: 0.035, radius: 0.05),
                              materials: [Self.glow(UIColor(red: 0.9, green: 0.1, blue: 0.08, alpha: 1))])
        hub.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        w.addChild(hub)

        // A marker at the top of the rim shows the wheel's turn.
        let marker = ModelEntity(mesh: .generateBox(size: [0.02, 0.04, 0.038]),
                                 materials: [Self.glow(.systemYellow)])
        marker.position = [0, r, 0]
        w.addChild(marker)

        // The column into the dash.
        let shaft = ModelEntity(mesh: .generateCylinder(height: 0.25, radius: 0.025), materials: [metal])
        shaft.orientation = wheelBaseOrientation * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        shaft.position = wheelBaseOrientation.act([0, 0, -0.13])
        column.addChild(shaft)

        wheel = w
    }

    private func makeScreen() -> ModelEntity {
        let s = ModelEntity(mesh: .generatePlane(width: Self.screenSize.x, height: Self.screenSize.y),
                            materials: [UnlitMaterial(color: .black)])
        s.name = "Screen"
        return s
    }

    // MARK: Full immersion surroundings

    /// The arcade room (full immersion): black all round, a carpet floor
    /// centred on the cab, lit by the room's neon and fading to black, and the
    /// neon rings, bulbs and tokens around it (ArcadeRoom.usdz and the floor's
    /// textures, from model/build_room.sh; the floor's material is
    /// ArcadeFloor.usda). Without those, a grey floor that fades to black, as
    /// vision-emulator's dark room. The cab casts a soft contact shadow on it.
    private func buildEnvironment() async {
        environment.name = "Environment"
        var sky = UnlitMaterial(color: .black)
        sky.faceCulling = .front
        environment.addChild(ModelEntity(mesh: .generateSphere(radius: 40), materials: [sky]))

        let floor: ModelEntity
        if let room = await Self.loadRoom() {
            room.scene.position = placerCentreLocal
            environment.addChild(room.scene)
            roomScene = room.scene
            floor = room.floor
            bindRoom(room.scene)
        } else {
            floor = Self.greyFloor()
        }
        floor.position = placerCentreLocal // centred on the cab
        floor.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: true))
        environment.addChild(floor)

        // Shadows on the floor and the room only: between its own parts the cab
        // has its baked ambient occlusion (a grounding shadow from above would
        // darken the dash under the monitor).
        rig.visit { entity in
            if entity is ModelEntity {
                entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: false))
            }
        }

        environment.isEnabled = false
    }

    private var roomScene: Entity?
    private var roomBulbs: [Entity] = []
    private var roomTokens: [(token: Entity, spin: Float)] = []
    private var roomTime: Float = 0

    /// The two halves of the bulb ring slowly fade up and down in turn: a
    /// whole cycle's seconds, and how dim a half gets.
    private static let bulbFadePeriod: Float = 6
    private static let bulbFadeLow: Float = 0.02
    /// How fast the tokens turn, radians a second.
    private static let tokenSpin: Float = 0.7

    /// The room and its floor, if its resources load.
    private static func loadRoom() async -> (scene: Entity, floor: ModelEntity)? {
        guard let roomURL = Bundle.main.url(forResource: "ArcadeRoom", withExtension: "usdz"),
              let carpetURL = Bundle.main.url(forResource: "ArcadeCarpet", withExtension: "png"),
              let lightURL = Bundle.main.url(forResource: "ArcadeFloorLight", withExtension: "png"),
              let scene = try? await Entity(contentsOf: roomURL),
              var material = try? await ShaderGraphMaterial(
                  named: "/Root/ArcadeFloor", from: "ArcadeFloor.usda", in: Bundle.main),
              // Mipmapped: the carpet's fine pattern would shimmer in the distance.
              let carpet = try? await TextureResource(
                  contentsOf: carpetURL, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)),
              let light = try? await TextureResource(contentsOf: lightURL, options: .init(semantic: .raw))
        else { return nil }

        // FloorSpec's position is the floor's size: x its radius, y a carpet tile's width.
        let spec = scene.findEntity(named: "FloorSpec")?.position(relativeTo: scene) ?? [9, 2, 0]
        let radius = spec.x, tile = max(spec.y, 0.1)
        do {
            try material.setParameter(name: "Carpet", value: .textureResource(carpet))
            try material.setParameter(name: "Light", value: .textureResource(light))
            try material.setParameter(name: "Tiles", value: .float(radius * 2 / tile))
        } catch {
            return nil
        }

        let floor = ModelEntity(mesh: .generatePlane(width: radius * 2, depth: radius * 2), materials: [material])
        floor.name = "ArcadeFloor"
        return (scene, floor)
    }

    /// Finds what the room animates: the bulb ring's halves and the tokens
    /// (each `Token_<n>`, holding its rim and stars). Each half's bulbs are
    /// drawn as glowing sprites at their `Bulb_<half>_<n>` spots, in place of
    /// the little spheres (which, far off, show their facets): every mesh under
    /// a half is hidden (the export nests the spheres' mesh inside it).
    private func bindRoom(_ scene: Entity) {
        roomBulbs = ["Bulbs_A", "Bulbs_B"].compactMap { scene.findEntity(named: $0) }
        if let glow = Self.bulbGlow() {
            let sprite = MeshResource.generatePlane(width: Self.bulbGlowSize, height: Self.bulbGlowSize)
            for bulbs in roomBulbs {
                var spots: [Entity] = []
                bulbs.visit { if $0.name.hasPrefix("Bulb_") { spots.append($0) } }
                guard !spots.isEmpty else { continue }
                bulbs.visit { $0.components.remove(ModelComponent.self) }
                bulbs.components.set(OpacityComponent(opacity: 1)) // faded in animateRoom
                for spot in spots {
                    let glowing = ModelEntity(mesh: sprite, materials: [glow])
                    glowing.components.set(BillboardComponent()) // always facing the viewer: round
                    spot.addChild(glowing)
                }
            }
        }
        var seen = Set<String>()
        scene.visit { entity in
            let name = entity.name
            guard name.hasPrefix("Token_"), Int(name.dropFirst("Token_".count)) != nil,
                  seen.insert(name).inserted // the outermost of a name: the mesh sits inside its Xform
            else { return }
            roomTokens.append((entity, roomTokens.count % 2 == 0 ? Self.tokenSpin : -Self.tokenSpin))
        }
    }

    /// A bulb's sprite, across (metres): the hot core is about a fifth of it.
    private static let bulbGlowSize: Float = 0.4

    /// A bulb seen across the dark room: a small hot core, a faint halo and a
    /// barely-there starburst round it (the glare a bright point makes in the eye),
    /// warm white, fading to nothing at the sprite's edge. Unlit, blended.
    private static func bulbGlow() -> UnlitMaterial? {
        let n = 128
        let warm = SIMD3<Float>(1.0, 0.8, 0.48), hot = SIMD3<Float>(1.0, 0.97, 0.9)
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let u = (Float(x) + 0.5) / Float(n) * 2 - 1, v = (Float(y) + 0.5) / Float(n) * 2 - 1
                let r = (u * u + v * v).squareRoot()
                let core = max(0, min(1, (0.16 - r) / 0.04))
                let halo = 0.22 * exp(-r * r / (2 * 0.2 * 0.2))
                let rays = 0.06 * (exp(-abs(u) / 0.01) + exp(-abs(v) / 0.01)) * max(0, 1 - r)
                let edge = max(0, min(1, (1 - r) / 0.25))
                let alpha = min(1, core + halo + rays) * edge
                let colour = warm + (hot - warm) * core
                let i = (y * n + x) * 4
                pixels[i] = UInt8(colour.x * 255)
                pixels[i + 1] = UInt8(colour.y * 255)
                pixels[i + 2] = UInt8(colour.z * 255)
                pixels[i + 3] = UInt8(alpha * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        else { return nil }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }

    /// Runs the room while it shows: the bulbs fade in turn, the tokens turn.
    func animateRoom(dt: Float) {
        guard environment.isEnabled, let roomScene else { return }
        roomTime += dt

        // 0..1..0 over a cycle, eased; the second half the other way round
        let wave = 0.5 - 0.5 * cos(2 * .pi * roomTime / Self.bulbFadePeriod)
        for (i, bulbs) in roomBulbs.enumerated() {
            let up = i == 0 ? wave : 1 - wave
            bulbs.components.set(OpacityComponent(opacity: Self.bulbFadeLow + (1 - Self.bulbFadeLow) * up))
        }

        for (token, spin) in roomTokens {
            let turn = simd_quatf(angle: spin * dt, axis: [0, 1, 0])
            token.setOrientation(turn * token.orientation(relativeTo: roomScene), relativeTo: roomScene)
        }
    }

    private static func greyFloor() -> ModelEntity {
        let extent = floorFullRadius + floorFadeDistance

        // Unlit, as vision-emulator's room floor: lit, it would pick up the
        // surroundings' reflections and never reach the sky's black.
        var floorMaterial = UnlitMaterial()
        if let fade = floorFade() {
            floorMaterial.color = .init(tint: .white, texture: .init(fade))
        } else {
            floorMaterial.color = .init(tint: UIColor(white: CGFloat(floorGrey), alpha: 1))
        }

        return ModelEntity(
            mesh: .generatePlane(width: extent * 2, depth: extent * 2),
            materials: [floorMaterial]
        )
    }

    /// The grey floor's grey, fully there out to `floorFullRadius` from the cab and
    /// gone to black `floorFadeDistance` further out.
    private static let floorGrey: Float = 0.02 // linear: very dark (unlit, it shows as it is)
    private static let floorFullRadius: Float = 2.2
    private static let floorFadeDistance: Float = 4.4

    private static func floorFade() -> TextureResource? {
        let n = 512
        let extent = floorFullRadius + floorFadeDistance
        var pixels = [UInt8](repeating: 0, count: n * n)

        for y in 0..<n {
            for x in 0..<n {
                let u = (Float(x) + 0.5) / Float(n) * 2 - 1, v = (Float(y) + 0.5) / Float(n) * 2 - 1
                let r = simd_length(SIMD2(u, v)) * extent
                let t = max(0, min(1, (r - floorFullRadius) / floorFadeDistance))
                let k = 1 - t * t * (3 - 2 * t)
                // sRGB-encoded grey, so the fade is even to the eye.
                pixels[y * n + x] = UInt8(max(0, min(255, pow(floorGrey * k, 1 / 2.2) * 255)))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        return try? TextureResource(image: image, options: .init(semantic: .color))
    }

    // MARK: Helpers

    /// The arcade button an entity stands for, from its name: `Button_<name>`
    /// (or `Button.<name>`), any case, and the coin door's parts.
    static func buttonID(_ name: String) -> String? {
        let n = name.lowercased()
        if n == "coindoor" || n.hasPrefix("coinentry") { return "coin" }

        for prefix in ["button_", "button."] where n.hasPrefix(prefix) {
            let id = String(n.dropFirst(prefix.count))
            return ["start", "coin", "view1", "view2", "view3", "view4", "test", "service"].contains(id) ? id : nil
        }

        return nil
    }

    /// The part that moves when a button is pressed: for the coin door, the
    /// coin entry's lit insert (CoinEntry_<n>), not the bezel or door that was
    /// tapped; the first entry when the door itself was. Otherwise the button.
    func pressedPart(for button: Entity) -> Entity {
        let n = button.name.lowercased()
        let entry: String
        if n.hasPrefix("coinentry_") {
            entry = String(n.dropFirst("coinentry_".count).prefix { $0.isNumber })
        } else if n == "coindoor" {
            entry = "1"
        } else {
            return button
        }
        return rig.findEntity(named: "CoinEntry_\(entry)") ?? button
    }

    static func makeTappable(_ entity: Entity, hover: Bool = true) {
        entity.components.set(InputTargetComponent())
        if hover { entity.components.set(HoverEffectComponent()) }

        if !entity.components.has(CollisionComponent.self) { entity.generateCollisionShapes(recursive: true) }
        if !entity.components.has(CollisionComponent.self) {
            let b = entity.visualBounds(relativeTo: entity)
            let box = ShapeResource.generateBox(size: b.extents).offsetBy(translation: b.center)
            entity.components.set(CollisionComponent(shapes: [box]))
        }
    }

    private static func paint(_ color: UIColor, roughness: Float, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        return m
    }

    private static func glow(_ color: UIColor) -> PhysicallyBasedMaterial {
        var m = paint(color, roughness: 0.3)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = 0.6
        return m
    }

    private static func box(_ size: SIMD3<Float>, _ material: some Material, at position: SIMD3<Float>) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.008), materials: [material])
        e.position = position
        return e
    }

    private static func grille(at position: SIMD3<Float>, material: some Material) -> ModelEntity {
        let e = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.06), materials: [material])
        e.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        e.position = position
        return e
    }

    private static func sign(_ text: String, height: Float, color: UIColor, at position: SIMD3<Float>) -> ModelEntity {
        let mesh = MeshResource.generateText(text, extrusionDepth: height * 0.1,
                                             font: .systemFont(ofSize: CGFloat(height), weight: .heavy))
        let e = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let b = mesh.bounds
        e.position = position - [b.center.x, b.center.y, 0]
        return e
    }
}

private extension Entity {
    func visit(_ body: (Entity) -> Void) {
        body(self)
        for child in children { child.visit(body) }
    }
}
