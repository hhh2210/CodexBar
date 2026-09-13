import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityLocalPricingTests {
    @Test(arguments: [UInt64(1_798_761_599), UInt64(1_798_761_600)])
    func `Gemini estimates price each disjoint token bucket and honor the published cutoff`(seconds: UInt64) throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [AntigravityLocalFixture.blob(
            model: "gemini-3.8-flash",
            system: 100,
            input: 900,
            output: 20,
            cacheRead: 2000,
            reasoning: 80,
            seconds: seconds)])
        let report = try fixture.report()
        let entry = try #require(report.report.data.first)
        let expected = (1000 * 0.75 + 2000 * 0.075 + 100 * 3.75) / 1_000_000
            * (seconds < 1_798_761_600 ? 1.0 : 2.0)
        #expect(report.isComplete)
        #expect(try abs(#require(entry.costUSD) - expected) < 1e-12)
        #expect(entry.totalTokens == 3100)
        #expect(entry.estimatedRequestCount == 1)
        #expect(entry.pricedRequestCount == 0)
    }

    @Test
    func `unknown models retain tokens and explicit unpriced coverage beside an estimate`() throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [
            AntigravityLocalFixture.blob(model: "gemini-3.8-flash"),
            AntigravityLocalFixture.blob(model: "fixture-unpriced-model"),
        ])
        let report = try fixture.report()
        let entry = try #require(report.report.data.first)
        #expect(report.isComplete)
        #expect(entry.requestCount == 2)
        #expect(entry.totalTokens == 396)
        #expect(entry.costUSD != nil)
        #expect(entry.estimatedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.modelBreakdowns?.first(where: { $0.modelName == "fixture-unpriced-model" })?.costUSD == nil)
    }
}
