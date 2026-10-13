import AVFAudio
import RealityKit

/// The game's sound from the cabinet's own speakers: one spatial mono
/// generator per channel, on the left and right speaker entities, so the
/// sound stays in the cab as you turn your head.
@MainActor
final class CabAudio {
    private var controllers: [AudioGeneratorController] = []

    func start(session: GameSession, left: Entity, right: Entity) {
        stop()

        for (channel, speaker) in [(0, left), (1, right)] {
            speaker.components.set(SpatialAudioComponent(gain: -4, directivity: .beam(focus: 0.2)))

            do {
                let controller = try speaker.playAudio { isSilence, _, frameCount, outputData in
                    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
                    for buffer in buffers {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        session.readAudio(channel: channel, into: data, frames: Int(frameCount))
                    }
                    isSilence.pointee = false
                    return noErr
                }
                controllers.append(controller)
            } catch {
                print("CabAudio: cannot start the \(channel == 0 ? "left" : "right") speaker: \(error)")
            }
        }
    }

    func stop() {
        for controller in controllers { controller.stop() }
        controllers.removeAll()
    }
}
