import AlgorithmCore
import Foundation
import JSOrefCore
import XCTest

/// Plan S0.2 `GoldenOrefTests`: the package's JavaScriptCore run of the app's exact scripts
/// must reproduce what the Node harness produced for the same inputs and clock.
final class GoldenOrefTests: XCTestCase {
    func testAllScenarioFixturesReproduce() throws {
        try TestSupport.skipUnlessUTC()
        let fixtures = try ScenarioFixture.loadAll()
        XCTAssertGreaterThanOrEqual(fixtures.count, 8, "scenario fixtures missing")
        let core = try TestSupport.makeCore()

        for fixture in fixtures {
            let output = try core.run(fixture.inputs, clock: fixture.clock, timeZone: fixture.timeZone)
            let actual = try output.determination.jsonObject() as? [String: Any] ?? [:]

            // Decision fields must match exactly.
            for key in ["rate", "duration", "units", "eventualBG", "insulinReq", "carbsReq", "deliverAt", "COB", "IOB", "minGuardBG", "minPredBG", "threshold"] {
                let e = fixture.expectedDetermination[key]
                let a = actual[key]
                switch (e, a) {
                case (nil, nil): break
                case let (x as NSNumber, y as NSNumber): XCTAssertEqual(x, y, "[\(fixture.name)] \(key)")
                case let (x as String, y as String): XCTAssertEqual(x, y, "[\(fixture.name)] \(key)")
                default: XCTFail("[\(fixture.name)] \(key): expected \(String(describing: e)) got \(String(describing: a))")
                }
            }
            // Prediction curves must match element-for-element.
            let ep = fixture.expectedDetermination["predBGs"] as? [String: Any] ?? [:]
            let ap = actual["predBGs"] as? [String: Any] ?? [:]
            XCTAssertEqual(TestSupport.diff(ap, ep, path: "predBGs"), [], "[\(fixture.name)] predBGs differ")

            // Whole-document comparison (iob, meal, determination). Any difference here is either a
            // JS-engine numeric difference or a real behavioural divergence; both must be understood.
            let iobDiff = try TestSupport.diff(output.iob.jsonObject() ?? NSNull(), fixture.expectedIOB, path: "iob")
            let mealDiff = try TestSupport.diff(output.meal.jsonObject() ?? NSNull(), fixture.expectedMeal, path: "meal")
            let detDiff = TestSupport.diff(actual, fixture.expectedDetermination, path: "determination")
            XCTAssertEqual(iobDiff, [], "[\(fixture.name)] iob differs: \(iobDiff.prefix(5))")
            XCTAssertEqual(mealDiff, [], "[\(fixture.name)] meal differs: \(mealDiff.prefix(5))")
            XCTAssertEqual(detDiff, [], "[\(fixture.name)] determination differs: \(detDiff.prefix(5))")
        }
    }
}
