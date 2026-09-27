import SwiftUI
import QuartzCore

/// Master Tuner view implementing the complete chorder native instrument tuner.
struct TunerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = TunerViewModel.live()
    @State private var isShowingSettings = false

    init() {}

    /// The String the readout should name as the thing being aimed at.
    ///
    /// In the guided and locked modes the player has already chosen a String and the
    /// answer does not depend on what is sounding. In auto mode the answer is whatever
    /// String the current Reading is measured against — and a chromatic Reading is
    /// measured against nothing, so there is no String to name. That is not a gap to
    /// fill with a placeholder: the readout says EQUAL TEMP in that case, which is a
    /// truer description than any String would be.
    private var activeTarget: StringTarget? {
        if viewModel.config.mode == .guided {
            let index = min(viewModel.guidedTargetIndex, viewModel.targets.count - 1)
            return viewModel.targets[index]
        } else if viewModel.config.mode == .manual {
            let index = min(viewModel.config.selectedString, viewModel.targets.count - 1)
            return viewModel.targets[index]
        }
        guard case .target(let target, _) = viewModel.currentReading?.aim else { return nil }
        return target
    }

    /// The String the grid should highlight as the one being tuned.
    ///
    /// Auto mode follows the Reading, and a chromatic Reading names a Note rather than a
    /// String, so nothing is highlighted — there is no String on the instrument the
    /// player is currently being told to reach for.
    private var highlightedStringIndex: Int? {
        if viewModel.config.mode == .guided { return viewModel.guidedTargetIndex }
        if viewModel.config.mode == .manual { return viewModel.config.selectedString }
        guard case .target(let target, _) = viewModel.currentReading?.aim else { return nil }
        return viewModel.targets.firstIndex(of: target)
    }

    /// Whether the display may declare a String in tune right now.
    ///
    /// `false` in chromatic mode, where the Reading carries no verdict to show. The
    /// gauge then colours the needle by the direction of the deviation instead of
    /// turning green, and the haptic never fires — a chromatic tuner has no peg to
    /// tell anyone about.
    private var showsInTuneVerdict: Bool {
        viewModel.currentReading?.inTune ?? false
    }

    /// When the display recomputes the hold fade.
    ///
    /// Only a Held reading fades, so that is the only time the timeline needs to run:
    /// paused whenever the Reading is Fresh or absent, there is nothing to recompute and
    /// nothing running to recompute it with. The floor on the interval is the rate the
    /// fade was previously polled at, so a given moment of the hold still looks the
    /// same — the ticks now belong to the display rather than to the ViewModel.
    private var holdFadeSchedule: AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 30.0, paused: viewModel.currentReading?.freshness != .held)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TunerTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    // 1. Header (Instrument switch & Tuning preset)
                    headerControls

                    // 2. Hardware Display (Gauge, Readout, Guidance)
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
                        selectedIndex: highlightedStringIndex,
                        mode: viewModel.config.mode,
                        guidedProgress: viewModel.guidedProgress,
                        activeToneIndex: viewModel.activeToneStringIndex,
                        onToggleLock: { viewModel.toggleStringLock(index: $0) },
                        onUnlock: { viewModel.unlockString() },
                        onPlayTone: { viewModel.playReferenceTone(index: $0) },
                        onResetGuided: { viewModel.resetGuidedSession() }
                    )
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Tuner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    Task {
                        await viewModel.start()
                    }
                case .inactive:
                    if viewModel.engineStatus != .requesting {
                        viewModel.stop()
                    }
                case .background:
                    viewModel.stop()
                @unknown default:
                    break
                }
            }
            // Haptic trigger when crossing into tune. Only a Reading that names a
            // String can be "into tune"; in chromatic mode the trigger stays nil and
            // the player is never told they have arrived somewhere.
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

            // Hardware 21-tick Gauge and the readout fade together, off one timeline, so
            // the two halves of the display never disagree about how far through the
            // hold they are. A Held reading is a memory of a Fresh one, and how faded it
            // is belongs to the display's own lifetime: the fade is a function of the
            // Reading's last-fresh time and the timeline's date, so nothing has to wake
            // up to recompute it.
            TimelineView(holdFadeSchedule) { _ in
                // CACurrentMediaTime, not the timeline's `Date`, because that is the clock
                // a Reading's `lastFreshAt` is stamped on. Comparing the two would make
                // the fade a function of how far apart the clocks happen to read.
                let holdFade = TunerPresentation.holdOpacity(
                    for: viewModel.currentReading,
                    now: CACurrentMediaTime()
                )

                VStack(spacing: 12) {
                    HardwareGaugeView(
                        cents: viewModel.currentReading?.displayCents ?? 0,
                        visible: viewModel.currentReading != nil,
                        inTune: showsInTuneVerdict,
                        needleOpacity: viewModel.needleOpacity(holdFade: holdFade)
                    )
                    .padding(.horizontal, 12)

                    HardwareReadoutView(
                        reading: viewModel.currentReading,
                        lastTone: viewModel.lastTone,
                        feedback: viewModel.feedbackState,
                        precision: viewModel.config.precision,
                        selectedTarget: activeTarget,
                        mode: viewModel.config.mode,
                        holdOpacity: holdFade
                    )
                    .padding(.bottom, viewModel.engineStatus.guidanceError == nil ? 14 : 2)
                }
            }

            // Error Message (if permission denied or audio interrupted)
            if let errorMsg = viewModel.engineStatus.guidanceError {
                if viewModel.engineStatus == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(TunerTheme.sharp)
                            .multilineTextAlignment(.center)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                } else {
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(TunerTheme.sharp)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
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
