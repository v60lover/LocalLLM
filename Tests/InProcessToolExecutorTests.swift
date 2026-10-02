import Foundation
import XCTest
@testable import LocalLLMChat

final class InProcessToolExecutorTests: XCTestCase {
    func testModelPickerToolReturnsPickerSignal() async throws {
        let executor = InProcessToolExecutor()

        let result = try await executor.execute(.openModelPicker)

        XCTAssertTrue(result.opensModelPicker)
    }
}
