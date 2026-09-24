import SwiftUI

/// Horizontal row of instrument string peg buttons allowing auto-detection or manual string locking.
public struct StringSelectorView: View {
    let tuning: Tuning
    let selectedStringNumber: Int?
    let targetString: TunedString?
    let autoDetect: Bool
    let playingToneStringNumber: Int?
    let onSelectString: (TunedString?) -> Void
    let onToggleTone: (TunedString) -> Void

    public init(
        tuning: Tuning,
        selectedStringNumber: Int?,
        targetString: TunedString?,
        autoDetect: Bool,
        playingToneStringNumber: Int?,
        onSelectString: @escaping (TunedString?) -> Void,
        onToggleTone: @escaping (TunedString) -> Void
    ) {
        self.tuning = tuning
        self.selectedStringNumber = selectedStringNumber
        self.targetString = targetString
        self.autoDetect = autoDetect
        self.playingToneStringNumber = playingToneStringNumber
        self.onSelectString = onSelectString
        self.onToggleTone = onToggleTone
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Mode Indicator / Auto Toggle Header
            HStack {
                Text("STRINGS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onSelectString(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: autoDetect ? "bolt.fill" : "hand.tap.fill")
                            .font(.caption2)
                        Text(autoDetect ? "Auto Detect" : "Locked")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(autoDetect ? TunerTheme.inTune.opacity(0.2) : TunerTheme.surfaceElevated)
                    .foregroundStyle(autoDetect ? TunerTheme.inTune : .primary)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)

            // String Buttons Carousel / Grid
            if !tuning.strings.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tuning.strings) { item in
                        let isHighlighted = (targetString?.stringNumber == item.stringNumber)
                        let isLocked = (selectedStringNumber == item.stringNumber)
                        let isPlayingTone = (playingToneStringNumber == item.stringNumber)

                        StringPegButton(
                            string: item,
                            isHighlighted: isHighlighted,
                            isLocked: isLocked,
                            isPlayingTone: isPlayingTone,
                            onTap: {
                                onSelectString(item)
                            },
                            onToneTap: {
                                onToggleTone(item)
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct StringPegButton: View {
    let string: TunedString
    let isHighlighted: Bool
    let isLocked: Bool
    let isPlayingTone: Bool
    let onTap: () -> Void
    let onToneTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                // String Number Label
                Text("\(string.stringNumber)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isHighlighted ? TunerTheme.inTune : .secondary)

                // Note Name (e.g. E, A, D)
                Text(string.note.noteName.rawValue)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(isHighlighted ? .white : .primary)

                // Octave (e.g. 2, 4)
                Text("\(string.note.octave)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                // Pitch pipe reference tone button
                Button(action: onToneTap) {
                    Image(systemName: isPlayingTone ? "speaker.wave.3.fill" : "speaker.wave.1")
                        .font(.system(size: 11))
                        .foregroundStyle(isPlayingTone ? TunerTheme.sharp : .secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHighlighted ? TunerTheme.inTune.opacity(0.25) : TunerTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isHighlighted ? TunerTheme.inTune : (isLocked ? TunerTheme.flat : Color.clear),
                                lineWidth: 2
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
