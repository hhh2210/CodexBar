import CodexBarCore
import Foundation

extension UsageStore {
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
