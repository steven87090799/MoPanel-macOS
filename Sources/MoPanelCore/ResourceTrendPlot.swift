// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct ResourceTrendObservation: Sendable {
    public let date: Date
    public let value: Double?
    public let interval: TimeInterval
    public let startsNewSegment: Bool
    public init(date: Date, value: Double?, interval: TimeInterval = 2, startsNewSegment: Bool = false) {
        self.date = date; self.value = value; self.interval = interval; self.startsNewSegment = startsNewSegment
    }
}

public struct ResourceTrendGap: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct ResourceTrendPoint: Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let date: Date
    public let value: Double
    public let segment: Int
    public let isolated: Bool
}

/// Preserve only actual observations. A stopped watch, missing metric or late
/// sample starts a new line; no interpolation or zero-filling bridges the gap.
public struct ResourceTrendPlot: Sendable {
    public let points: [ResourceTrendPoint]
    public let gaps: [ResourceTrendGap]
    public let dateDomain: ClosedRange<Date>?

    public static func make(_ observations: [ResourceTrendObservation]) -> ResourceTrendPlot {
        var entries: [(Int, ResourceTrendObservation, Int)] = []
        var gaps: [ResourceTrendGap] = []
        var previous: ResourceTrendObservation?, interrupted = false, segment = 0
        let dates = observations.map(\.date).filter { $0.timeIntervalSince1970.isFinite }
        for (index, sample) in observations.enumerated() {
            guard sample.date.timeIntervalSince1970.isFinite, let value = sample.value, value.isFinite, value >= 0 else {
                interrupted = true; continue
            }
            if let previous {
                let delta = sample.date.timeIntervalSince(previous.date)
                let expected = max(validInterval(previous.interval), validInterval(sample.interval))
                if interrupted || sample.startsNewSegment || delta <= 0 || delta > max(3, expected * 1.8 + 0.25) {
                    segment += 1
                    if delta > 0 { gaps.append(.init(start: previous.date, end: sample.date)) }
                }
            } else if let first = dates.first, sample.date > first {
                gaps.append(.init(start: first, end: sample.date))
            }
            entries.append((index, sample, segment))
            previous = sample; interrupted = false
        }
        if interrupted, let previous, let last = dates.last, last > previous.date {
            gaps.append(.init(start: previous.date, end: last))
        }
        let counts = Dictionary(grouping: entries, by: { $0.2 }).mapValues(\.count)
        let points = entries.map { index, sample, segment in
            ResourceTrendPoint(index: index, date: sample.date, value: sample.value!, segment: segment, isolated: counts[segment] == 1)
        }
        let domain: ClosedRange<Date>?
        if let first = dates.min(), let last = dates.max() {
            domain = first < last ? first...last : first.addingTimeInterval(-1)...last.addingTimeInterval(1)
        } else { domain = nil }
        return .init(points: points, gaps: gaps, dateDomain: domain)
    }

    private static func validInterval(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? min(value, 60) : 2
    }
}
