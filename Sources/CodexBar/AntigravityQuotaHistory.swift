import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static func antigravityHistoryUsesObservations(
        snapshot: UsageSnapshot?, histories: [PlanUtilizationSeriesHistory]) -> Bool
    {
        if let snapshot { return !self.hasAntigravityQuotaSummary(snapshot) }
        // During startup/unavailability, use the most recently captured format; ties favor structured windows.
        // Both sets remain persisted. A stale observation must not hide newer structured history.
        let supported = histories.filter(\.hasSupportedCadence)
        let observations = supported.filter(\.name.isQuotaObservation).compactMap(\.latestCapturedAt).max()
        let structured = supported.filter { !$0.name.isQuotaObservation }.compactMap(\.latestCapturedAt).max()
        return (observations ?? .distantPast) > (structured ?? .distantPast)
    }

    nonisolated static func antigravityQuotaObservationSamples(
        snapshot: UsageSnapshot,
        capturedAt: Date) -> [PlanUtilizationSeriesSample]
    {
        guard !self.hasAntigravityQuotaSummary(snapshot) else { return [] }
        let lanes: [(PlanUtilizationSeriesName, RateWindow?)] = [
            (.antigravityGemini, snapshot.primary),
            (.antigravityClaudeGPT, snapshot.secondary),
        ]
        return lanes.compactMap { name, window in
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { return nil }
            return PlanUtilizationSeriesSample(
                name: name,
                windowMinutes: 0,
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: capturedAt,
                    usedPercent: min(100, max(0, window.usedPercent)),
                    resetsAt: window.resetsAt))
        }
    }

    nonisolated static func hasAntigravityQuotaSummary(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.extraRateWindows?.contains { $0.id.hasPrefix("antigravity-quota-summary-") } == true
    }
}
