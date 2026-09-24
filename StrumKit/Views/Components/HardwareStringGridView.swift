import SwiftUI

/// Reference strings section matching chorder's string grid, locked state, checkmarks, and tone buttons.
public struct HardwareStringGridView: View {
    let targets: [StringTarget]
    let selectedIndex: Int?
    let mode: TunerMode
    let guidedProgress: [Bool]
    let activeToneIndex: Int?
    let onToggleLock: (Int) -> Void
    let onUnlock: () -> Void
    let onPlayTone: (Int) -> Void
    let onResetGuided: () -> Void

    public init(
        targets: [StringTarget],
        selectedIndex: Int?,
        mode: TunerMode,
        guidedProgress: [Bool],
        activeToneIndex: Int?,
        onToggleLock: @escaping (Int) -> Void,
        onUnlock: @escaping () -> Void,
        onPlayTone: @escaping (Int) -> Void,
        onResetGuided: @escaping () -> Void
    ) {
        self.targets = targets
        self.selectedIndex = selectedIndex
        self.mode = mode
        self.guidedProgress = guidedProgress
        self.activeToneIndex = activeToneIndex
        self.onToggleLock = onToggleLock
        self.onUnlock = onUnlock
        self.onPlayTone = onPlayTone
        self.onResetGuided = onResetGuided
    }

    private var captionText: String {
        switch mode {
        case .chromatic: "Reference tones"
        case .guided: "Tune each string until it is checked"
        case .manual: "Tap a note to unlock string"
        case .auto: "Tap a note to lock a string"
        }
    }

    public var body: some View {
        VStack(spacing: 10) {
            // Caption Header
            HStack {
                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if mode == .manual {
                    Button("Unlock string", action: onUnlock)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TunerTheme.inTune)
                }
            }
            .padding(.horizontal, 20)

            // String Grid
            HStack(spacing: 6) {
                ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                    let isSelected = (selectedIndex == index && mode != .chromatic)
                    let isChecked = (index < guidedProgress.count && guidedProgress[index])
                    let isPlayingTone = (activeToneIndex == index)

                    StringCardView(
                        target: target,
                        isSelected: isSelected,
                        isChecked: isChecked,
                        isPlayingTone: isPlayingTone,
                        isManualLocked: mode == .manual && isSelected,
                        onTapLock: { onToggleLock(index) },
                        onTapTone: { onPlayTone(index) }
                    )
                }
            }
            .padding(.horizontal, 16)

            // Guided Mode Progress Bar & Restart Button
            if mode == .guided {
                let checkedCount = guidedProgress.filter { $0 }.count
                let allChecked = checkedCount == targets.count && !targets.isEmpty

                HStack {
                    Text("\(checkedCount) of \(targets.count) checked this session\(allChecked ? ". All strings checked!" : "")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(allChecked ? TunerTheme.inTune : .secondary)

                    Spacer()

                    Button {
                        onResetGuided()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Restart")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }

            // Reference tone hint
            if activeToneIndex != nil {
                Text("Reference tone playing. Pluck along or press Start tuning when ready.")
                    .font(.caption2)
                    .foregroundStyle(TunerTheme.sharp)
                    .padding(.top, 2)
            }
        }
    }
}

private struct StringCardView: View {
    let target: StringTarget
    let isSelected: Bool
    let isChecked: Bool
    let isPlayingTone: Bool
    let isManualLocked: Bool
    let onTapLock: () -> Void
    let onTapTone: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            // String Lock Button
            Button(action: onTapLock) {
                VStack(spacing: 2) {
                    Text("String \(target.number)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? TunerTheme.inTune : .secondary)

                    Text(target.note)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)

                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(TunerTheme.inTune)
                            .frame(height: 14)
                    } else if isManualLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(TunerTheme.flat)
                            .frame(height: 14)
                    } else {
                        Text("\(String(format: "%.0f", target.frequency))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(height: 14)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Reference Tone Pluck Button
            Button(action: onTapTone) {
                Image(systemName: isPlayingTone ? "speaker.wave.3.fill" : "speaker.wave.1")
                    .font(.system(size: 11))
                    .foregroundStyle(isPlayingTone ? TunerTheme.sharp : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(isPlayingTone ? TunerTheme.sharp.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? TunerTheme.inTune.opacity(0.18) : TunerTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? TunerTheme.inTune : Color.clear, lineWidth: 1.5)
                )
        )
    }
}
