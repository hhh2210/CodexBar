import Foundation

public struct RecordedScheduleAudit: Sendable, Equatable {
    public let recordedAdvanceCount: Int
    public let evaluatedCount: Int
    public let acceptedEvaluationCount: Int
    public let rejectedEvaluationCount: Int
    public let payloadMismatchCount: Int
    public let decisionMismatchCount: Int
    public let menuLinkMismatchCount: Int
    public let ambiguousComparisonCount: Int

    public var isValid: Bool {
        self.payloadMismatchCount == 0
            && self.decisionMismatchCount == 0
            && self.menuLinkMismatchCount == 0
            && self.ambiguousComparisonCount == 0
    }
}

/// Audits the live schedule records without equating them to ReplayEngine's counterfactual clock.
public enum RecordedScheduleAuditor {
    public static func audit(
        _ records: [AdaptiveRefreshTraceRecord],
        timestampTolerance: TimeInterval = 1) -> RecordedScheduleAudit
    {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        let menuTimestamps = sorted.filter { $0.kind == .menuOpen }.map(\.timestamp)
        let advances = sorted.filter { $0.kind == .timerAdvanced }
        let evaluations = sorted.filter { $0.kind == .timerAdvanceEvaluated }

        var payloadMismatchCount = advances.count(where: { !Self.payloadIsValid($0) })
        let evaluationOutcomes = evaluations.map(Self.evaluationOutcome)
        let decisionMismatchCount = evaluationOutcomes.count(where: { $0 == .mismatch })
        let ambiguousComparisonCount = evaluationOutcomes.count(where: { $0 == .ambiguous })
        let menuLinkMismatchCount = (advances + evaluations).count(where: { event in
            !menuTimestamps.contains(where: {
                abs($0.timeIntervalSince(event.timestamp)) <= timestampTolerance
            })
        })

        if let firstEvaluationAt = evaluations.first?.timestamp {
            let accepted = evaluations.filter { $0.timerAdvanceAccepted == true }
            let auditableAdvances = advances.filter { $0.timestamp >= firstEvaluationAt }
            payloadMismatchCount += Self.scheduleMultiplicityDifference(accepted, auditableAdvances)
        }

        return RecordedScheduleAudit(
            recordedAdvanceCount: advances.count,
            evaluatedCount: evaluations.count,
            acceptedEvaluationCount: evaluations.count(where: { $0.timerAdvanceAccepted == true }),
            rejectedEvaluationCount: evaluations.count(where: { $0.timerAdvanceAccepted == false }),
            payloadMismatchCount: payloadMismatchCount,
            decisionMismatchCount: decisionMismatchCount,
            menuLinkMismatchCount: menuLinkMismatchCount,
            ambiguousComparisonCount: ambiguousComparisonCount)
    }

    private static func payloadIsValid(_ record: AdaptiveRefreshTraceRecord) -> Bool {
        guard let candidate = record.candidateScheduledAt,
              let delay = record.delaySeconds,
              abs(candidate.timeIntervalSince(record.timestamp) - delay) < 0.001
        else { return false }
        // Whole-second legacy timestamps can collapse a sub-second accepted lead to equality.
        return record.previousScheduledAt.map { candidate <= $0 } ?? true
    }

    private enum EvaluationOutcome: Equatable {
        case valid
        case mismatch
        case ambiguous
    }

    private static func evaluationOutcome(_ record: AdaptiveRefreshTraceRecord) -> EvaluationOutcome {
        guard let accepted = record.timerAdvanceAccepted,
              let candidate = record.candidateScheduledAt,
              let delay = record.delaySeconds,
              abs(candidate.timeIntervalSince(record.timestamp) - delay) < 0.001
        else { return .mismatch }
        guard record.previousScheduledAt != nil else { return accepted ? .valid : .mismatch }
        if let lead = record.scheduleLeadSeconds {
            return accepted == (lead > 0) ? .valid : .mismatch
        }
        guard let previous = record.previousScheduledAt else { return .mismatch }
        if candidate == previous {
            return .ambiguous
        }
        return accepted == (candidate < previous) ? .valid : .mismatch
    }

    private struct ScheduleKey: Hashable {
        let timestamp: Date
        let previousScheduledAt: Date?
        let candidateScheduledAt: Date?
        let reason: String?
        let delaySeconds: TimeInterval?
    }

    private static func scheduleMultiplicityDifference(
        _ lhs: [AdaptiveRefreshTraceRecord],
        _ rhs: [AdaptiveRefreshTraceRecord]) -> Int
    {
        func counts(_ records: [AdaptiveRefreshTraceRecord]) -> [ScheduleKey: Int] {
            Dictionary(grouping: records, by: Self.scheduleKey).mapValues(\.count)
        }
        let lhsCounts = counts(lhs)
        let rhsCounts = counts(rhs)
        return Set(lhsCounts.keys).union(rhsCounts.keys).reduce(0) { difference, key in
            difference + abs(lhsCounts[key, default: 0] - rhsCounts[key, default: 0])
        }
    }

    private static func scheduleKey(_ record: AdaptiveRefreshTraceRecord) -> ScheduleKey {
        ScheduleKey(
            timestamp: record.timestamp,
            previousScheduledAt: record.previousScheduledAt,
            candidateScheduledAt: record.candidateScheduledAt,
            reason: record.reason,
            delaySeconds: record.delaySeconds)
    }
}
