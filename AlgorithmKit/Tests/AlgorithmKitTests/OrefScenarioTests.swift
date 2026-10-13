import AlgorithmCore
import Foundation
import JSOrefCore
import XCTest

/// Plan S0.2 `OrefScenarioTests`: pins *current* oref behaviour so later changes fail loudly.
/// The assertions live in each fixture (`assertions` array, authored in make-fixtures.js).
final class OrefScenarioTests: XCTestCase {
    func testScenarioAssertionsHold() throws {
        try TestSupport.skipUnlessUTC()
        let core = try TestSupport.makeCore()
        for fixture in try ScenarioFixture.loadAll() {
            let output = try core.run(fixture.inputs, clock: fixture.clock, timeZone: fixture.timeZone)
            let det = try output.determination.jsonObject() as? [String: Any] ?? [:]
            XCTAssertFalse(fixture.assertions.isEmpty, "[\(fixture.name)] has no assertions")
            for a in fixture.assertions {
                let field = a["field"] as? String ?? ""
                let op = a["op"] as? String ?? ""
                let value = det[field]
                let number = (value as? NSNumber)?.doubleValue
                let context = "[\(fixture.name)] \(field) \(op) \(String(describing: a["value"])) — \(fixture.note)"
                switch op {
                case "absent": XCTAssertNil(value, context)
                case "present": XCTAssertNotNil(value, context)
                case "==": XCTAssertEqual(number, (a["value"] as? NSNumber)?.doubleValue, context)
                case "<=": XCTAssertLessThanOrEqual(number ?? .infinity, (a["value"] as? NSNumber)?.doubleValue ?? -.infinity, context)
                case ">=": XCTAssertGreaterThanOrEqual(number ?? -.infinity, (a["value"] as? NSNumber)?.doubleValue ?? .infinity, context)
                case ">": XCTAssertGreaterThan(number ?? -.infinity, (a["value"] as? NSNumber)?.doubleValue ?? .infinity, context)
                case "contains": XCTAssertTrue((value as? String ?? "").contains(a["value"] as? String ?? "\u{0}"), context)
                case "halfOf":
                    let other = (det[a["value"] as? String ?? ""] as? NSNumber)?.doubleValue ?? .nan
                    let tol = (a["tolerance"] as? NSNumber)?.doubleValue ?? 0.05
                    XCTAssertEqual(number ?? .nan, other / 2, accuracy: tol, context)
                default: XCTFail("unknown op \(op) in \(fixture.name)")
                }
            }
        }
    }
}
