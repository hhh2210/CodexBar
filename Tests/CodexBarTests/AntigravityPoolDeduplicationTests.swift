import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityPoolDeduplicationTests {
    @Test
    func `remote source suppresses pool mirroring variants when shared pool is partially consumed`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "gemini-3-1-pro-high",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Claude Sonnet 3.7",
                    modelId: "claude-3-7-sonnet",
                    remainingFraction: 1.0,
                    resetTime: resetTime,
                    resetDescription: nil),
                // Internal pool-mirroring variants sharing the same consumed fraction and reset time
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-exp",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Gemini 3.5 Flash Lite",
                    modelId: "gemini-3-5-flash-lite",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Image",
                    modelId: "gemini-3-1-flash-image",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 96)
        #expect(usage.secondary?.remainingPercent.rounded() == 100)
        // Pool-mirroring variants must be suppressed from extraRateWindows
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `remote source deduplicates multiple entries sharing the same display label`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: resetTime,
                    resetDescription: nil),
                // Multiple variants resolving to the same display label with distinct usage
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-a",
                    remainingFraction: 0.50,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-b",
                    remainingFraction: 0.40,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.title == "Gemini 3.1 Flash Lite")
        // Keeps the most constrained entry (40% remaining -> 60% used)
        #expect(extras.first?.window.usedPercent == 60)
    }

    @Test
    func `remote source preserves variants with distinct quota consumption`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                // Variant with distinct usage from the 96% pool representative
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Image",
                    modelId: "gemini-3-1-flash-image",
                    remainingFraction: 0.30,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.title == "Gemini 3.1 Flash Image")
        #expect(extras.first?.window.usedPercent == 70)
    }
}
