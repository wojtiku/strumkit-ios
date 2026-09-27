import SwiftUI

/// Settings sheet for reference pitch calibration, custom tunings, and audio diagnostics matching chorder.
struct SettingsView: View {
    @Bindable var viewModel: TunerViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: TunerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Reference Pitch Calibration (A4)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Reference pitch (A4)")
                                .font(.body.weight(.medium))
                            Spacer()
                            Text("\(String(format: "%.0f", viewModel.config.a4)) Hz")
                                .font(.system(.body, design: .monospaced, weight: .bold))
                                .foregroundStyle(TunerTheme.inTune)
                        }

                        HStack(spacing: 16) {
                            Button {
                                viewModel.updateA4(viewModel.config.a4 - 1)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title2)
                            }
                            .disabled(viewModel.config.a4 <= TunerConstants.minCalibrationHz)

                            Slider(
                                value: Binding(
                                    get: { viewModel.config.a4 },
                                    set: { viewModel.updateA4($0) }
                                ),
                                in: TunerConstants.minCalibrationHz...TunerConstants.maxCalibrationHz,
                                step: 1.0
                            )
                            .tint(TunerTheme.inTune)

                            Button {
                                viewModel.updateA4(viewModel.config.a4 + 1)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                            }
                            .disabled(viewModel.config.a4 >= TunerConstants.maxCalibrationHz)
                        }

                        HStack(spacing: 10) {
                            PresetA4Button(title: "415 Hz (Baroque)", hz: 415) { viewModel.updateA4(415) }
                            PresetA4Button(title: "432 Hz (Verdi)", hz: 432) { viewModel.updateA4(432) }
                            PresetA4Button(title: "440 Hz (Standard)", hz: 440) { viewModel.updateA4(440) }
                            PresetA4Button(title: "442 Hz", hz: 442) { viewModel.updateA4(442) }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Calibration")
                } footer: {
                    Text("Calibration affects every target and reference tone. Conventional instrument range is 415 to 466 Hz.")
                }

                // Section 2: Custom Tuning String Config (if custom selected)
                if viewModel.config.tuningId == "custom" {
                    Section("Custom Open-String Notes") {
                        ForEach(Array(viewModel.targets.enumerated()), id: \.offset) { index, target in
                            Picker("String \(target.number)", selection: Binding(
                                get: { viewModel.config.customMidi[index] },
                                set: { viewModel.updateCustomMidi(stringIndex: index, midi: $0) }
                            )) {
                                ForEach(Presets.customNotes, id: \.self) { midi in
                                    Text("\(PitchMath.midiNoteName(midi)) (\(String(format: "%.1f", PitchMath.midiFrequency(midi, a4: viewModel.config.a4))) Hz)")
                                        .tag(midi)
                                }
                            }
                        }
                    }
                }

                // Section 3: Audio Diagnostics
                Section("Microphone & Diagnostics") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Input Level")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(min(100, viewModel.diagnostics.level * 1000)))%")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(TunerTheme.surfaceElevated)
                                Capsule()
                                    .fill(TunerTheme.inTune)
                                    .frame(width: max(4, geo.size.width * CGFloat(min(1.0, viewModel.diagnostics.level * 10.0))))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)

                    LabeledContent("Capture Engine", value: "AVAudioEngine (.measurement)")
                    LabeledContent("Sample Rate", value: "\(Int(viewModel.diagnostics.sampleRate)) Hz")
                    LabeledContent("Analysis Latency", value: String(format: "%.1f ms", viewModel.diagnostics.analysisMs))
                    LabeledContent("Status", value: viewModel.engineStatus.displayTitle)

                    // The first thing to check when a detector "does nothing". A
                    // simulator audio client can start cleanly, report "Listening" with a
                    // live latency, and still deliver pure silence — indistinguishable
                    // from a broken algorithm unless the level is measured, not inferred.
                    let input = viewModel.inputLevel
                    LabeledContent("Measured input RMS", value: String(format: "%.7f", input.rms))
                    LabeledContent("Measured input peak", value: String(format: "%.7f", input.peak))
                    LabeledContent("Windows analysed", value: "\(input.frames)")
                    if input.frames > 30 && input.peak < 1e-5 {
                        Label {
                            Text("The capture tap is delivering silence. No detector can hear anything until real audio reaches it — this is an input problem, not an algorithm problem.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(TunerTheme.sharp)
                        }
                    }
                }

                // Section 4: Privacy Notice
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(TunerTheme.inTune)
                            .font(.title3)
                        Text("Audio stays entirely on your device. No recordings, uploads, or cloud accounts needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Tuning Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PresetA4Button: View {
    let title: String
    let hz: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(TunerTheme.surfaceElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
