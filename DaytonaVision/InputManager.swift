import ARKit
import GameController
import QuartzCore
import simd

/// Turns hands and game controllers into the arcade's controls each frame.
///
/// Hands: grab the wheel's rim (a hand within reach of it) and turn. With both
/// hands the wheel follows the line between them; with one, the hand's angle
/// around the hub (frame by frame, see `steerWithHands`). Let go and the wheel
/// springs back to centre. Gas and brake are pinches, the thumb to a finger,
/// by default the right index finger for gas and the left for brake (each
/// pedal's hand and finger can be set): all or nothing (Constant), or (Variable) the
/// closer the fingers, the more pedal.
///
/// Controller: left stick steers, right/left trigger gas/brake, shoulders or
/// D-pad up/down shift, A B X Y the four view buttons, Menu start, Options coin.
@MainActor
final class InputManager {
    private let session = ARKitSession()
    private let hands = HandTrackingProvider()
    private let world = WorldTrackingProvider()

    private(set) var handsRunning = false
    private(set) var worldRunning = false

    /// World anchors the system has found and is tracking (they persist
    /// between sessions: the cab's saved spot comes back this way).
    private var anchors: [UUID: simd_float4x4] = [:]

    private var anchorUpdates: Task<Void, Never>?

    // Wheel state

    private(set) var wheelAngle: Float = 0 // radians, + clockwise
    private var gripped = [false, false]   // left, right

    /// The grip angle last frame, while held.
    private var gripBase: Float?

    private var lastPalm: [SIMD3<Float>?] = [nil, nil]
    private var stillFor: [Float] = [0, 0]
    private var lastGrip = (false, false)

    // Controller edge detection

    private var heldShift = (up: false, down: false)

    func start() async {
        var providers: [any DataProvider] = []
        if HandTrackingProvider.isSupported { providers.append(hands) }
        if WorldTrackingProvider.isSupported { providers.append(world) }
        guard !providers.isEmpty else { return }

        do {
            try await session.run(providers)
            handsRunning = HandTrackingProvider.isSupported
            worldRunning = WorldTrackingProvider.isSupported
            if worldRunning { watchAnchors() }
        } catch {
            print("InputManager: ARKit session failed: \(error)")
        }
    }

    func stop() {
        anchorUpdates?.cancel()
        anchorUpdates = nil
        session.stop()
        handsRunning = false
        worldRunning = false
    }

    private func watchAnchors() {
        anchorUpdates = Task { [weak self, world] in
            for await update in world.anchorUpdates {
                let anchor = update.anchor
                if update.event == .removed || !anchor.isTracked {
                    self?.anchors[anchor.id] = nil
                } else {
                    self?.anchors[anchor.id] = anchor.originFromAnchorTransform
                }
            }
        }
    }

    /// Where a world anchor is now, if the system has found it.
    func anchorTransform(_ id: UUID) -> simd_float4x4? { anchors[id] }

    /// Saves a spot as a world anchor (kept between sessions), removing `old`.
    func replaceAnchor(_ old: UUID?, with transform: simd_float4x4) async -> UUID? {
        guard worldRunning else { return nil }
        if let old { try? await world.removeAnchor(forID: old) }

        let anchor = WorldAnchor(originFromAnchorTransform: transform)
        do {
            try await world.addAnchor(anchor)
            return anchor.id
        } catch {
            print("InputManager: could not save the cab's spot: \(error)")
            return nil
        }
    }

    /// The device transform now, in the immersive space.
    func headTransform() -> simd_float4x4? {
        guard worldRunning, let anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return nil }

        return anchor.originFromAnchorTransform
    }

    /// The stick's dead zone: drift and a resting thumb don't steer.
    private static let stickDeadZone: Float = 0.12

    /// How fast the stick turns the wheel: full lock and back, per second.
    private static let stickWheelSpeed: Float = 3

    /// The stick's position (past the dead zone) to steering: gentle near the
    /// middle, full lock at the edge. Sensitivity 1 is straight; 0 the most curved.
    private static func stickCurve(_ x: Float, sensitivity: Float) -> Float {
        let t = (abs(x) - stickDeadZone) / (1 - stickDeadZone)
        let exponent = 1 + 2 * (1 - max(0, min(1, sensitivity)))
        return (x < 0 ? -1 : 1) * pow(max(0, min(1, t)), exponent)
    }

    /// One frame: reads every source, updates the wheel, and returns the input.
    /// Without a cab (the flat screen window) only controllers steer.
    func update(model: AppModel, cab: Cab?, dt: Float) -> DTInput {
        let lock = model.wheelLockDegrees * .pi / 180
        var steer: Float?
        var accel: Float = 0, brake: Float = 0
        var buttons: UInt32 = 0

        // Hands
        var handCount = 0
        if handsRunning, let cab {
            let (left, right) = hands.latestAnchors
            let samples = [left, right].map { anchor in anchor.flatMap { Self.sample($0) } }
            handCount = steerWithHands(samples.map { $0?.palm }, cab: cab, lock: lock, dt: dt)
            let pedals = pinchPedals(samples, model: model, dt: dt)
            accel = max(accel, pedals.gas)
            brake = max(brake, pedals.brake)
        } else {
            relax(dt: dt)
            // `-gripdemo` (no hand tracking, e.g. the simulator): show both grip glows.
            let demo = ProcessInfo.processInfo.arguments.contains("-gripdemo")
            for hand in 0..<2 {
                cab?.setGrip(hand: hand, angle: demo ? (hand == 0 ? 2.1 : 1.0) : nil,
                            reach: 1, holding: demo, dt: dt)
            }
        }

        // Controllers
        var controllerName: String?
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            controllerName = controller.vendorName ?? "Controller"

            let x = pad.leftThumbstick.xAxis.value
            if abs(x) > Self.stickDeadZone { steer = Self.stickCurve(x, sensitivity: model.stickSensitivity) }
            accel = max(accel, pad.rightTrigger.value)
            brake = max(brake, pad.leftTrigger.value)

            if pad.buttonA.isPressed { buttons |= UInt32(DT_BTN_VIEW1) }
            if pad.buttonB.isPressed { buttons |= UInt32(DT_BTN_VIEW2) }
            if pad.buttonX.isPressed { buttons |= UInt32(DT_BTN_VIEW3) }
            if pad.buttonY.isPressed { buttons |= UInt32(DT_BTN_VIEW4) }
            if pad.buttonMenu.isPressed { buttons |= UInt32(DT_BTN_START) }
            if pad.buttonOptions?.isPressed == true { buttons |= UInt32(DT_BTN_COIN) }

            let up = pad.rightShoulder.isPressed || pad.dpad.up.isPressed
            let down = pad.leftShoulder.isPressed || pad.dpad.down.isPressed
            if up && !heldShift.up { model.shift(1) }
            if down && !heldShift.down { model.shift(-1) }
            heldShift = (up, down)
        }

        // A controller stick overrides the hands and turns the wheel towards
        // where it points, at a wheel's speed (a flick doesn't snap it).
        if let steer {
            let step = Self.stickWheelSpeed * lock * dt
            wheelAngle += max(-step, min(step, steer * lock - wheelAngle))
            gripBase = nil
            lastGrip = (false, false)
            gripped = [false, false]
        }

        if model.autoGas { accel = max(accel, 1 - brake) }

        let finalSteer = max(-1, min(1, wheelAngle / lock))
        cab?.setWheelAngle(wheelAngle)
        cab?.setGear(model.gear)
        cab?.setPedals(gas: accel, brake: brake)

        model.steer = finalSteer
        model.accel = accel
        model.brake = brake
        model.handsOnWheel = handCount
        model.handTrackingAvailable = handsRunning
        model.controllerName = controllerName

        buttons |= model.panelButtons(now: ProcessInfo.processInfo.systemUptime)
        return DTInput(steer: finalSteer, accel: accel, brake: brake, gear: model.gear, buttons: buttons)
    }

    // MARK: Hand steering

    private struct HandSample {
        var palm: SIMD3<Float>
        var pinch: [Float] // thumb tip to the index and middle fingertips, metres
    }

    private static func sample(_ anchor: HandAnchor) -> HandSample? {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        func world(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = anchor.originFromAnchorTransform * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let palm = (world(.wrist) + world(.middleFingerKnuckle)) / 2
        let thumb = world(.thumbTip)
        return HandSample(palm: palm, pinch: [simd_distance(thumb, world(.indexFingerTip)),
                                              simd_distance(thumb, world(.middleFingerTip))])
    }

    // MARK: Pinch pedals

    /// A pinch as a switch: on closing to 2.5 cm, off again opening past
    /// 3.5 cm (the gap keeps a pinch held near the edge from flickering).
    private static let pinchOn: Float = 0.025, pinchOff: Float = 0.035

    /// Pinch (Variable): no pedal with the thumb and index finger 8 cm apart (a
    /// hand at rest), all of it at 1.5 cm (fingertips touching).
    private static let pinchOpen: Float = 0.08, pinchClosed: Float = 0.015

    /// How quickly a pedal follows the fingers (a time constant, seconds):
    /// the tracked fingertips jitter by a few millimetres.
    private static let pinchSmoothing: Float = 0.06

    /// Each pedal's pinch held (switch) and its smoothed amount: [gas, brake].
    private var pinchHeld = [false, false]
    private var pinchLevel: [Float] = [0, 0]

    /// The gas and brake from the hands' pinches ([left, right]; nil, not
    /// tracked), each a thumb and finger on a hand as set. With both on one
    /// hand, only the finger closer to the thumb counts: pinching one brings
    /// the other near the thumb too.
    private func pinchPedals(_ hands: [HandSample?], model: AppModel, dt: Float) -> (gas: Float, brake: Float) {
        let pedals: [(style: AppModel.PedalStyle, hand: AppModel.Hand, finger: AppModel.Finger)] = [
            (model.gasStyle, model.gasHand, model.gasFinger),
            (model.brakeStyle, model.brakeHand, model.brakeFinger),
        ]
        var out: [Float] = [0, 0]
        for (i, pedal) in pedals.enumerated() {
            let finger = pedal.finger == .index ? 0 : 1
            guard pedal.style != .auto, let hand = hands[pedal.hand == .left ? 0 : 1] else {
                pinchHeld[i] = false
                pinchLevel[i] = 0
                continue
            }
            var d = hand.pinch[finger]
            if model.pedalsShareHand && hand.pinch[1 - finger] < d { d = .infinity }

            pinchHeld[i] = d < (pinchHeld[i] ? Self.pinchOff : Self.pinchOn)
            let amount = max(0, min(1, (Self.pinchOpen - d) / (Self.pinchOpen - Self.pinchClosed)))
            pinchLevel[i] += (amount - pinchLevel[i]) * min(1, dt / Self.pinchSmoothing)
            out[i] = pedal.style == .amount ? pinchLevel[i] : (pinchHeld[i] ? 1 : 0)
        }
        return (gas: out[0], brake: out[1])
    }

    /// Updates the wheel from the hands on it; returns how many are on it.
    ///
    /// The wheel follows the hands frame by frame: each frame's change in the
    /// grip angle (the line between two hands, or one hand round the hub) is
    /// added to it. Measured against a fixed start instead, a turn past half a
    /// revolution wrapped round and threw the wheel to the other lock, and a
    /// hand that drifted while clamped at lock left the wheel out of step.
    private func steerWithHands(_ palms: [SIMD3<Float>?], cab: Cab, lock: Float, dt: Float) -> Int {
        let r = cab.wheelRadius
        var local: [SIMD3<Float>?] = [nil, nil]

        for i in 0..<2 {
            guard let p = palms[i], !isFrozen(hand: i, palm: p, dt: dt) else {
                gripped[i] = false
                cab.setGrip(hand: i, angle: nil, reach: 0, holding: false, dt: dt)
                continue
            }

            let l = cab.wheelLocal(p)
            let off = abs(simd_length(SIMD2(l.x, l.y)) - r)

            // Easier to keep hold than to take it, but not by much: a hand
            // resting in the lap below the rim must not keep hold of it.
            gripped[i] = gripped[i] ? (off < 0.12 && abs(l.z) < 0.15) : (off < 0.09 && abs(l.z) < 0.12)
            if gripped[i] { local[i] = l }

            // Feedback: the glow fades in from 25 cm away and brightens on hold.
            let distance = simd_length(SIMD2(off, max(0, abs(l.z) - 0.03)))
            let reach = max(0, min(1, 1 - (distance - 0.08) / 0.17))
            cab.setGrip(hand: i, angle: reach > 0 || gripped[i] ? atan2(l.y, l.x) : nil,
                        reach: reach, holding: gripped[i], dt: dt)
        }

        let grip = (gripped[0], gripped[1])
        var angle: Float?
        if let l = local[0], let rt = local[1] {
            angle = atan2(rt.y - l.y, rt.x - l.x)
        } else if let h = local[0] ?? local[1] {
            angle = atan2(h.y, h.x)
        }

        if grip != lastGrip { // a hand took hold or let go: carry on from here
            gripBase = angle
            lastGrip = grip
        }

        if let angle, let last = gripBase {
            let step = Self.wrap(angle - last)
            gripBase = angle
            // A jump no hand makes in one frame is a tracking glitch, or two
            // hands crossing (their line flips): skip it rather than follow it.
            if abs(step) < 0.6 {
                // Counter-clockwise hands turn the wheel left.
                wheelAngle = max(-lock, min(lock, wheelAngle - step))
            }
        } else {
            relax(dt: dt)
        }

        return gripped.filter { $0 }.count
    }

    /// A hand whose position has not changed at all for a while: tracking
    /// stopped updating it (real hands always move a little). Treated as gone,
    /// or it would hold the wheel wherever it was last seen.
    private func isFrozen(hand i: Int, palm: SIMD3<Float>, dt: Float) -> Bool {
        if let last = lastPalm[i], simd_distance(last, palm) < 1e-5 {
            stillFor[i] += dt
        } else {
            stillFor[i] = 0
        }
        lastPalm[i] = palm
        return stillFor[i] > 0.4
    }

    private func relax(dt: Float) {
        wheelAngle *= exp(-dt * 7) // spring back to centre
        if abs(wheelAngle) < 0.002 { wheelAngle = 0 }
    }

    private static func wrap(_ a: Float) -> Float {
        var a = a
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
