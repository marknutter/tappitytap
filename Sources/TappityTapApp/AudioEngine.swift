import Foundation
import AVFoundation

// Generates damped-sine "click" buffers at startup, plays them on a small pool
// of player nodes. Pentatonic-ish set so random sequences sound vaguely musical.

final class TapPlayer {
    private let engine = AVAudioEngine()
    private var buffers: [AVAudioPCMBuffer] = []
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0

    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    init() throws {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frequencies: [Double] = [440, 523.25, 587.33, 659.25, 783.99, 880]
        for f in frequencies {
            buffers.append(Self.makeClickBuffer(frequency: f, format: format))
        }
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        try engine.start()
        for p in players { p.play() }
    }

    func playTap(intensity: Double) {
        let buf = buffers.randomElement()!
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        // Tap intensity 0.025..0.30 -> player volume 0.2..1.0.
        let soft = 0.025, hard = 0.30
        let t = (intensity - soft) / (hard - soft)
        let v = Float(max(0.2, min(1.0, 0.2 + 0.8 * t)))
        player.volume = v
        player.scheduleBuffer(buf, at: nil, options: [.interrupts], completionHandler: nil)
    }

    private static func makeClickBuffer(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let durationS: Double = 0.030
        let decayTau: Double = 0.006
        let frames = AVAudioFrameCount(durationS * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let channels = Int(format.channelCount)
        let twoPiF = 2.0 * .pi * frequency
        for n in 0..<Int(frames) {
            let t = Double(n) / sr
            let env = exp(-t / decayTau)
            let sample = Float(sin(twoPiF * t) * env)
            for c in 0..<channels {
                buf.floatChannelData![c][n] = sample
            }
        }
        return buf
    }
}
