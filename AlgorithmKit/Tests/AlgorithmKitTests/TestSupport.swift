import AlgorithmCore
import Foundation
import JSOrefCore
import XCTest

/// A scenario fixture produced by `tools/jsharness/make-fixtures.js`.
struct ScenarioFixture {
    let name: String
    let note: String
    let clock: Date
    let timeZone: TimeZone
    let inputs: LoopInputs
    let expectedIOB: Any
    let expectedMeal: Any
    let expectedDetermination: [String: Any]
    let assertions: [[String: Any]]

    static func loadAll() throws -> [ScenarioFixture] {
        guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?.appendingPathComponent("scenarios") else {
            throw DosingCoreError.missingResource("Fixtures/scenarios")
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try load($0) }
    }

    static func load(_ url: URL) throws -> ScenarioFixture {
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let name = obj["name"] as? String,
              let clockString = obj["clock"] as? String,
              let clock = Date.fromOrefISO8601(clockString),
              let tzId = obj["timeZone"] as? String, let tz = TimeZone(identifier: tzId),
              let inputsObj = obj["inputs"] as? [String: Any],
              let expected = obj["expected"] as? [String: Any],
              let determination = expected["determination"] as? [String: Any]
        else { throw DosingCoreError.malformedOutput("fixture \(url.lastPathComponent)") }

        func doc(_ key: String) throws -> RawJSONDocument {
            guard let v = inputsObj[key], !(v is NSNull) else { return .null }
            return try RawJSONDocument(jsonObject: v)
        }
        let inputs = try LoopInputs(
            glucose: doc("glucose"), pumpHistory: doc("pumpHistory"), carbs: doc("carbs"), profile: doc("profile"),
            basalProfile: doc("basalProfile"), autosens: doc("autosens"), reservoir: doc("reservoir"),
            preferences: doc("preferences"), trioCustomOrefVariables: doc("trioCustomOrefVariables"),
            currentTemp: doc("currentTemp"), microBolusAllowed: inputsObj["microBolusAllowed"] as? Bool ?? true
        )
        return ScenarioFixture(
            name: name, note: obj["note"] as? String ?? "", clock: clock, timeZone: tz, inputs: inputs,
            expectedIOB: expected["iob"] ?? NSNull(), expectedMeal: expected["meal"] ?? NSNull(),
            expectedDetermination: determination, assertions: obj["assertions"] as? [[String: Any]] ?? []
        )
    }
}

enum TestSupport {
    static func makeCore() throws -> JSOrefCore { try JSOrefCore(gitSHA: "test") }

    /// Fixtures are generated in UTC; the package's core refuses to run under another zone.
    static var processIsUTC: Bool { TimeZone.current.identifier == "UTC" || TimeZone.current.identifier == "GMT" || TimeZone.current.secondsFromGMT() == 0 }

    static func skipUnlessUTC() throws {
        try XCTSkipUnless(processIsUTC, "Run with TZ=UTC (CI sets it); process time zone is \(TimeZone.current.identifier)")
    }

    /// Keys whose values may legitimately differ between JavaScript engines or runs.
    static let volatileDeterminationKeys: Set<String> = []

    static func normaliseEngineDateStrings(_ s: String) -> String {
        s.replacingOccurrences(of: #"GMT[+-]\d{4} \([^)]*\)"#, with: "GMT", options: .regularExpression)
    }

    /// Compare two JSON values structurally, returning a list of differing key paths.
    static func diff(_ a: Any, _ b: Any, path: String = "$") -> [String] {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            var out: [String] = []
            for key in Set(x.keys).union(y.keys).sorted() {
                switch (x[key], y[key]) {
                case (nil, _?): out.append("\(path).\(key): missing in actual")
                case (_?, nil): out.append("\(path).\(key): missing in expected")
                case let (l?, r?): out += diff(l, r, path: "\(path).\(key)")
                default: break
                }
            }
            return out
        case let (x as [Any], y as [Any]):
            if x.count != y.count { return ["\(path): array length \(x.count) vs \(y.count)"] }
            return zip(x, y).enumerated().flatMap { diff($0.element.0, $0.element.1, path: "\(path)[\($0.offset)]") }
        case let (x as NSNumber, y as NSNumber):
            return x == y ? [] : ["\(path): \(x) vs \(y)"]
        case let (x as String, y as String):
            // JavaScript engines print Date.toString() time-zone names differently
            // ("GMT+0000 (Coordinated Universal Time)" in V8, "(UTC)" in JavaScriptCore);
            // such strings only ever appear inside `reason`, so normalise them.
            let nx = normaliseEngineDateStrings(x), ny = normaliseEngineDateStrings(y)
            return nx == ny ? [] : ["\(path): \"\(x.prefix(80))\" vs \"\(y.prefix(80))\""]
        case (is NSNull, is NSNull):
            return []
        default:
            return ["\(path): type mismatch (\(type(of: a)) vs \(type(of: b)))"]
        }
    }
}
