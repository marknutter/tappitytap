import Foundation
import AVFoundation

// A sound pack pre-generates a bank of PCM buffers at init, then hands one
// back per tap. The pack decides whether selection is random or driven by
// intensity. All buffers use the same audio format so they can be played
// through any of the player nodes interchangeably.

protocol SoundPack {
    var id: String { get }
    var displayName: String { get }
    func pickBuffer(intensity: Double) -> AVAudioPCMBuffer
}

// =====================================================================
// MARK: - Helpers
// =====================================================================

private func allocBuffer(format: AVAudioFormat, durationS: Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(durationS * format.sampleRate)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    return buf
}

private func writeSample(_ buf: AVAudioPCMBuffer, _ frame: Int, _ value: Float) {
    let channels = Int(buf.format.channelCount)
    for c in 0..<channels {
        buf.floatChannelData![c][frame] = value
    }
}

// Simple one-pole white noise with optional running smoothing — sounds less
// harsh than raw uniform noise.
private func smoothedNoise(_ count: Int, smoothing: Double = 0.0) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    var prev: Double = 0
    for i in 0..<count {
        let n = Double.random(in: -1...1)
        let v = prev * smoothing + n * (1 - smoothing)
        out[i] = Float(v)
        prev = v
    }
    return out
}

// =====================================================================
// MARK: - Pentatonic (the original click pack)
// =====================================================================

final class PentatonicPack: SoundPack {
    let id = "pentatonic"
    let displayName = "Pentatonic clicks"
    private let buffers: [AVAudioPCMBuffer]

    init(format: AVAudioFormat) {
        let frequencies: [Double] = [440, 523.25, 587.33, 659.25, 783.99, 880]
        self.buffers = frequencies.map { f in
            let buf = allocBuffer(format: format, durationS: 0.030)
            let sr = format.sampleRate
            let twoPiF = 2.0 * .pi * f
            let decayTau = 0.006
            for n in 0..<Int(buf.frameLength) {
                let t = Double(n) / sr
                let env = exp(-t / decayTau)
                writeSample(buf, n, Float(sin(twoPiF * t) * env))
            }
            return buf
        }
    }

    func pickBuffer(intensity: Double) -> AVAudioPCMBuffer {
        return buffers.randomElement()!
    }
}

// =====================================================================
// MARK: - Mechanical (typewriter clicks + woodblock taps)
// =====================================================================

final class MechanicalPack: SoundPack {
    let id = "mechanical"
    let displayName = "Mechanical clicks"
    private let buffers: [AVAudioPCMBuffer]

    init(format: AVAudioFormat) {
        var all: [AVAudioPCMBuffer] = []
        let sr = format.sampleRate

        // Typewriter-ish clicks: sharp impulse + damped sine at mid-high frequency,
        // with a tiny bit of noise mixed into the attack for grit.
        for centerHz in [1500.0, 1900.0, 2400.0, 3000.0] {
            let buf = allocBuffer(format: format, durationS: 0.025)
            let twoPiF = 2.0 * .pi * centerHz
            let decayTau = 0.0035
            let noise = smoothedNoise(Int(buf.frameLength), smoothing: 0.4)
            for n in 0..<Int(buf.frameLength) {
                let t = Double(n) / sr
                let env = exp(-t / decayTau)
                let attack = n < 6 ? Float(n) / 6.0 : 1.0  // soften the very first samples
                let tone = sin(twoPiF * t) * env
                let grit = Double(noise[n]) * env * 0.35
                writeSample(buf, n, attack * Float(tone + grit) * 0.9)
            }
            all.append(buf)
        }

        // Woodblock taps: lower frequency, longer ring, no grit.
        for centerHz in [600.0, 750.0, 900.0, 1100.0] {
            let buf = allocBuffer(format: format, durationS: 0.060)
            let twoPiF = 2.0 * .pi * centerHz
            let decayTau = 0.012
            for n in 0..<Int(buf.frameLength) {
                let t = Double(n) / sr
                let env = exp(-t / decayTau)
                let attack = n < 4 ? Float(n) / 4.0 : 1.0
                writeSample(buf, n, attack * Float(sin(twoPiF * t) * env) * 0.85)
            }
            all.append(buf)
        }

        self.buffers = all
    }

    func pickBuffer(intensity: Double) -> AVAudioPCMBuffer {
        return buffers.randomElement()!
    }
}

// =====================================================================
// MARK: - Soft drum kit (kick / snare / hat, mapped by intensity)
// =====================================================================

final class SoftDrumPack: SoundPack {
    let id = "drums"
    let displayName = "Soft drum kit"

    private let hats:  [AVAudioPCMBuffer]
    private let snares: [AVAudioPCMBuffer]
    private let kicks:  [AVAudioPCMBuffer]

    init(format: AVAudioFormat) {
        let sr = format.sampleRate

        // Hi-hat: short noise burst, high-passed by subtracting a running mean.
        self.hats = (0..<3).map { _ in
            let buf = allocBuffer(format: format, durationS: 0.060)
            let decayTau = 0.012
            var lp = 0.0
            for n in 0..<Int(buf.frameLength) {
                let t = Double(n) / sr
                let env = exp(-t / decayTau)
                let raw = Double.random(in: -1...1)
                lp = lp * 0.6 + raw * 0.4
                let highPassed = raw - lp
                writeSample(buf, n, Float(highPassed * env) * 0.7)
            }
            return buf
        }

        // Snare: noise + 200 Hz body tone, both shaped by a sharp envelope.
        self.snares = (0..<3).map { i in
            let bodyHz = 180.0 + Double(i) * 25.0
            let buf = allocBuffer(format: format, durationS: 0.150)
            let decayTau = 0.045
            let twoPiF = 2.0 * .pi * bodyHz
            for n in 0..<Int(buf.frameLength) {
                let t = Double(n) / sr
                let env = exp(-t / decayTau)
                let attack = n < 12 ? Float(n) / 12.0 : 1.0
                let body = sin(twoPiF * t) * env * 0.45
                let noise = Double.random(in: -1...1) * env * 0.55
                writeSample(buf, n, attack * Float(body + noise) * 0.85)
            }
            return buf
        }

        // Kick: sine sweep from ~140 Hz down to ~40 Hz with a thumpy envelope.
        self.kicks = (0..<2).map { i in
            let startHz = 140.0 + Double(i) * 15.0
            let endHz = 40.0
            let buf = allocBuffer(format: format, durationS: 0.220)
            let decayTau = 0.080
            let sweepTau = 0.040
            var phase = 0.0
            for n in 0..<Int(buf.frameLength) {
                let t = Double(n) / sr
                let env = exp(-t / decayTau)
                let sweep = exp(-t / sweepTau)
                let hz = endHz + (startHz - endHz) * sweep
                phase += 2.0 * .pi * hz / sr
                writeSample(buf, n, Float(sin(phase) * env) * 0.95)
            }
            return buf
        }
    }

    func pickBuffer(intensity: Double) -> AVAudioPCMBuffer {
        // Light tap -> hat, medium -> snare, hard -> kick. Tunable cutoffs.
        let pool: [AVAudioPCMBuffer]
        switch intensity {
        case ..<0.06: pool = hats
        case ..<0.14: pool = snares
        default:      pool = kicks
        }
        return pool.randomElement()!
    }
}

// =====================================================================
// MARK: - Registry
// =====================================================================

enum SoundPackKind: String, CaseIterable, Identifiable {
    case pentatonic, mechanical, drums
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pentatonic: return "Pentatonic clicks"
        case .mechanical: return "Mechanical clicks"
        case .drums:      return "Soft drum kit"
        }
    }
    func make(format: AVAudioFormat) -> SoundPack {
        switch self {
        case .pentatonic: return PentatonicPack(format: format)
        case .mechanical: return MechanicalPack(format: format)
        case .drums:      return SoftDrumPack(format: format)
        }
    }
}
