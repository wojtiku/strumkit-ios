import SwiftUI

/// Mode bar matching chorder: tabs for Auto / Guided / Chromatic and Precision ±2¢ / ±5¢ toggle.
struct HardwareModeBarView: View {
    let mode: TunerMode
    let precision: Bool
    let onSelectMode: (TunerMode) -> Void
    let onTogglePrecision: () -> Void

    init(
        mode: TunerMode,
        precision: Bool,
        onSelectMode: @escaping (TunerMode) -> Void,
        onTogglePrecision: @escaping () -> Void
    ) {
        self.mode = mode
        self.precision = precision
        self.onSelectMode = onSelectMode
        self.onTogglePrecision = onTogglePrecision
    }

    var body: some View {
        HStack(spacing: 8) {
            // Mode Tabs (Auto, Guided, Chromatic)
            HStack(spacing: 2) {
                ModeTabButton(title: "Auto", isSelected: mode == .auto || mode == .manual) {
                    onSelectMode(.auto)
                }
                ModeTabButton(title: "Guided", isSelected: mode == .guided) {
                    onSelectMode(.guided)
                }
                ModeTabButton(title: "Chromatic", isSelected: mode == .chromatic) {
                    onSelectMode(.chromatic)
                }
            }
            .padding(2)
            .background(TunerTheme.surface)
            .clipShape(Capsule())

            Spacer()

            // Precision Toggle Button
            Button(action: onTogglePrecision) {
                HStack(spacing: 4) {
                    Text("Precision")
                        .font(.caption.weight(.semibold))
                    Text(precision ? "±2¢" : "±5¢")
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(precision ? TunerTheme.inTune : .secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(precision ? TunerTheme.inTune.opacity(0.15) : TunerTheme.surface)
                .overlay(
                    Capsule()
                        .stroke(precision ? TunerTheme.inTune : Color.clear, lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }
}

private struct ModeTabButton: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.caption.weight(isSelected ? .bold : .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? TunerTheme.surfaceElevated : Color.clear)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
