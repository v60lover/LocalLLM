import XCTest
@testable import LocalLLMChat

final class ContextBudgetTests: XCTestCase {
    func testRemainingUsesActualReportedTokensAndClampsAtZero() {
        XCTAssertEqual(ContextBudget.remaining(contextSize: 4096, usedTokens: 1536), 2560)
        XCTAssertEqual(ContextBudget.remaining(contextSize: 4096, usedTokens: 5000), 0)
        XCTAssertNil(ContextBudget.remaining(contextSize: nil, usedTokens: 100))
        XCTAssertNil(ContextBudget.remaining(contextSize: 4096, usedTokens: nil))
    }
}
