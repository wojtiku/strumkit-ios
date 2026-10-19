# StrumKit iOS — Physical Device & Real-World Instrument Testing Guide

**Document:** `DEVICE_TESTING.md`  
**Target Ticket:** 13 — Validate native capture, real-time cost and device experience  
**Target Build:** StrumKit Release (`make build` / Xcode Archive)  
**Authoritative Algorithm Source:** test-tuner `6a5a4f30304f392ff9dec9997633f83c295e1e1b`  
**Native Algorithm Modules:** `StrumKit/Algorithm/` (`FaithfulCaptureFraming`, `FaithfulStreamingDetector`, `FaithfulTargetTracker`, `FaithfulPublicationAdapter`)  

---

## 1. Objectives & Testing Scope

This guide establishes human physical verification for StrumKit running on real iOS hardware with physical acoustic instruments. Offline parity (Ticket 12, 282 cases / 31,495 frames) and automated real-time performance headroom (Ticket 13, > 97% headroom, zero dropped frames) have been proven.

This document guides the human tester through:
1. Physical acoustic instrument plucks (Ukulele G4, C4, E4, A4; Guitar Low E 82.4 Hz, Drop D 73.4 Hz).
2. Dynamic range validation: quiet onsets, fingerstyle plucks, and decaying tails down to ambient floor.
3. Tuning peg movements (3–15 cents) and exact 400 ms green confirmation.
4. Reference tone speaker isolation: verify playback cleanly pauses microphone capture and never self-triggers.
5. iOS lifecycle events: backgrounding, foregrounding, lock screen, route changes (built-in mic, AirPods/Bluetooth, wired headset), and audio interruptions (phone call, Siri, alarm).

---

## 2. Test Environment & Apparatus Setup

Record the following metadata before executing the physical test runs:

| Parameter | Recorded Value / Notes |
| :--- | :--- |
| **Physical Device Model** | e.g. iPhone 15 Pro / iPhone 14 / iPad Air |
| **iOS Version** | e.g. iOS 18.2 / iOS 17.5 |
| **Hardware Input Route** | Built-in Bottom Microphone / Built-in Front Microphone / Headset Mic |
| **Hardware Sample Rate** | 44,100 Hz or 48,000 Hz |
| **Room Condition** | Quiet indoor room (ambient floor < 40 dBA) / typical living room |
| **App Build Hash** | Commit SHA (`git rev-parse HEAD`) |
| **Build Configuration** | Release (`-O`, whole-module optimization) |

---

## 3. Physical Test Protocols

### Protocol 1: Real Ukulele Plucks (Standard High-G / Low-G Tuning)

*Objective:* Verify clean string acquisition, octave accuracy, and responsiveness across all 4 ukulele strings.

*Instrument:* Soprano, Concert, or Tenor Ukulele in Standard Tuning (G4 = 392.00 Hz, C4 = 261.63 Hz, E4 = 329.63 Hz, A4 = 440.00 Hz).

1. **Launch App:** Open StrumKit on the device. Ensure **Ukulele** instrument and **Standard** tuning are selected in Auto mode.
2. **String 4 (G4 - 392.00 Hz):**
   - Pluck String 4 firmly with thumb/pick.
   - *Expected:* Needle jumps promptly (< 100 ms) to Target "G4". Deviation displays accurately in cents. No octave jumping to G3 or G5.
3. **String 3 (C4 - 261.63 Hz):**
   - Pluck String 3.
   - *Expected:* Target transitions immediately to "C4". C4 fundamental is cleanly identified despite rich 2nd/3rd harmonics.
4. **String 2 (E4 - 329.63 Hz):**
   - Pluck String 2.
   - *Expected:* Target transitions cleanly to "E4".
5. **String 1 (A4 - 440.00 Hz):**
   - Pluck String 1.
   - *Expected:* Target transitions cleanly to "A4".
6. **String Switching & Damping:**
   - Pluck String 4, let it ring for 1 second, then mute it with your palm and immediately pluck String 1.
   - *Expected:* Old note holds smoothly for presentation hold duration; new pluck immediately overrides hold and acquires String 1 without ghost target fluttering.

- [ ] String 4 (G4) acquired cleanly without octave error
- [ ] String 3 (C4) acquired cleanly
- [ ] String 2 (E4) acquired cleanly
- [ ] String 1 (A4) acquired cleanly
- [ ] Rapid string switching smoothly switches targets

---

### Protocol 2: Guitar Low E (82.4 Hz) & Drop D / Drop A (Extended Range)

*Objective:* Verify low-frequency pitch detection down to 73.4 Hz (Drop D) and 82.4 Hz (Guitar Low E2) using the extended-range engine profile.

*Instrument:* Acoustic or Electric Guitar (unplugged or mic'd near soundhole).

1. **Switch Instrument:** In StrumKit, select **Guitar** -> **Standard Tuning**.
2. **Low E String (E2 - 82.41 Hz):**
   - Pluck the low 6th string (E2).
   - *Expected:* Tuner acquires Target "E2" (82.4 Hz). Low fundamental is identified without doubling to 164.8 Hz (E3) or tripling.
3. **Drop D Mode:**
   - Select **Drop D** tuning preset (D2 = 73.42 Hz on 6th string).
   - Pluck the dropped 6th string tuned to D2.
   - *Expected:* Needle locks onto Target "D2" (73.42 Hz) stably down to low E boundary.
4. **Ukulele Guardband Verification:**
   - Switch back to **Ukulele** preset.
   - Pluck guitar low E2 (82.4 Hz).
   - *Expected:* Ukulele profile strictly ignores/rejects audio below 110 Hz. Needle does not latch onto low guitar frequency as a false ukulele target.

- [ ] Guitar Low E2 (82.4 Hz) detected stably without octave doubling
- [ ] Guitar Drop D (73.4 Hz) acquired cleanly in extended mode
- [ ] Ukulele profile rejects sub-110 Hz guitar plucks

---

### Protocol 3: Dynamic Range — Quiet Onsets & Decaying Tails

*Objective:* Verify tuner sensitivity to soft fingerstyle playing, gradual decay, and proper return to ready state at the noise floor.

1. **Quiet Plucks:**
   - Pluck the ukulele A4 string very softly (finger flesh, minimal velocity, ~30–40 dB above noise floor).
   - *Expected:* Onset is captured promptly. Feedback indicator shows `.tracking`. Reading appears with valid pitch.
2. **Sustained Decaying Tail:**
   - Pluck a clean open C4 string and allow it to ring out naturally over 4 to 8 seconds without muting.
   - *Expected:*
     - During strong vibration (0–3 s): Needle remains bright and responsive (`.measured` evidence).
     - During decay tail (3–6 s): As harmonic energy drops, display smoothly shifts to `.sustained` (dimmed needle) while holding pitch steady without erratic cent fluctuation.
     - At silence/decay limit (> 6 s): Reading smoothly expires into hold presentation and fades to inactive state. No erratic jumping from ambient room noise.

- [ ] Very soft / quiet plucks detect reliably
- [ ] Decaying tail holds pitch smoothly without erratic needle flutter
- [ ] Tuner gracefully drops to ready/idle when string sound falls into room noise floor

---

### Protocol 4: Peg Adjustments (3–15 Cents) & 400 ms Green Confirmation

*Objective:* Validate needle movement fidelity during physical peg turning and verify the 400 ms in-tune confirmation contract.

1. **Continuous Peg Turn (15 Cents Off):**
   - Detune a string ~15 cents flat. Pluck and slowly turn the tuning peg clockwise towards pitch.
   - *Expected:* The needle follows the mechanical tuning peg movement smoothly and monotonically in real time (< 25 ms update latency).
2. **Small Peg Movement (3–5 Cents):**
   - Make a micro-adjustment of 3 to 5 cents.
   - *Expected:* Needle reflects the 3–5 cent displacement accurately without sticking in dead-bands.
3. **In-Tune Confirmation Boundary (400 ms):**
   - Bring the string into the in-tune zone (within ±3 cents of target).
   - *Expected:*
     - During the first 100–380 ms inside ±3 cents, needle is green/centered but confirmation one-shot has not yet triggered.
     - At precisely 400 ms of sustained in-tune evidence, the target card illuminates green with confirmation feedback (haptic/visual one-shot).
   - Deliberately pitch-bend or detune out before 350 ms:
     - *Expected:* Confirmation does NOT fire; timer resets cleanly.

- [ ] Smooth needle tracking during physical peg turning
- [ ] Micro-adjustments (3–5 cents) clearly visible on gauge
- [ ] 400 ms continuous in-tune confirmation behaves strictly according to spec

---

### Protocol 5: Reference Tone Speaker Isolation & Feedback Prevention

*Objective:* Ensure acoustic playback of the synthesized reference tone never contaminates microphone capture or triggers false in-tune confirmations.

1. **Play Reference Tone:**
   - In StrumKit, tap the reference tone button for String 1 (A4 = 440 Hz). Turn device volume up to 80%.
   - *Expected:*
     - Clear, pleasant acoustic plucked reference tone plays through device speakers.
     - The tuner engine transitions immediately to `.paused` status.
     - The microphone tap is completely stopped (`source.stop()`).
     - Gauge needle and reading are immediately cleared (`currentReading == nil`).
2. **Acoustic Self-Contamination Verification:**
   - Observe the display while the loud reference tone is ringing from the device speaker.
   - *Expected:*
     - The tuner NEVER detects its own speaker output.
     - Needle NEVER flickers, acquires "A4", or triggers a false 400 ms in-tune confirmation.
3. **Automatic Resume on Tone Completion:**
   - Allow reference tone to finish playing.
   - *Expected:*
     - Tuner automatically resumes listening mode (`engineStatus == .listening`).
     - Microphone tap restarts cleanly without error.
4. **Rapid Tone Tap Protection:**
   - Tap reference tone buttons rapidly in succession (e.g. String 4 -> 3 -> 2 -> 1).
   - *Expected:* Previous playback cancels cleanly; new tone starts without audio glitching, feedback loops, or engine crash.

- [ ] Reference tone playback immediately pauses microphone capture
- [ ] Zero microphone self-detection or false in-tune confirmation during playback
- [ ] Clean automatic resume to listening after tone completion
- [ ] Rapid button tapping handled safely without audio engine stall

---

### Protocol 6: iOS Lifecycle, Route Changes & System Interruptions

*Objective:* Verify robustness across background/foreground transitions, audio interruptions, and hardware route switches.

1. **Background / Foreground Transition:**
   - While tuner is actively listening, swipe to home screen or lock device. Wait 5 seconds.
   - Return to StrumKit.
   - *Expected:* Audio capture stops cleanly in background. On returning to foreground, audio session resumes seamlessly and plucks are immediately detected.
2. **Audio Hardware Route Change:**
   - While strumming and observing active tuning:
     - Connect AirPods or plug in a wired headset.
     - *Expected:* Audio session absorbs `.routeChanged` event cleanly. Sample rate adapts if switching between 44.1 kHz and 48.0 kHz. Detection continues without restart lag or crash.
     - Disconnect AirPods / headset back to built-in microphone.
     - *Expected:* Capture cleanly restarts on built-in mic.
3. **Audio Interruption (Call / Alarm / Siri):**
   - Trigger Siri or place an incoming phone call to the device while the tuner is active.
   - *Expected:* Audio session receives `AVAudioSession.interruptionNotification`. Capture stops immediately.
   - Dismiss Siri / decline call.
   - *Expected:* Capture resumes automatically if listening was intentional; no stalled audio thread.

- [ ] Backgrounding / lock screen suspends audio capture cleanly
- [ ] Foregrounding resumes listening without user intervention
- [ ] Connecting / disconnecting AirPods or headset handles route change gracefully
- [ ] Audio interruption (Siri / Call) safely suspends and resumes engine

---

## 4. Acceptance Sign-off Matrix

| Test Suite | Result | Tested By | Date | Notes |
| :--- | :---: | :--- | :--- | :--- |
| **Ukulele Plucks (G4, C4, E4, A4)** | PASS / FAIL | | | |
| **Guitar Low E (82.4 Hz) & Drop D** | PASS / FAIL | | | |
| **Quiet Plucks & Decaying Tails** | PASS / FAIL | | | |
| **Peg Movement & 400ms Confirmation**| PASS / FAIL | | | |
| **Reference Tone Acoustic Isolation** | PASS / FAIL | | | |
| **Lifecycle & Route Interruptions** | PASS / FAIL | | | |

**Final Human Acceptance Sign-off:**  
Operator Name: _______________________  
Signature: ____________________________  
Date: _________________________________
