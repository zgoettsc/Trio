import AlgorithmCore
import Foundation
import JSOrefCore

// trio-replay — plan step S0.2 scope: `tick` (run one recorded/synthetic loop) and
// `fingerprint`. The replay engine, metrics and reports arrive in S0.4.
//
//   trio-replay tick <inputs.json>      run one loop; prints {"iob","meal","determination"}
//   trio-replay fingerprint             print the script hashes and process time zone
//
// inputs.json: {"clock": "<ISO-8601>", "timeZone": "<IANA id>", "microBolusAllowed": true,
//               "glucose": [...], "pumpHistory": [...], "carbs": [...], "profile": {...},
//               "basalProfile": [...], "autosens": {...}|null, "reservoir": 300|null,
//               "preferences": {...}, "trioCustomOrefVariables": {...}, "currentTemp": {...}}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func doc(_ object: [String: Any], _ key: String) throws -> RawJSONDocument {
    guard let value = object[key] else { return .null }
    if value is NSNull { return .null }
    return try RawJSONDocument(jsonObject: value)
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { fail("usage: trio-replay tick <inputs.json> | fingerprint") }

do {
    let core = try JSOrefCore(gitSHA: ProcessInfo.processInfo.environment["TRIO_GIT_SHA"])
    switch command {
    case "fingerprint":
        let data = try JSONEncoder().encode(core.fingerprint)
        print(String(decoding: data, as: UTF8.self))
    case "tick":
        guard args.count >= 2 else { fail("tick needs an inputs.json path") }
        let url = URL(fileURLWithPath: args[args.startIndex + 1])
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            fail("inputs.json must be a JSON object")
        }
        guard let clockString = object["clock"] as? String, let clock = Date.fromOrefISO8601(clockString) else {
            fail("inputs.json needs an ISO-8601 \"clock\"")
        }
        let tzId = object["timeZone"] as? String ?? TimeZone.current.identifier
        guard let timeZone = TimeZone(identifier: tzId) else { fail("unknown timeZone \(tzId)") }
        let inputs = try LoopInputs(
            glucose: doc(object, "glucose"),
            pumpHistory: doc(object, "pumpHistory"),
            carbs: doc(object, "carbs"),
            profile: doc(object, "profile"),
            basalProfile: doc(object, "basalProfile"),
            autosens: doc(object, "autosens"),
            reservoir: doc(object, "reservoir"),
            preferences: doc(object, "preferences"),
            trioCustomOrefVariables: doc(object, "trioCustomOrefVariables"),
            currentTemp: doc(object, "currentTemp"),
            microBolusAllowed: object["microBolusAllowed"] as? Bool ?? true
        )
        let output = try core.run(inputs, clock: clock, timeZone: timeZone)
        let result: [String: Any] = [
            "iob": try output.iob.jsonObject() ?? NSNull(),
            "meal": try output.meal.jsonObject() ?? NSNull(),
            "determination": try output.determination.jsonObject() ?? NSNull(),
            "fingerprint": try JSONSerialization.jsonObject(with: JSONEncoder().encode(core.fingerprint)),
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error)")
}
