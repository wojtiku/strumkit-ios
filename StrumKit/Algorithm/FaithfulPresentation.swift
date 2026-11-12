// StrumKit/Algorithm/FaithfulPresentation.swift
import Foundation

// MARK: - Faithful Presentation

/// Calm the display without reducing detector cadence or adding pitch latency.
///
/// Ported faithfully from `Tools/parity-contract/reference-source/presentation.ts`.
/// Throttles publication to at most 12 Hz (`time - lastDisplay < 1000.0 / 12.0`),
/// preserves the latest reading before throttling, and clears output to empty
/// after a 1000 ms display hold (`time - lastReading >= 1000.0`).
final class FaithfulPresentation: @unchecked Sendable {
    enum Action: Sendable, Equatable {
        case skipped
        case empty
        case published(reading: FaithfulReading, freshness: TunerReading.Freshness)

        var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }

        var isEmpty: Bool {
            if case .empty = self { return true }
            return false
        }

        var isPublished: Bool {
            if case .published = self { return true }
            return false
        }

        var reading: FaithfulReading? {
            switch self {
            case .published(let r, _): return r
            default: return nil
            }
        }

        var freshness: TunerReading.Freshness? {
            switch self {
            case .published(_, let f): return f
            default: return nil
            }
        }
    }

    private(set) var latest: FaithfulReading? = nil
    private(set) var lastReading: Double = -.infinity
    private(set) var lastDisplay: Double = -.infinity
    private(set) var lastFreshTime: Double = -.infinity

    init() {}

    func reset() {
        latest = nil
        lastReading = -.infinity
        lastDisplay = -.infinity
        lastFreshTime = -.infinity
    }

    /// Throttles and holds reading frames.
    ///
    /// - Parameters:
    ///   - reading: Newly tracked reading, or `nil` if detector/tracker produced no reading on this frame.
    ///   - time: Frame timestamp in milliseconds.
    /// - Returns: `Action`:
    ///   - `.skipped` when frame rate exceeds 12 Hz (`time - lastDisplay < 1000.0 / 12.0`).
    ///   - `.empty` when hold has expired (`time - lastReading >= 1000.0`) or no reading exists.
    ///   - `.published(reading, freshness)` when ready for display. `freshness` is `.fresh` if a new reading arrived on this frame, or `.held` if published from hold.
    @discardableResult
    func push(reading: FaithfulReading?, time: Double) -> Action {
        let isFresh = (reading != nil)
        if let reading = reading {
            latest = reading
            lastReading = time
            lastFreshTime = time
        }
        if (time - lastDisplay) < (1000.0 / 12.0) {
            return .skipped
        }
        lastDisplay = time
        if (time - lastReading) >= 1000.0 {
            latest = nil
            return .empty
        }
        guard let currentLatest = latest else {
            return .empty
        }
        let freshness: TunerReading.Freshness = isFresh ? .fresh : .held
        return .published(reading: currentLatest, freshness: freshness)
    }
}
