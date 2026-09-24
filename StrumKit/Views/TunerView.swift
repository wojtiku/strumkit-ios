import SwiftUI

/// Master Tuner view implementing the complete chorder native instrument tuner.
public struct TunerView: View {
    @State private var viewModel = TunerViewModel()
    @State private var isShowingSettings = false
    @State private var isHistoryExpanded = false

    public init() {}

    private var activeTarget: StringTarget? {
        if viewModel.config.mode == .guided {
            let index = min(viewModel.guidedTargetIndex, viewModel.targets.count - 1)
            return viewModel.targets[index]
        } else if viewModel.config.mode == .manual {
            let index = min(viewModel.config.selectedString, viewModel.targets.count - 1)
            return viewModel.targets[index]
        }
        return viewModel.currentReading?.target
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                TunerTheme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // 1. Header (Instrument switch & Tuning preset)
                        headerControls

                        // 2. Hardware Display (Gauge, Readout, Guidance, Start/Stop)
                        hardwareDisplaySection

                        // 3. Mode Bar (Auto, Guided, Chromatic & Precision toggle)
                        HardwareModeBarView(
                            mode: viewModel.config.mode,
                            precision: viewModel.config.precision,
                            onSelectMode: { viewModel.setMode($0) },
                            onTogglePrecision: { viewModel.togglePrecision() }
                        )

                        // 4. Reference Strings Section
                        HardwareStringGridView(
                            targets: viewModel.targets,
                            selectedIndex: viewModel.config.mode == .guided ? viewModel.guidedTargetIndex : (viewModel.config.mode == .manual ? viewModel.config.selectedString : viewModel.currentReading?.targetIndex),
                            mode: viewModel.config.mode,
                            guidedProgress: viewModel.guidedProgress,
                            activeToneIndex: viewModel.activeToneStringIndex,
                            onToggleLock: { viewModel.toggleStringLock(index: $0) },
                            onUnlock: { viewModel.unlockString() },
                            onPlayTone: { viewModel.playReferenceTone(index: $0) },
                            onResetGuided: { viewModel.resetGuidedSession() }
                        )

                        // 5. Expandable Pitch History Strip
                        DisclosureGroup(isExpanded: $isHistoryExpanded) {
                            PitchHistoryGraphView(history: viewModel.history)
                                .padding(.top, 6)
                        } label: {
                            Label("Pitch History (7s)", systemImage: "waveform.path.ecg")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(TunerTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)

                        // 6. Privacy Footer
                        Text("Audio stays on your device. No recordings, uploads, or account needed.")
                            .font(.system(size: 11))
                            .foregroundStyle(TunerTheme.gaugeTickMinor)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.bottom, 16)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Tuner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("One string. A clear reading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline)
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(viewModel: viewModel)
            }
            .task {
                await viewModel.start()
            }
            // Haptic trigger when crossing into tune
            .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.currentReading?.inTune) { oldVal, newVal in
                newVal == true && oldVal == false
            }
        }
    }

    // MARK: - Header Controls
    private var headerControls: some View {
        HStack(spacing: 12) {
            // Instrument Switch Tabs (Guitar / Ukulele)
            HStack(spacing: 2) {
                ForEach(InstrumentCategory.allCases) { inst in
                    let isSelected = viewModel.config.instrument == inst
                    Button {
                        viewModel.setInstrument(inst)
                    } label: {
                        Text(inst.label)
                            .font(.caption.weight(isSelected ? .bold : .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(isSelected ? TunerTheme.surfaceElevated : Color.clear)
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(TunerTheme.surface)
            .clipShape(Capsule())

            Spacer()

            // Tuning Preset Menu
            Menu {
                ForEach(Presets.presets(for: viewModel.config.instrument)) { preset in
                    Button {
                        viewModel.setTuningPreset(id: preset.id)
                    } label: {
                        HStack {
                            Text(preset.label)
                            if viewModel.config.tuningId == preset.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    viewModel.setTuningPreset(id: "custom")
                } label: {
                    HStack {
                        Text("Custom tuning")
                        if viewModel.config.tuningId == "custom" {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tuningTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TunerTheme.surface)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 20)
    }

    private var tuningTitle: String {
        if viewModel.config.tuningId == "custom" { return "Custom" }
        let presets = Presets.presets(for: viewModel.config.instrument)
        return presets.first(where: { $0.id == viewModel.config.tuningId })?.label.components(separatedBy: " · ").first ?? "Tuning"
    }

    // MARK: - Hardware Display Card
    private var hardwareDisplaySection: some View {
        VStack(spacing: 12) {
            // Status Sub-header
            HStack {
                // Live status dot + title
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.engineStatus == .listening ? TunerTheme.inTune : TunerTheme.neutral)
                        .frame(width: 8, height: 8)
                        .shadow(color: viewModel.engineStatus == .listening ? TunerTheme.inTune.opacity(0.8) : Color.clear, radius: 4)

                    Text(viewModel.engineStatus.displayTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(viewModel.engineStatus == .listening ? .primary : .secondary)
                }

                Spacer()

                // Mode status pill
                Text(modeStatusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // Hardware 21-tick Gauge
            HardwareGaugeView(
                cents: viewModel.currentReading?.displayCents ?? 0,
                visible: viewModel.currentReading != nil || viewModel.lastTone != nil,
                inTune: viewModel.currentReading?.inTune ?? false
            )
            .padding(.horizontal, 12)

            // Readout (Note, Superscript, Formatted Cents, Guidance, Frequencies)
            HardwareReadoutView(
                reading: viewModel.currentReading,
                lastTone: viewModel.lastTone,
                feedback: viewModel.feedbackState,
                precision: viewModel.config.precision,
                selectedTarget: activeTarget,
                mode: viewModel.config.mode
            )

            // Big Start / Stop Tuning Button
            Button {
                Task {
                    await viewModel.toggleListening()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.engineStatus == .listening ? "stop.fill" : "mic.fill")
                        .font(.subheadline)
                    Text(viewModel.engineStatus == .listening ? "Stop tuning" : (viewModel.engineStatus == .requesting ? "Cancel request" : "Start tuning"))
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(viewModel.engineStatus == .listening ? TunerTheme.surfaceElevated : TunerTheme.inTune)
                .foregroundStyle(viewModel.engineStatus == .listening ? Color.white : Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Error Message (if permission denied or audio interrupted)
            if let errorMsg = viewModel.engineStatus.guidanceError {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(TunerTheme.sharp)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(TunerTheme.surface)
        )
        .padding(.horizontal, 16)
    }

    private var modeStatusLabel: String {
        if viewModel.config.guided {
            let num = viewModel.targets[min(viewModel.guidedTargetIndex, viewModel.targets.count - 1)].number
            return "Guided · String \(num)"
        } else if viewModel.config.mode == .manual {
            let num = viewModel.targets[min(viewModel.config.selectedString, viewModel.targets.count - 1)].number
            return "Locked · String \(num)"
        } else if viewModel.config.mode == .chromatic {
            return "Chromatic"
        } else {
            return "Auto detect"
        }
    }
}
