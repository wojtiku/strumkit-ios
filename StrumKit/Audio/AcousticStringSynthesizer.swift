import AVFoundation
import Foundation

/// Synthesizes authentic acoustic plucked string tones for Guitar and Ukulele.
/// Based on chorder's physical string model (Karplus-Strong with pluck excitation, body resonance, and string dispersion).
public final class AcousticStringSynthesizer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.strumkit.stringsynth")
    private let synthFormat: AVAudioFormat

    public private(set) var activeStringIndex: Int? = nil

    public init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        self.synthFormat = format
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    /// Plays an acoustic reference string tone.
    public func playString(frequency: Double, stringIndex: Int, instrument: InstrumentCategory) {
        queue.async {
            self.stopInternal()

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                do {
                    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                    try session.setActive(true)
                } catch {
                    print("[StrumKit] Synth session error: \(error)")
                }
            }
            #endif

            let sampleRate: Double = 44100.0
            let durationSeconds: Double = instrument == .guitar ? 2.8 : 2.0
            let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.synthFormat, frameCapacity: frameCount) else { return }

            buffer.frameLength = frameCount
            guard let channelData = buffer.floatChannelData?[0] else { return }

            // Karplus-Strong string synthesis with pick excitation and dispersion
            let delayLength = max(2, Int(round(sampleRate / frequency)))
            var delayLine = [Float](repeating: 0.0, count: delayLength)

            // String profile coefficients
            let decayFactor: Float = instrument == .guitar ? 0.994 : 0.988
            let brightness: Float = instrument == .guitar ? 0.45 : 0.35

            // Initial excitation: noise burst shaped by pluck position
            let pluckPos: Double = instrument == .guitar ? 0.18 : 0.23
            let combTap = max(1, Int(Double(delayLength) * pluckPos))

            var randSeed: UInt32 = UInt32(stringIndex * 7919 + 104729)
            func nextRandom() -> Float {
                randSeed = (randSeed &* 1664525 &+ 1013904223)
                return (Float(randSeed >> 16) / 32768.0) - 1.0
            }

            for i in 0..<delayLength {
                let noise = nextRandom()
                let shaped = (i >= combTap) ? (noise - delayLine[i - combTap] * 0.8) : noise
                delayLine[i] = shaped
            }

            // Loop filter and body resonance simulation
            var delayIdx = 0
            var prevSample: Float = 0.0
            // Low-pass body formant filter
            var bodyFilter: Float = 0.0

            for frame in 0..<Int(frameCount) {
                let current = delayLine[delayIdx]
                // Low-pass averaging filter for string dissipation
                let filtered = (current * (1.0 - brightness) + prevSample * brightness) * decayFactor
                delayLine[delayIdx] = filtered
                prevSample = filtered

                // Simple 2-pole body resonator simulation (adding warm acoustic bloom)
                bodyFilter += 0.08 * (filtered - bodyFilter)

                // Amplitude envelope (exponential tail decay)
                let progress = Float(frame) / Float(frameCount)
                let envelope = pow(1.0 - progress, 2.0)

                channelData[frame] = (filtered * 0.7 + bodyFilter * 0.3) * envelope * 0.85

                delayIdx = (delayIdx + 1) % delayLength
            }

            let playerFormat = self.playerNode.outputFormat(forBus: 0)
            if playerFormat.channelCount != self.synthFormat.channelCount || playerFormat.sampleRate != self.synthFormat.sampleRate {
                self.engine.disconnectNodeOutput(self.playerNode)
                self.engine.connect(self.playerNode, to: self.engine.mainMixerNode, format: self.synthFormat)
            }

            if !self.engine.isRunning {
                do {
                    try self.engine.start()
                } catch {
                    print("[StrumKit] Failed to start synth engine: \(error)")
                    return
                }
            }

            guard self.playerNode.outputFormat(forBus: 0).channelCount == buffer.format.channelCount else {
                print("[StrumKit] Player node output format channel count mismatch: \(self.playerNode.outputFormat(forBus: 0).channelCount) vs \(buffer.format.channelCount)")
                return
            }

            self.activeStringIndex = stringIndex
            self.playerNode.stop()
            self.playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    if self.activeStringIndex == stringIndex {
                        self.activeStringIndex = nil
                    }
                }
            }
            self.playerNode.play()
        }
    }

    /// Stops any playing tone immediately.
    public func stop() {
        queue.async {
            self.stopInternal()
        }
    }

    private func stopInternal() {
        playerNode.stop()
        activeStringIndex = nil
    }
}
