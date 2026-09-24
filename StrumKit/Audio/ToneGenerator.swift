import AVFoundation
import Foundation

/// Real-time audio synthesizer for reference pitch pipe playback.
/// Uses AVAudioSourceNode to generate pure sine waves with smooth attack/decay envelopes.
public final class ToneGenerator: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let queue = DispatchQueue(label: "com.strumkit.tonegenerator")

    private var currentPhase: Double = 0.0
    private var currentFrequency: Double = 440.0
    private var isPlayingInternal: Bool = false
    private var targetVolume: Float = 0.5
    private var currentVolume: Float = 0.0

    public init() {}

    /// Starts playing a pure sine wave tone at the specified frequency.
    public func play(frequency: Double, volume: Float = 0.5) {
        queue.async {
            self.currentFrequency = frequency
            self.targetVolume = volume

            guard !self.isPlayingInternal else { return }

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                print("[StrumKit] ToneGenerator session error: \(error)")
            }
            #endif

            let outputFormat = self.engine.outputNode.outputFormat(forBus: 0)
            let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44100.0

            let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let phaseIncrement = (2.0 * Double.pi * self.currentFrequency) / sampleRate

                for frame in 0..<Int(frameCount) {
                    // Smooth volume ramping (envelope)
                    if self.currentVolume < self.targetVolume {
                        self.currentVolume = min(self.targetVolume, self.currentVolume + 0.001)
                    } else if self.currentVolume > self.targetVolume {
                        self.currentVolume = max(0.0, self.currentVolume - 0.001)
                    }

                    let sampleVal = Float(sin(self.currentPhase)) * self.currentVolume
                    self.currentPhase += phaseIncrement
                    if self.currentPhase >= 2.0 * Double.pi {
                        self.currentPhase -= 2.0 * Double.pi
                    }

                    for buffer in ablPointer {
                        guard let buf = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        buf[frame] = sampleVal
                    }
                }
                return noErr
            }

            self.sourceNode = source
            self.engine.attach(source)
            self.engine.connect(source, to: self.engine.mainMixerNode, format: outputFormat)

            do {
                self.engine.prepare()
                try self.engine.start()
                self.isPlayingInternal = true
            } catch {
                print("[StrumKit] ToneGenerator engine start failed: \(error)")
            }
        }
    }

    /// Stops audio playback gracefully.
    public func stop() {
        queue.async {
            guard self.isPlayingInternal else { return }
            self.engine.stop()
            if let node = self.sourceNode {
                self.engine.detach(node)
                self.sourceNode = nil
            }
            self.isPlayingInternal = false
            self.currentPhase = 0.0
            self.currentVolume = 0.0
        }
    }

    public var isPlaying: Bool {
        queue.sync { isPlayingInternal }
    }
}
