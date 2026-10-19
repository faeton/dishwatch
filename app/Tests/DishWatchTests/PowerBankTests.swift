import XCTest
@testable import DishWatch

final class PowerBankTests: XCTestCase {
    typealias Sheet = BatterySetupSheet

    func testWhPassesThrough() {
        XCTAssertEqual(Sheet.wh(from: "67", unit: .wh, volts: "3.7"), 67)
        XCTAssertEqual(Sheet.wh(from: " 99,5 ", unit: .wh, volts: "3.7"), 99.5)
    }

    /// The label's mAh is at the cell voltage: 20 000 mAh × 3.7 V = 74 Wh.
    /// Using the 5 V output instead would overstate it by a third.
    func testMAhConvertsAtCellVoltage() throws {
        let wh = try XCTUnwrap(Sheet.wh(from: "20000", unit: .mAh, volts: "3.7"))
        XCTAssertEqual(wh, 74, accuracy: 0.001)
    }

    func testRejectsNonsense() {
        XCTAssertNil(Sheet.wh(from: "", unit: .wh, volts: "3.7"))
        XCTAssertNil(Sheet.wh(from: "-5", unit: .wh, volts: "3.7"))
        XCTAssertNil(Sheet.wh(from: "abc", unit: .mAh, volts: "3.7"))
        XCTAssertNil(Sheet.wh(from: "20000", unit: .mAh, volts: "0"))
        XCTAssertNil(Sheet.wh(from: "20000", unit: .mAh, volts: ""))
        // Out of range would trap the first `Int(...)` that saw it.
        XCTAssertNil(Sheet.wh(from: "1e20", unit: .wh, volts: "3.7"))
        XCTAssertNil(Sheet.wh(from: "20000", unit: .mAh, volts: "1e-300"))
        XCTAssertEqual(Sheet.whText(1e20), "100000000000000000000 Wh")
    }

    /// README's worked example: 7.37 Wh over an 11% drop → 67 Wh.
    func testCalibrationSolvesFromTheAnchor() {
        XCTAssertEqual(Sheet.calibratedCapacity(anchorPct: 90, usedWh: 7.37, nowPct: 79), 67)
    }

    /// The old formula returned the starting capacity whatever was entered.
    /// A different reading must give a different answer.
    func testCalibrationDependsOnTheReading() {
        let a = Sheet.calibratedCapacity(anchorPct: 90, usedWh: 7.37, nowPct: 79)
        let b = Sheet.calibratedCapacity(anchorPct: 90, usedWh: 7.37, nowPct: 84)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }

    func testCalibrationNeedsARealDrop() {
        XCTAssertNil(Sheet.calibratedCapacity(anchorPct: 90, usedWh: 2, nowPct: 88))   // 2% drop
        XCTAssertNil(Sheet.calibratedCapacity(anchorPct: 90, usedWh: 0, nowPct: 70))   // nothing drawn
        XCTAssertNil(Sheet.calibratedCapacity(anchorPct: 50, usedWh: 5, nowPct: 60))   // went up
    }

    /// The two fields Calibrate divides, decoded from a real helper payload.
    func testDecodesAnchorFields() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "live-connected", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "live-connected", withExtension: "json"))
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["bankAnchored"] = true
        obj["bankAnchorPct"] = 90
        obj["bankUsedWh"] = 6.7
        let d = try JSONDecoder().decode(DishData.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(d.bankAnchorPct, 90)
        XCTAssertEqual(d.bankUsedWh, 6.7)
    }
}
