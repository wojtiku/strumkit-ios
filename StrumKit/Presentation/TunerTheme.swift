import SwiftUI

/// Visual styling and color palette for StrumKit.
enum TunerTheme {
    // Dark stage-ready canvas colors
    static let background = Color(red: 0.05, green: 0.07, blue: 0.09)
    static let surface = Color(red: 0.10, green: 0.13, blue: 0.17)
    static let surfaceElevated = Color(red: 0.14, green: 0.18, blue: 0.24)

    // Tuning status accents
    static let inTune = Color(red: 0.18, green: 0.88, blue: 0.54) // Emerald Mint
    static let flat = Color(red: 0.24, green: 0.68, blue: 0.98)   // Azure Cyan
    static let sharp = Color(red: 1.00, green: 0.52, blue: 0.20)  // Vivid Amber
    static let neutral = Color(red: 0.50, green: 0.55, blue: 0.63)

    // Gauge track colors
    static let gaugeTrack = Color(red: 0.18, green: 0.22, blue: 0.29)
    /// The only tick colour the gauge draws — every tick on it is a minor one.
    static let gaugeTickMinor = Color(red: 0.35, green: 0.40, blue: 0.48)
}
