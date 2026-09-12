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

    @Test
    func `local source retains curated variants even if mirroring summary`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Gemini 3.5 Flash Lite",
                    modelId: "gemini-3-5-flash-lite",
                    remainingFraction: 0.96,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.title == "Gemini 3.5 Flash Lite")
        #expect(extras.first?.window.usedPercent == 4)
    }

    @Test
    func `missing reset timestamp is not treated as mirrored quota`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.96,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.5 Flash Lite",
                    modelId: "gemini-3-5-flash-lite",
                    remainingFraction: 0.96,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.title == "Gemini 3.5 Flash Lite")
    }

    @Test
    func `canonical model id deduplication runs before display label grouping`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.40,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                // Two entries that share the same model ID but have different raw labels
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Image Experimental",
                    modelId: "gemini-3-1-flash-image",
                    remainingFraction: 0.80,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Image Preview",
                    modelId: "gemini-3-1-flash-image",
                    remainingFraction: 0.50,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h 48m"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.window.usedPercent == 50)
    }

    @Test
    func `local source with known primary and reset candidate avoids extra pool row`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.80,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h"),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro",
                    modelId: "gemini-3-pro",
                    remainingFraction: nil,
                    resetTime: resetTime,
                    resetDescription: "Resets in 3h"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 20)
        // Gemini pool already has primary representation; reset-only pool row must not be added to extras
        #expect(usage.extraRateWindows?.contains(where: { $0.id == "antigravity-gemini" }) != true)
    }

    @Test
    func `fractional quota comparison preserves precision between near-zero values`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: resetTime,
                    resetDescription: nil),
                // 0.004 remaining (0.4%) vs exact 0.0 remaining (exhausted)
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-fraction",
                    remainingFraction: 0.004,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-exhausted",
                    remainingFraction: 0.0,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.id == "gemini-3-1-flash-lite-exhausted")
        #expect(extras.first?.window.remainingPercent == 0.0)
    }

    @Test
    func `compact fallback identity takes precedence across display title dedup`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Custom Engine",
                    modelId: "MODEL_PLACEHOLDER_A",
                    remainingFraction: 0.50,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Custom Engine",
                    modelId: "MODEL_PLACEHOLDER_B",
                    remainingFraction: 0.50,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.id.hasPrefix("antigravity-compact-fallback-") == true)
    }

    @Test
    func `mixed known and reset-only candidates with duplicate titles preserve known usage`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-known",
                    remainingFraction: 0.30,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite-reset-only",
                    remainingFraction: nil,
                    resetTime: resetTime,
                    resetDescription: "Resets soon"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.id == "gemini-3-1-flash-lite-known")
        #expect(extras.first?.window.usedPercent == 70)
    }

    @Test
    func `autocomplete variant mirroring gemini pool is suppressed on remote projection`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.90,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Tab Autocomplete",
                    modelId: "tab_autocomplete_model",
                    remainingFraction: 0.90,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.extraRateWindows == nil)
    }
}
