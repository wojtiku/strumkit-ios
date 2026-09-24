import SwiftUI

/// Settings sheet for reference frequency calibration, noise gate, and tolerance tuning.
public struct SettingsView: View {
    @Bindable var viewModel: TunerViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: TunerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Form {
                // Section 1: Reference Pitch Calibration (A4)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Concert Pitch A4")
                                .font(.body.weight(.medium))
                            Spacer()
                            Text("\(String(format: "%.1f", viewModel.configuration.referenceA4)) Hz")
                                .font(.system(.body, design: .monospaced, weight: .bold))
                                .foregroundStyle(TunerTheme.inTune)
                        }

                        Slider(
                            value: Binding(
                                get: { viewModel.configuration.referenceA4 },
                                set: { viewModel.updateReferenceA4($0) }
                            ),
                            in: 430.0...450.0,
                            step: 0.5
                        )
                        .tint(TunerTheme.inTune)

                        HStack(spacing: 12) {
                            Button("432.0 Hz (Verdi)") {
                                viewModel.updateReferenceA4(432.0)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)

                            Button("440.0 Hz (Standard)") {
                                viewModel.updateReferenceA4(440.0)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(TunerTheme.surfaceElevated)
                            .font(.caption)

                            Button("442.0 Hz (Orchestral)") {
                                viewModel.updateReferenceA4(442.0)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Pitch Calibration")
                } footer: {
                    Text("Standard concert pitch is 440 Hz. 432 Hz is popular for acoustic and meditation music.")
                }

                // Section 2: Tuning Precision
                Section {
                    Picker("In-Tune Tolerance", selection: $viewModel.configuration.inTuneToleranceCents) {
                        Text("±1.5 cents (Pro / Studio)").tag(1.5)
                        Text("±3.0 cents (Standard)").tag(3.0)
                        Text("±5.0 cents (Relaxed)").tag(5.0)
                    }

                    Toggle("Auto-Detect Strings", isOn: $viewModel.configuration.autoDetectString)
                } header: {
                    Text("Accuracy & Behavior")
                }

                // Section 3: Audio DSP & Noise Gate
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Noise Gate (Sensitivity)")
                            Spacer()
                            Text(String(format: "%.3f", viewModel.configuration.noiseGateRMS))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $viewModel.configuration.noiseGateRMS,
                            in: 0.005...0.040,
                            step: 0.002
                        )
                    }
                } header: {
                    Text("Microphone Filtering")
                } footer: {
                    Text("Increase threshold in noisy rehearsal spaces to prevent ambient room noise from triggering the tuner.")
                }

                // Section 4: Pro Tuning Tips
                Section("Tuner Pro Tips") {
                    TipRow(
                        icon: "arrow.up.circle.fill",
                        title: "Always Tune Up",
                        description: "If your string is sharp, drop it below pitch first, then tune up to lock string tension around the tuning peg."
                    )
                    TipRow(
                        icon: "speaker.wave.2.fill",
                        title: "Tune by Ear",
                        description: "Tap the speaker icon on any string peg to play pure reference sine wave tones."
                    )
                    TipRow(
                        icon: "hand.raised.fill",
                        title: "Mute Unplayed Strings",
                        description: "Rest your palm across unplayed strings so sympathetic vibrations don't confuse pitch detection."
                    )
                }
            }
            .navigationTitle("Tuner Settings")
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

private struct TipRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(TunerTheme.inTune)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
