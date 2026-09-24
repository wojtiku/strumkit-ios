import SwiftUI

/// Main dashboard view for StrumKit guitar and ukulele tuner.
public struct TunerView: View {
    @State private var viewModel = TunerViewModel()
    @State private var isShowingSettings = false

    public init() {}

    public var body: some View {
        ZStack {
            TunerTheme.background
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Header: Instrument Selector & Tuning Menu
                headerView

                // Permission Warning (if microphone denied)
                if viewModel.permissionStatus == .denied {
                    permissionWarningBanner
                }

                Spacer()

                // Hero Note & Frequency Readout
                NoteDisplayView(
                    note: viewModel.currentPitch.closestNote,
                    targetNote: viewModel.targetString?.note,
                    frequency: viewModel.currentPitch.frequency,
                    cents: viewModel.smoothedCents,
                    isInTune: viewModel.isInTune,
                    isSignalPresent: viewModel.currentPitch.isSignalPresent,
                    tolerance: viewModel.configuration.inTuneToleranceCents
                )

                // High-Precision Tuner Dial Gauge
                TunerDialView(
                    cents: viewModel.smoothedCents,
                    isInTune: viewModel.isInTune,
                    isSignalPresent: viewModel.currentPitch.isSignalPresent,
                    tolerance: viewModel.configuration.inTuneToleranceCents
                )
                .padding(.horizontal, 20)

                Spacer()

                // String Peg Selector (Guitar / Ukulele Strings)
                StringSelectorView(
                    tuning: viewModel.selectedTuning,
                    selectedStringNumber: viewModel.configuration.selectedStringNumber,
                    targetString: viewModel.targetString,
                    autoDetect: viewModel.configuration.autoDetectString,
                    playingToneStringNumber: viewModel.playingReferenceToneStringNumber,
                    onSelectString: { string in
                        viewModel.selectString(string)
                    },
                    onToggleTone: { string in
                        viewModel.togglePitchPipe(for: string)
                    }
                )

                // Real-time Audio Level & Noise Gate Meter
                AudioLevelMeter(
                    amplitudeRMS: viewModel.currentPitch.amplitudeRMS,
                    noiseGateThreshold: viewModel.configuration.noiseGateRMS,
                    isListening: viewModel.isListening
                )
                .padding(.bottom, 8)
            }
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .task {
            await viewModel.start()
        }
        // Haptic tap whenever string locks in-tune
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: viewModel.isInTune) { oldValue, newValue in
            newValue == true && oldValue == false
        }
    }

    // MARK: - Header Controls
    private var headerView: some View {
        HStack(spacing: 12) {
            // Instrument Selector Menu
            Menu {
                ForEach(viewModel.availableInstruments) { instrument in
                    Button {
                        viewModel.selectInstrument(instrument)
                    } label: {
                        Label(instrument.name, systemImage: instrument.type.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.selectedInstrument.type.systemImage)
                        .foregroundStyle(TunerTheme.inTune)
                    Text(viewModel.selectedInstrument.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TunerTheme.surface)
                .clipShape(Capsule())
            }

            // Tuning Preset Picker (if instrument has tunings)
            if !viewModel.selectedInstrument.tunings.isEmpty {
                Menu {
                    ForEach(viewModel.selectedInstrument.tunings) { tuning in
                        Button {
                            viewModel.selectTuning(tuning)
                        } label: {
                            HStack {
                                Text(tuning.name)
                                if tuning.id == viewModel.selectedTuning.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.selectedTuning.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(TunerTheme.surface)
                    .clipShape(Capsule())
                }
            }

            Spacer()

            // Settings Sheet Button
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(TunerTheme.surface)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Permission Warning Banner
    private var permissionWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Microphone permission denied. Enable microphone in iOS Settings to detect pitch.")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }
}
