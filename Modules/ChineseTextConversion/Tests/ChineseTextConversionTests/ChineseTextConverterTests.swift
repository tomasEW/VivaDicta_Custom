import XCTest
@testable import ChineseTextConversion

final class ChineseTextConverterTests: XCTestCase {
    func testConvertsSimplifiedChinese() async {
        let output = await ChineseTextConverter.traditionalized("汉语 input 软件")
        XCTAssertEqual(output, "漢語 input 軟件")
    }

    func testPreservesTraditionalChinese() async {
        let output = await ChineseTextConverter.traditionalized("這是繁體中文")
        XCTAssertEqual(output, "這是繁體中文")
    }
}
