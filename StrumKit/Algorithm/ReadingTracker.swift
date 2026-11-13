// StrumKit/Algorithm/ReadingTracker.swift
import Foundation

/// Follows a measured pitch against the **Targets**: which one it belongs to, where the
/// needle should be, and whether the **String** is in tune.
///
/// The measurements that arrive here are already precise — the partial lock sees to that —
/// so this does not have to invent stability. It has three jobs.
///
/// *Which Target.* The nearest one, held with hysteresis so a string between two Targets
/// does not flicker, and changed only when a different one has been heard twice running.
///
/// *Where the needle is.* A three-hop median removes the odd wild hop, and what is left is
/// smoothed by a filter whose cutoff rises with how fast the pitch is moving: slow and
/// heavy while the string is still, so the needle rests; quick while the peg is being
/// turned, so it keeps up. That one rule replaces a set of special cases for small steps,
/// large steps, decays and re-plucks.
///
/// *In tune.* 400 ms of continuous measurement within tolerance, as the glossary defines
/// it. Once given, the verdict is kept until the needle has clearly left, so it does not
/// flash on and off at the edge.
final class ReadingTracker {
    struct Tuning: Sendable, Equatable {
        /// Cutoff of the needle's smoothing while the pitch is still, in Hz.
        var restCutoff: Double = 1.1
        /// How much the cutoff rises per cent-per-second of motion.
        var speedGain: Double = 0.085
        /// Cutoff of the smoothing applied to the speed estimate itself, in Hz.
        var speedCutoff: Double = 1.5
        /// Apparent motion slower than this, in cents per second, is taken for
        /// measurement noise and does not quicken the needle.
        var restSpeed: Double = 12
        /// Extra cutoff right after a **String** is picked up, so the needle arrives
        /// instead of creeping in, and how quickly that extra fades (ms).
        var arrivalCutoff: Double = 7.0
        var arrivalFadeMs: Double = 110
        /// Tolerance for **In tune**, the margin for leaving it, and how long it takes.
        var toleranceCents: Double = 5
        var releaseCents: Double = 6.5
        var confirmationMs: Double = 400
        /// How far a single measurement may stray, as a multiple of the tolerance,
        /// without restarting a confirmation while the needle itself stays inside. A real
        /// string's pitch beats by a few cents; the needle averages that, and the
        /// verdict is about where the string is, not about each hop.
        var strayFactor: Double = 1.6
        /// A gap in measurement longer than this breaks an unfinished confirmation.
        var continuityMs: Double = 70
        /// With nothing measured for this long the smoothing starts afresh, and for this
        /// long the **String** itself is forgotten.
        var historyMs: Double = 300
        var identityMs: Double = 1000
        /// A pitch further than this from every **Target** belongs to none of them.
        var rejectionCents: Double = 250
        var hysteresisCents: Double = 25
        /// A different **Target** has to be heard this many hops running, over at least
        /// this long, before the tracker moves to it.
        var switchHops: Int = 2
        var switchMs: Double = 60
    }

    let tuning: Tuning

    var targets: [Target] = []
    /// Follow whichever **Target** is nearest, or stay on `selected`.
    var auto = true
    var selected = 0

    private(set) var current: Int?
    private var pending: (index: Int, count: Int, since: Double)?
    private var recent: [Double] = []
    private var smoothed: Double?
    private var speed = 0.0
    private var previousMedian: Double?
    private var lastMeasured = -Double.infinity
    private var acquiredAt = -Double.infinity
    private var withinSince: Double?
    private var confirmed = false

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    func reset() {
        current = nil
        pending = nil
        forgetMotion()
        lastMeasured = -.infinity
    }

    private func forgetMotion() {
        recent = []
        smoothed = nil
        speed = 0
        previousMedian = nil
        withinSince = nil
        confirmed = false
    }

    /// - Parameters:
    ///   - frequency: the measured pitch on this hop, or `nil` when nothing was measured.
    ///   - time: stream time in milliseconds.
    func push(frequency: Double?, rms: Double = 0, time: Double) -> FaithfulReading? {
        if time - lastMeasured > tuning.identityMs {
            current = nil
        }
        if time - lastMeasured > tuning.historyMs {
            forgetMotion()
        }

        guard let frequency, frequency > 0, !targets.isEmpty else {
            pending = nil
            // A dropout may hold a verdict already given; it cannot finish one.
            if !confirmed { withinSince = nil }
            return nil
        }

        // Which Target.
        var index = min(max(selected, 0), targets.count - 1)
        if auto {
            var nearest = 0
            var distance = Double.infinity
            for (i, target) in targets.enumerated() {
                let d = abs(centsBetween(frequency: frequency, reference: target.frequency))
                if d < distance { distance = d; nearest = i }
            }
            guard distance <= tuning.rejectionCents else {
                pending = nil
                if !confirmed { withinSince = nil }
                return nil
            }
            index = nearest
            if let current, index != current {
                let held = abs(centsBetween(frequency: frequency, reference: targets[current].frequency))
                if held < distance + tuning.hysteresisCents { index = current }
            }
        }

        if index != current {
            if let p = pending, p.index == index {
                pending = (index, p.count + 1, p.since)
            } else {
                pending = (index, 1, time)
            }
            let ready = pending!.count >= tuning.switchHops
                && (current == nil || time - pending!.since >= tuning.switchMs)
            guard ready else { return nil }
            current = index
            pending = nil
            forgetMotion()
        } else {
            pending = nil
        }

        let elapsed = lastMeasured.isFinite ? max(1.0, min(tuning.continuityMs, time - lastMeasured)) : 21.0
        let gap = time - lastMeasured
        lastMeasured = time

        let cents = centsBetween(frequency: frequency, reference: targets[index].frequency)
        recent.append(cents)
        if recent.count > 3 { recent.removeFirst() }
        let median = recent.sorted()[recent.count / 2]

        // Where the needle is.
        let value: Double
        if let previous = smoothed {
            let dt = elapsed / 1000
            let rawSpeed = (median - (previousMedian ?? median)) / dt
            speed += Self.gain(cutoff: tuning.speedCutoff, dt: dt) * (rawSpeed - speed)
            var cutoff = tuning.restCutoff + tuning.speedGain * max(0, abs(speed) - tuning.restSpeed)
            cutoff += tuning.arrivalCutoff * exp(-(time - acquiredAt) / tuning.arrivalFadeMs)
            value = previous + Self.gain(cutoff: cutoff, dt: dt) * (median - previous)
        } else {
            acquiredAt = time
            speed = 0
            value = median
        }
        smoothed = value
        previousMedian = median

        // In tune.
        if confirmed {
            if abs(value) > tuning.releaseCents || abs(median) > tuning.releaseCents * 1.5 {
                confirmed = false
                withinSince = nil
            }
        } else if abs(median) <= tuning.toleranceCents * tuning.strayFactor && abs(value) <= tuning.toleranceCents {
            if withinSince == nil || gap > tuning.continuityMs { withinSince = time }
            if time - withinSince! >= tuning.confirmationMs { confirmed = true }
        } else {
            withinSince = nil
        }

        let target = targets[index]
        return FaithfulReading(
            frequency: target.frequency * pow(2.0, value / 1200.0),
            cents: value,
            index: index,
            note: target.note,
            inTune: confirmed,
            rms: rms,
            stringNumber: target.stringNumber ?? (targets.count - index)
        )
    }

    /// The share of the remaining distance a one-pole low-pass covers in `dt` seconds.
    private static func gain(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 - exp(-dt / tau)
    }
}
