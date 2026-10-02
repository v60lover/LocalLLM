import XCTest
@testable import LocalLLMChat

final class ContextBudgetTests: XCTestCase {
    func testRemainingUsesActualReportedTokensAndClampsAtZero() {
        XCTAssertEqual(ContextBudget.remaining(contextSize: 4096, usedTokens: 1536), 2560)
        XCTAssertEqual(ContextBudget.remaining(contextSize: 4096, usedTokens: 5000), 0)
        XCTAssertNil(ContextBudget.remaining(contextSize: nil, usedTokens: 100))
        XCTAssertNil(ContextBudget.remaining(contextSize: 4096, usedTokens: nil))
    }

    func testNearlyFullLeavesRoomForOneReply() {
        XCTAssertTrue(ContextBudget.isNearlyFull(contextSize: 1000, usedTokens: 800, replyBudget: 100))
        XCTAssertFalse(ContextBudget.isNearlyFull(contextSize: 1000, usedTokens: 500, replyBudget: 100))
        XCTAssertFalse(ContextBudget.isNearlyFull(contextSize: nil, usedTokens: 999, replyBudget: 100))
    }
}
