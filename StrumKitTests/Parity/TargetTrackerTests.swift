// StrumKitTests/Parity/TargetTrackerTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Faithful Target Tracker & State Transitions")
struct TargetTrackerTests {

    let budgets = ParityBudgets.frozen

    // MARK: - 1. Target Tables & Frequencies

    @Test("Pre-calculated target tables match reference definitions")
    func targetTablesMatchReference() {
        let standard = TUNINGS["standard"]!
        #expect(standard.count == 4)
        #expect(standard[0].note == "G4" && standard[0].midi == 67)
        #expect(abs(standard[0].frequency - 391.99543598174927) < budgets.frequencyAbsoluteHz)
        #expect(standard[1].note == "C4" && standard[1].midi == 60)
        #expect(abs(standard[1].frequency - 261.6255653005986) < budgets.frequencyAbsoluteHz)
        #expect(standard[2].note == "E4" && standard[2].midi == 64)
        #expect(abs(standard[2].frequency - 329.6275569128699) < budgets.frequencyAbsoluteHz)
        #expect(standard[3].note == "A4" && standard[3].midi == 69)
        #expect(abs(standard[3].frequency - 440.0) < budgets.frequencyAbsoluteHz)

        let lowG = TUNINGS["low-g"]!
        #expect(lowG[0].note == "G3" && lowG[0].midi == 55)
        #expect(abs(lowG[0].frequency - 195.99771799087463) < budgets.frequencyAbsoluteHz)

        let d = TUNINGS["d"]!
        #expect(d[0].note == "A4" && d[0].midi == 69)
        #expect(d[1].note == "D4" && d[1].midi == 62)
        #expect(abs(d[1].frequency - 293.6647679174076) < budgets.frequencyAbsoluteHz)
        #expect(d[2].matchesNoteName("F#4") && d[2].midi == 66)
        #expect(abs(d[2].frequency - 369.9944227116344) < budgets.frequencyAbsoluteHz)
        #expect(d[3].note == "B4" && d[3].midi == 71)
        #expect(abs(d[3].frequency - 493.8833012561241) < budgets.frequencyAbsoluteHz)

        let slack = TUNINGS["slack"]!
        #expect(slack[0].note == "G4" && slack[0].midi == 67)
        #expect(slack[1].note == "C4" && slack[1].midi == 60)
        #expect(slack[2].note == "E4" && slack[2].midi == 64)
        #expect(slack[3].note == "G4" && slack[3].midi == 67)
    }

    @Test("centsBetween calculates exact logarithmic pitch deviation")
    func centsBetweenCalculations() {
        #expect(abs(centsBetween(frequency: 440.0, reference: 440.0)) < 1e-9)
        #expect(abs(centsBetween(frequency: 880.0, reference: 440.0) - 1200.0) < 1e-9)
        #expect(abs(centsBetween(frequency: 220.0, reference: 440.0) - (-1200.0)) < 1e-9)
        let semitoneRatio = pow(2.0, 1.0 / 12.0)
        #expect(abs(centsBetween(frequency: 440.0 * semitoneRatio, reference: 440.0) - 100.0) < 1e-9)
    }

    // MARK: - 2. Nearest Target Selection Across All Tunings

    @Test("Nearest target selection in standard tuning")
    func nearestTargetStandardTuning() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // G4 acquisition (2 frames)
        _ = tracker.push(frequency: 392.0, confidence: 0.99, time: 0)
        let rG4 = tracker.push(frequency: 392.0, confidence: 0.99, time: 20)
        #expect(rG4?.index == 0)
        #expect(rG4?.note == "G4")
        #expect(rG4?.stringNumber == 4)

        // Reset and acquire C4
        tracker.reset()
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 100)
        let rC4 = tracker.push(frequency: 261.6, confidence: 0.99, time: 120)
        #expect(rC4?.index == 1)
        #expect(rC4?.note == "C4")
        #expect(rC4?.stringNumber == 3)

        // Reset and acquire E4
        tracker.reset()
        _ = tracker.push(frequency: 329.6, confidence: 0.99, time: 200)
        let rE4 = tracker.push(frequency: 329.6, confidence: 0.99, time: 220)
        #expect(rE4?.index == 2)
        #expect(rE4?.note == "E4")
        #expect(rE4?.stringNumber == 2)

        // Reset and acquire A4
        tracker.reset()
        _ = tracker.push(frequency: 440.0, confidence: 0.99, time: 300)
        let rA4 = tracker.push(frequency: 440.0, confidence: 0.99, time: 320)
        #expect(rA4?.index == 3)
        #expect(rA4?.note == "A4")
        #expect(rA4?.stringNumber == 1)
    }

    @Test("Nearest target selection in low-g and d tunings")
    func nearestTargetLowGAndD() {
        let tracker = FaithfulTracker()

        // Low-G tuning: G3 is target 0
        tracker.tuning = "low-g"
        _ = tracker.push(frequency: 196.0, confidence: 0.99, time: 0)
        let rG3 = tracker.push(frequency: 196.0, confidence: 0.99, time: 20)
        #expect(rG3?.index == 0)
        #expect(rG3?.note == "G3")
        #expect(rG3?.stringNumber == 4)

        // D tuning: A4 (0), D4 (1), F#4 (2), B4 (3)
        tracker.reset()
        tracker.tuning = "d"

        _ = tracker.push(frequency: 293.7, confidence: 0.99, time: 100)
        let rD4 = tracker.push(frequency: 293.7, confidence: 0.99, time: 120)
        #expect(rD4?.index == 1)
        #expect(rD4?.note == "D4")
        #expect(rD4?.stringNumber == 3)

        tracker.reset()
        _ = tracker.push(frequency: 370.0, confidence: 0.99, time: 200)
        let rFSharp4 = tracker.push(frequency: 370.0, confidence: 0.99, time: 220)
        #expect(rFSharp4?.index == 2)
        #expect(rFSharp4?.stringNumber == 2)
        #expect(rFSharp4?.note.contains("F") == true)

        tracker.reset()
        _ = tracker.push(frequency: 494.0, confidence: 0.99, time: 300)
        let rB4 = tracker.push(frequency: 494.0, confidence: 0.99, time: 320)
        #expect(rB4?.index == 3)
        #expect(rB4?.note == "B4")
        #expect(rB4?.stringNumber == 1)
    }

    // MARK: - 3. Duplicate Targets in Slack Tuning

    @Test("Duplicate targets in Slack tuning: tie goes to lowest index (first string)")
    func duplicateTargetsSlackTuningTieToFirst() {
        let tracker = FaithfulTracker()
        tracker.tuning = "slack" // [G4, C4, E4, G4]

        // Pitch is exact G4 (391.995436 Hz) equidistant to index 0 and index 3
        let g4Freq = 440.0 * pow(2.0, Double(67 - 69) / 12.0)
        _ = tracker.push(frequency: g4Freq, confidence: 0.99, time: 0)
        let reading = tracker.push(frequency: g4Freq, confidence: 0.99, time: 20)

        // Tie must go to lowest index (index 0, String 4)
        #expect(reading != nil)
        #expect(reading?.index == 0)
        #expect(reading?.stringNumber == 4)
        #expect(reading?.note == "G4")
    }

    // MARK: - 4. 250-Cent Rejection Gate

    @Test("250-cent rejection gate: within 250 cents accepted, outside 250 cents rejected")
    func rejectionGate250Cents() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"
        let c4Freq = TUNINGS["standard"]![1].frequency // 261.625565 Hz

        // Frequency at -249 cents from C4 (no other target is close)
        let freq249BelowC4 = c4Freq * pow(2.0, -249.0 / 1200.0)
        _ = tracker.push(frequency: freq249BelowC4, confidence: 0.99, time: 0)
        let rAccepted = tracker.push(frequency: freq249BelowC4, confidence: 0.99, time: 20)
        #expect(rAccepted != nil)
        #expect(rAccepted?.index == 1) // C4

        // Frequency at -251 cents from C4: distance is 251 cents > 250 cents
        tracker.reset()
        let freq251BelowC4 = c4Freq * pow(2.0, -251.0 / 1200.0)
        let r1 = tracker.push(frequency: freq251BelowC4, confidence: 0.99, time: 100)
        let r2 = tracker.push(frequency: freq251BelowC4, confidence: 0.99, time: 120)
        #expect(r1 == nil)
        #expect(r2 == nil)
        #expect(tracker.current == nil)
        #expect(tracker.pending == nil)
        #expect(tracker.pendingCount == 0)

        // Exact 250.0 boundary: distance == 250.0 is <= 250, so NOT rejected
        tracker.reset()
        let freqExact250BelowC4 = c4Freq * pow(2.0, -250.0 / 1200.0)
        _ = tracker.push(frequency: freqExact250BelowC4, confidence: 0.99, time: 200)
        let rExactBoundary = tracker.push(frequency: freqExact250BelowC4, confidence: 0.99, time: 220)
        #expect(rExactBoundary != nil)
        #expect(rExactBoundary?.index == 1)

        // Above highest string A4 (440 Hz)
        tracker.reset()
        let a4Freq = 440.0
        let freq249AboveA4 = a4Freq * pow(2.0, 249.0 / 1200.0)
        _ = tracker.push(frequency: freq249AboveA4, confidence: 0.99, time: 300)
        let rAcceptedHigh = tracker.push(frequency: freq249AboveA4, confidence: 0.99, time: 320)
        #expect(rAcceptedHigh != nil)
        #expect(rAcceptedHigh?.index == 3) // A4

        tracker.reset()
        let freq251AboveA4 = a4Freq * pow(2.0, 251.0 / 1200.0)
        _ = tracker.push(frequency: freq251AboveA4, confidence: 0.99, time: 400)
        let rRejectedHigh = tracker.push(frequency: freq251AboveA4, confidence: 0.99, time: 420)
        #expect(rRejectedHigh == nil)
        #expect(tracker.current == nil)
    }

    // MARK: - 5. 25-Cent Hysteresis vs Legacy Midpoint Deadband

    @Test("25-cent hysteresis holds current target past midpoint until distance delta >= 25 cents")
    func hysteresis25Cents() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Acquire C4 (index 1, 261.626 Hz)
        let c4Freq = TUNINGS["standard"]![1].frequency
        let e4Freq = TUNINGS["standard"]![2].frequency // 329.628 Hz, 400 cents above C4
        _ = tracker.push(frequency: c4Freq, confidence: 0.99, time: 0)
        let rInit = tracker.push(frequency: c4Freq, confidence: 0.99, time: 20)
        #expect(rInit?.index == 1)
        #expect(tracker.current == 1)

        // Midpoint between C4 and E4 is +200 cents from C4 (-200 cents from E4).
        // Legacy midpoint detector switches or dead-bands symmetrically around 200 cents.
        // In the faithful tracker:
        // distances[C4] < distances[E4] + 25 -> keep C4.
        // At +205 cents from C4: distances[C4]=205, distances[E4]=195.
        // 205 < 195 + 25 = 220 -> True: holds C4!
        let freqPlus205 = c4Freq * pow(2.0, 205.0 / 1200.0)
        let r205 = tracker.push(frequency: freqPlus205, confidence: 0.99, time: 40)
        #expect(r205?.index == 1) // Still C4!

        // At +212 cents from C4: distances[C4]=212, distances[E4]=188.
        // 212 < 188 + 25 = 213 -> True: still holds C4!
        let freqPlus212 = c4Freq * pow(2.0, 212.0 / 1200.0)
        let r212 = tracker.push(frequency: freqPlus212, confidence: 0.99, time: 60)
        #expect(r212?.index == 1) // Still C4!

        // At +213 cents from C4: distances[C4]=213, distances[E4]=187.
        // 213 < 187 + 25 = 212 is FALSE (213 >= 212).
        // Target index candidate becomes E4 (index 2)!
        // Because tracker is in auto mode and current != nil and index != current,
        // it requires pending vote and 160 ms auto-switch delay to switch.
        let freqPlus213 = c4Freq * pow(2.0, 213.0 / 1200.0)
        let rSwitchPending = tracker.push(frequency: freqPlus213, confidence: 0.99, time: 80)
        #expect(rSwitchPending == nil) // pending switch to E4
        #expect(tracker.pending == 2)
        #expect(tracker.current == 1) // Current remains C4 during switch delay
    }

    // MARK: - 6. Pending 2-Frame Vote

    @Test("Pending 2-frame vote: 1st frame returns nil, 2nd frame acquires target")
    func pendingTwoFrameVote() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Frame 1: fresh pitch
        let r1 = tracker.push(frequency: 440.0, confidence: 0.99, time: 100)
        #expect(r1 == nil)
        #expect(tracker.current == nil)
        #expect(tracker.pending == 3)
        #expect(tracker.pendingCount == 1)
        #expect(tracker.pendingSince == 100)
        #expect(tracker.pendingTime == 100)

        // Frame 2: corroborating pitch within 150 ms
        let r2 = tracker.push(frequency: 440.0, confidence: 0.99, time: 120)
        #expect(r2 != nil)
        #expect(tracker.current == 3)
        #expect(tracker.pending == nil)
        #expect(tracker.pendingCount == 0)
        #expect(r2?.index == 3)
        #expect(r2?.note == "A4")
    }

    // MARK: - 7. 160 ms Auto-Switch Delay

    @Test("160 ms auto-switch delay holds target until duration elapses")
    func autoSwitchDelay160ms() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Initial acquisition of C4 (index 1)
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 0)
        let rInit = tracker.push(frequency: 261.6, confidence: 0.99, time: 20)
        #expect(rInit?.index == 1)
        #expect(tracker.current == 1)

        // Pitch suddenly jumps to A4 (index 3) at t = 500 ms
        let r1 = tracker.push(frequency: 440.0, confidence: 0.99, time: 500)
        #expect(r1 == nil)
        #expect(tracker.current == 1)
        #expect(tracker.pending == 3)
        #expect(tracker.pendingCount == 1)
        #expect(tracker.pendingSince == 500)

        // Frame at t = 550 ms (elapsed 50 ms < 160 ms)
        let r2 = tracker.push(frequency: 440.0, confidence: 0.99, time: 550)
        #expect(r2 == nil)
        #expect(tracker.current == 1)
        #expect(tracker.pending == 3)
        #expect(tracker.pendingCount == 2)

        // Frame at t = 600 ms (elapsed 100 ms < 160 ms)
        let r3 = tracker.push(frequency: 440.0, confidence: 0.99, time: 600)
        #expect(r3 == nil)
        #expect(tracker.current == 1)
        #expect(tracker.pendingCount == 3)

        // Frame at t = 659 ms (elapsed 159 ms < 160 ms)
        let r4 = tracker.push(frequency: 440.0, confidence: 0.99, time: 659)
        #expect(r4 == nil)
        #expect(tracker.current == 1)

        // Frame at t = 660 ms (elapsed 160 ms >= 160 ms): switch commits!
        let r5 = tracker.push(frequency: 440.0, confidence: 0.99, time: 660)
        #expect(r5 != nil)
        #expect(tracker.current == 3)
        #expect(r5?.index == 3)
        #expect(r5?.note == "A4")
        #expect(tracker.pending == nil)
        #expect(tracker.pendingCount == 0)
    }

    @Test("Switching back before 160 ms cancels pending switch")
    func cancelPendingSwitchBefore160ms() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Acquire C4 (index 1)
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 0)
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 20)
        #expect(tracker.current == 1)

        // Temporary transient towards A4 (index 3) at t = 200 ms
        _ = tracker.push(frequency: 440.0, confidence: 0.99, time: 200)
        _ = tracker.push(frequency: 440.0, confidence: 0.99, time: 240)
        #expect(tracker.pending == 3)
        #expect(tracker.current == 1)

        // Pitch returns to C4 at t = 280 ms (before 160 ms delay)
        let rBack = tracker.push(frequency: 261.6, confidence: 0.99, time: 280)
        #expect(rBack != nil)
        #expect(rBack?.index == 1)
        #expect(tracker.current == 1)
        #expect(tracker.pending == nil)
        #expect(tracker.pendingCount == 0)
    }

    // MARK: - 8. 150 ms Pending Expiry

    @Test("150 ms pending expiry: frame gap > 150 ms resets pending vote count")
    func pendingExpiry150ms() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Frame 1 at t = 100 ms
        let r1 = tracker.push(frequency: 440.0, confidence: 0.99, time: 100)
        #expect(r1 == nil)
        #expect(tracker.pending == 3)
        #expect(tracker.pendingCount == 1)
        #expect(tracker.pendingTime == 100)

        // Frame 2 at t = 251 ms (gap = 151 ms > 150 ms): pending expired!
        let r2 = tracker.push(frequency: 440.0, confidence: 0.99, time: 251)
        #expect(r2 == nil)
        #expect(tracker.pending == 3)
        #expect(tracker.pendingCount == 1) // Reset to 0 then incremented to 1
        #expect(tracker.pendingSince == 251)
        #expect(tracker.pendingTime == 251)

        // Frame 3 at t = 270 ms (gap = 19 ms <= 150 ms): now count reaches 2 and acquires!
        let r3 = tracker.push(frequency: 440.0, confidence: 0.99, time: 270)
        #expect(r3 != nil)
        #expect(tracker.current == 3)
        #expect(tracker.pending == nil)
        #expect(tracker.pendingCount == 0)
    }

    // MARK: - 9. 300 ms Pitch History Expiry vs 1000 ms Target Identity Expiry

    @Test("300 ms pitch history expiry vs 1000 ms target identity expiry")
    func pitchHistoryVsTargetIdentityExpiry() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Acquire C4 (index 1) at t = 100, 120 ms
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 100)
        let r1 = tracker.push(frequency: 261.6, confidence: 0.99, time: 120)
        #expect(r1?.index == 1)
        #expect(tracker.current == 1)
        #expect(tracker.lastTime == 120)
        #expect(tracker.lastPitchTime == 120)

        // Silence for 350 ms: gap > 300 ms but <= 1000 ms.
        // At t = 470 ms:
        // pitch history is cleared, smoothed is reset to nil.
        // BUT target identity (current = 1) is NOT reset because elapsed (470 - 120 = 350) <= 1000 ms!
        let rAfter350 = tracker.push(frequency: 261.6, confidence: 0.99, time: 470)
        #expect(rAfter350 == nil) // smoothed == nil && time - lastTime > 300 requires 2 frames to re-acquire
        #expect(tracker.current == 1) // Target identity preserved!
        #expect(tracker.pending == 1)
        #expect(tracker.pendingCount == 1)

        // Second frame at t = 490 ms re-acquires smoothed reading
        let rReacquired = tracker.push(frequency: 261.6, confidence: 0.99, time: 490)
        #expect(rReacquired != nil)
        #expect(rReacquired?.index == 1)
        #expect(tracker.current == 1)
        #expect(tracker.lastTime == 490)

        // Now test 1000 ms display hold / identity expiry:
        // Silence for 1050 ms: next pitch arrives at t = 1540 ms (1540 - 490 = 1050 > 1000).
        // This triggers tracker.reset(), clearing current target identity!
        let rAfter1050 = tracker.push(frequency: 261.6, confidence: 0.99, time: 1540)
        #expect(rAfter1050 == nil)
        #expect(tracker.current == nil) // Target identity was completely reset!
        #expect(tracker.pending == 1)
        #expect(tracker.pendingCount == 1)

        // Second frame completes fresh acquisition
        let rFreshAcquired = tracker.push(frequency: 261.6, confidence: 0.99, time: 1560)
        #expect(rFreshAcquired != nil)
        #expect(tracker.current == 1)
    }

    // MARK: - 10. Reset Subsets & Low Confidence

    @Test("Reset preserves user configuration (tuning, auto, selected)")
    func resetPreservesConfiguration() {
        let tracker = FaithfulTracker()
        tracker.tuning = "low-g"
        tracker.auto = false
        tracker.selected = 2

        // Feed some frames
        _ = tracker.push(frequency: 329.6, confidence: 0.99, time: 0)
        _ = tracker.push(frequency: 329.6, confidence: 0.99, time: 20)
        #expect(tracker.current == 2)
        #expect(!tracker.history.isEmpty)
        #expect(tracker.smoothed != nil)

        // Perform explicit reset
        tracker.reset()

        // Verify configuration survives
        #expect(tracker.tuning == "low-g")
        #expect(tracker.auto == false)
        #expect(tracker.selected == 2)

        // Verify state is cleared
        #expect(tracker.current == nil)
        #expect(tracker.pending == nil)
        #expect(tracker.pendingCount == 0)
        #expect(tracker.history.isEmpty)
        #expect(tracker.smoothed == nil)
        #expect(tracker.lastTime == -.infinity)
        #expect(tracker.lastPitchTime == -.infinity)
    }

    @Test("Low confidence (<0.75) or nil pitch clears pending candidate without destroying current target")
    func lowConfidenceDropout() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"

        // Acquire C4 (index 1)
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 0)
        _ = tracker.push(frequency: 261.6, confidence: 0.99, time: 20)
        #expect(tracker.current == 1)

        // Start pending switch to A4 (index 3)
        _ = tracker.push(frequency: 440.0, confidence: 0.99, time: 100)
        #expect(tracker.pending == 3)
        #expect(tracker.pendingCount == 1)

        // Low confidence pitch arrives (confidence 0.5 < 0.75)
        let rLow = tracker.push(frequency: 440.0, confidence: 0.50, time: 120)
        #expect(rLow == nil)
        #expect(tracker.pending == nil) // Pending candidate cleared
        #expect(tracker.pendingCount == 0)
        #expect(tracker.current == 1) // Current target NOT destroyed!

        // Nil pitch arrives
        let rNil = tracker.push(pitch: nil, time: 140)
        #expect(rNil == nil)
        #expect(tracker.current == 1) // Still preserved
    }

    // MARK: - 11. Manual Mode

    @Test("Manual mode sticks to selected string ignoring nearest pitch")
    func manualModeSticksToSelected() {
        let tracker = FaithfulTracker()
        tracker.tuning = "standard"
        tracker.auto = false
        tracker.selected = 1 // C4

        // Pitch is near A4 (440 Hz), which would normally pick target 3 in auto mode
        _ = tracker.push(frequency: 440.0, confidence: 0.99, time: 0)
        let r1 = tracker.push(frequency: 440.0, confidence: 0.99, time: 20)

        // In manual mode, it must stick to target 1 (C4)
        #expect(r1 != nil)
        #expect(r1?.index == 1)
        #expect(r1?.note == "C4")
        #expect(r1?.stringNumber == 3)
        #expect(tracker.current == 1)

        // Now change selected string to target 2 (E4)
        tracker.selected = 2
        // In manual mode, switching strings does NOT wait 160 ms (only 2-frame vote)
        let rSwitch1 = tracker.push(frequency: 329.6, confidence: 0.99, time: 40)
        #expect(rSwitch1 == nil) // 1st frame pending
        let rSwitch2 = tracker.push(frequency: 329.6, confidence: 0.99, time: 60)
        #expect(rSwitch2 != nil) // 2nd frame acquires without 160 ms delay
        #expect(rSwitch2?.index == 2)
        #expect(rSwitch2?.note == "E4")
        #expect(tracker.current == 2)
    }

    // MARK: - 12. Positional Native String Mapping

    @Test("Positional String identity maps ukulele targets 0..3 to strings 4..1")
    func ukuleleStringNumberMapping() {
        #expect(FaithfulTracker.stringNumber(forIndex: 0, totalStrings: 4) == 4)
        #expect(FaithfulTracker.stringNumber(forIndex: 1, totalStrings: 4) == 3)
        #expect(FaithfulTracker.stringNumber(forIndex: 2, totalStrings: 4) == 2)
        #expect(FaithfulTracker.stringNumber(forIndex: 3, totalStrings: 4) == 1)

        // Slack tuning has two G4 targets: index 0 and index 3
        let tracker = FaithfulTracker()
        tracker.tuning = "slack"
        tracker.auto = false

        tracker.selected = 0
        _ = tracker.push(frequency: 392.0, confidence: 0.99, time: 0)
        let r0 = tracker.push(frequency: 392.0, confidence: 0.99, time: 20)
        #expect(r0?.index == 0)
        #expect(r0?.stringNumber == 4)
        #expect(tracker.currentStringNumber == 4)

        tracker.selected = 3
        _ = tracker.push(frequency: 392.0, confidence: 0.99, time: 40)
        let r3 = tracker.push(frequency: 392.0, confidence: 0.99, time: 60)
        #expect(r3?.index == 3)
        #expect(r3?.stringNumber == 1)
        #expect(tracker.currentStringNumber == 1)

        // String numbers are distinct (4 vs 1) even though MIDI notes and frequencies are identical
        #expect(r0?.note == r3?.note)
        #expect(r0?.stringNumber != r3?.stringNumber)
    }
}
