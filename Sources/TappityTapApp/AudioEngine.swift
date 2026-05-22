import Foundation
import AVFoundation

// Per-tap audio player. Owns the engine + a small pool of player nodes that
// cycle so overlapping taps don't cut each other off. The sound pack is
// hot-swappable — switching packs replaces the buffer source but keeps the
// engine running.

final class TapPlayer {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var pack: SoundPack

    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    var audioFormat: AVAudioFormat {
        return engine.mainMixerNode.outputFormat(forBus: 0)
    }

    init(initialPack: SoundPackKind) throws {
        // Make a temporary throwaway format request just to bring the engine
        // up. Real format is read after attach.
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        self.pack = initialPack.make(format: format)
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        try engine.start()
        for p in players { p.play() }
    }

    func setPack(_ kind: SoundPackKind) {
        pack = kind.make(format: audioFormat)
    }

    func playTap(intensity: Double) {
        let buf = pack.pickBuffer(intensity: intensity)
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        let soft = 0.025, hard = 0.30
        let t = (intensity - soft) / (hard - soft)
        let v = Float(max(0.2, min(1.0, 0.2 + 0.8 * t)))
        player.volume = v
        player.scheduleBuffer(buf, at: nil, options: [.interrupts], completionHandler: nil)
    }
}
