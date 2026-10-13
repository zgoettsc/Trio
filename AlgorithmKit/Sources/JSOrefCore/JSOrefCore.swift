import AlgorithmCore
import CryptoKit
import Foundation
import JavaScriptCore

/// Runs today's exact oref JavaScript (the same minified bundles and prepare wrappers the
/// app ships) in JavaScriptCore as a pure function of its inputs and the clock.
///
/// Differences from the app's `JavaScriptWorker` are deliberate and behaviour-neutral:
/// - one fresh `JSContext` per batch (the app reuses pooled contexts; every batch redefines
///   its globals, so state never carried over in practice either);
/// - a `Date` shim pinned to the loop clock so the wall-clock fallbacks inside the bundles
///   (profile schedule lookups, the autosens 24 h anchor, the iob fallback) become
///   functions of the tick clock;
/// - JavaScript exceptions raised while calling `generate` are thrown, not logged.
public final class JSOrefCore: DosingCore {
    public let name = "js-oref"
    public private(set) var fingerprint: AlgorithmFingerprint

    private let scripts: [String: String]
    private let virtualMachine = JSVirtualMachine()!
    private let logSink: ((String, [String]) -> Void)?

    /// Script batches, in the order `OpenAPS.swift` evaluates them.
    enum Batch: String, CaseIterable {
        case profile, iob, meal, autosens, determineBasal

        var scripts: [String] {
            switch self {
            case .profile: return ["prepare/log.js", "bundle/profile.js", "prepare/profile.js"]
            case .iob: return ["prepare/log.js", "bundle/iob.js", "prepare/iob.js"]
            case .meal: return ["prepare/log.js", "bundle/meal.js", "prepare/meal.js"]
            case .autosens: return ["prepare/log.js", "bundle/autosens.js", "prepare/autosens.js"]
            case .determineBasal: return [
                    "prepare/log.js",
                    "prepare/determine-basal.js",
                    "bundle/basal-set-temp.js",
                    "bundle/glucose-get-last.js",
                    "bundle/determine-basal.js",
                    "middleware/determine_basal.js",
                ]
            }
        }
    }

    private static let clockShim = """
    (function () {
      const RealDate = Date;
      let pinned = null;
      class ShimDate extends RealDate {
        constructor(...args) {
          if (args.length === 0 && pinned !== null) { super(pinned); } else { super(...args); }
        }
        static now() { return pinned !== null ? pinned : RealDate.now(); }
      }
      globalThis.Date = ShimDate;
      globalThis.__pinClock = function (ms) { pinned = (ms === null || ms === undefined) ? null : Number(ms); };
    })();
    """

    /// - Parameters:
    ///   - gitSHA: the commit of the code that built this core; the host supplies it.
    ///   - scriptsDirectory: override the script root (defaults to the package resources).
    ///   - logSink: receives `console.log` output per batch (never required).
    public init(gitSHA: String? = nil, scriptsDirectory: URL? = nil, logSink: ((String, [String]) -> Void)? = nil) throws {
        let root: URL
        if let scriptsDirectory {
            root = scriptsDirectory
        } else if let url = Bundle.module.url(forResource: "javascript", withExtension: nil) {
            root = url
        } else {
            throw DosingCoreError.missingResource("javascript")
        }
        var loaded: [String: String] = [:]
        var hashes: [String: String] = [:]
        let names = Set(Batch.allCases.flatMap(\.scripts))
        for name in names.sorted() {
            let url = root.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw DosingCoreError.missingResource(name)
            }
            loaded[name] = String(decoding: data, as: UTF8.self)
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        scripts = loaded
        self.logSink = logSink
        fingerprint = AlgorithmFingerprint(
            coreName: "js-oref",
            gitSHA: gitSHA,
            scriptSHA256: hashes,
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    // MARK: - DosingCore

    public func run(_ inputs: LoopInputs, clock: Date, timeZone: TimeZone) throws -> CoreOutput {
        try Self.requireProcessTimeZone(timeZone)
        let clockArg = Self.jsonString(clock.orefISO8601)
        let iob = try call(.iob, args: [inputs.pumpHistory.text, inputs.profile.text, clockArg, inputs.autosens.text], clock: clock)
        let meal = try call(
            .meal,
            args: [inputs.pumpHistory.text, inputs.profile.text, clockArg, inputs.glucose.text, inputs.basalProfile.text, inputs.carbs.text],
            clock: clock
        )
        let determination = try call(
            .determineBasal,
            args: [
                iob,
                inputs.currentTemp.text,
                inputs.glucose.text,
                inputs.profile.text,
                inputs.autosens.text,
                meal,
                inputs.microBolusAllowed ? "true" : "false",
                inputs.reservoir.text,
                clockArg,
                inputs.pumpHistory.text,
                inputs.preferences.text,
                inputs.basalProfile.text,
                inputs.trioCustomOrefVariables.text,
            ],
            clock: clock
        )
        return try CoreOutput(
            iob: RawJSONDocument(iob),
            meal: RawJSONDocument(meal),
            determination: RawJSONDocument(determination)
        )
    }

    // MARK: - Additional entry points (profile and autosens are inputs to `run`, generated separately as in the app)

    /// `prepare/profile.js` → `generate(...)`. Schedule lookups use the pinned clock.
    public func generateProfile(
        pumpSettings: RawJSONDocument,
        bgTargets: RawJSONDocument,
        isf: RawJSONDocument,
        basalProfile: RawJSONDocument,
        preferences: RawJSONDocument,
        carbRatio: RawJSONDocument,
        tempTargets: RawJSONDocument,
        model: RawJSONDocument,
        autotune: RawJSONDocument = .null,
        trioData: RawJSONDocument,
        clock: Date,
        timeZone: TimeZone
    ) throws -> RawJSONDocument {
        try Self.requireProcessTimeZone(timeZone)
        let out = try call(
            .profile,
            args: [pumpSettings.text, bgTargets.text, isf.text, basalProfile.text, preferences.text, carbRatio.text, tempTargets.text, model.text, autotune.text, trioData.text],
            clock: clock
        )
        return RawJSONDocument(out)
    }

    /// `prepare/autosens.js` → `generate(...)`. The 24 h look-back anchors on the pinned clock.
    public func generateAutosens(
        glucose: RawJSONDocument,
        pumpHistory: RawJSONDocument,
        basalProfile: RawJSONDocument,
        profile: RawJSONDocument,
        carbs: RawJSONDocument,
        tempTargets: RawJSONDocument,
        clock: Date,
        timeZone: TimeZone
    ) throws -> RawJSONDocument {
        try Self.requireProcessTimeZone(timeZone)
        let out = try call(
            .autosens,
            args: [glucose.text, pumpHistory.text, basalProfile.text, profile.text, carbs.text, tempTargets.text],
            clock: clock
        )
        return RawJSONDocument(out)
    }

    // MARK: - Internals

    /// JavaScriptCore resolves local time from the process time zone; switching it per call is
    /// not reliable, so the core refuses to run under a different zone than requested.
    static func requireProcessTimeZone(_ timeZone: TimeZone) throws {
        let current = TimeZone.current.identifier
        guard current == timeZone.identifier else {
            throw DosingCoreError.timeZoneMismatch(requested: timeZone.identifier, process: current)
        }
    }

    static func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        var text = String(decoding: data, as: UTF8.self)
        text.removeFirst() // "["
        text.removeLast() // "]"
        return text
    }

    private func call(_ batch: Batch, args: [String], clock: Date) throws -> String {
        let context = JSContext(virtualMachine: virtualMachine)!
        var logs: [String] = []
        var jsError: String?
        context.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "unknown JavaScript exception"
        }
        let consoleLog: @convention(block) (String) -> Void = { message in
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { logs.append(trimmed) }
        }
        context.setObject(consoleLog, forKeyedSubscript: "_consoleLog" as NSString)
        context.evaluateScript(Self.clockShim)
        if let e = jsError { throw DosingCoreError.javaScript("clock shim: \(e)") }

        for name in batch.scripts {
            guard let body = scripts[name] else { throw DosingCoreError.missingResource(name) }
            context.setObject(name, forKeyedSubscript: "scriptName" as NSString)
            context.evaluateScript(body)
            if let e = jsError { throw DosingCoreError.javaScript("\(name): \(e)") }
        }

        let pinMs = clock.timeIntervalSince1970 * 1000
        context.evaluateScript("__pinClock(\(pinMs));")
        let result = context.evaluateScript("JSON.stringify(generate(\(args.joined(separator: ","))), null, 4);")
        logSink?(batch.rawValue, logs)
        if let e = jsError { throw DosingCoreError.javaScript("\(batch.rawValue).generate: \(e)") }
        guard let result, !result.isUndefined, !result.isNull, let text = result.toString() else {
            throw DosingCoreError.malformedOutput("\(batch.rawValue).generate returned no JSON")
        }
        return text
    }
}
