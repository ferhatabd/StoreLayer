import XCTest
@testable import StoreLayer

final class StoreLayerTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(StoreLayer().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
