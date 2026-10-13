import Foundation

/// The documents one loop of the dosing core consumes, exactly as the app assembles them
/// (`OpenAPS.determineBasal`). Every document is kept as raw JSON text so that a core
/// implementation can pass bytes through unchanged; nothing here is re-encoded.
public struct LoopInputs: Codable, Equatable {
    /// 72 most recent glucose readings, newest first (`AlgorithmGlucose` encoding).
    public var glucose: RawJSONDocument
    /// Pump history for the last 24 h, newest first (`PumpEventDTO` encoding).
    public var pumpHistory: RawJSONDocument
    /// Carb entries for the last 24 h (rescue-tagged entries already filtered by the app).
    public var carbs: RawJSONDocument
    /// The generated oref profile (`settings/profile.json`).
    public var profile: RawJSONDocument
    /// The basal schedule (`settings/basal_profile.json`).
    public var basalProfile: RawJSONDocument
    /// Autosens result (`settings/autosense.json`); `null` when absent.
    public var autosens: RawJSONDocument
    /// Reservoir level (`monitor/reservoir.json`); a number or `null`.
    public var reservoir: RawJSONDocument
    /// `preferences.json` as adjusted per loop by the app (dynamic ISF may be disabled).
    public var preferences: RawJSONDocument
    /// `monitor/trio_custom_oref_variables.json`, captured per loop, never recomputed here.
    public var trioCustomOrefVariables: RawJSONDocument
    /// The running temp basal (`TempBasal` encoding).
    public var currentTemp: RawJSONDocument
    /// Whether SMBs may be proposed (the app always passes `true`).
    public var microBolusAllowed: Bool

    public init(
        glucose: RawJSONDocument,
        pumpHistory: RawJSONDocument,
        carbs: RawJSONDocument,
        profile: RawJSONDocument,
        basalProfile: RawJSONDocument,
        autosens: RawJSONDocument,
        reservoir: RawJSONDocument,
        preferences: RawJSONDocument,
        trioCustomOrefVariables: RawJSONDocument,
        currentTemp: RawJSONDocument,
        microBolusAllowed: Bool = true
    ) {
        self.glucose = glucose
        self.pumpHistory = pumpHistory
        self.carbs = carbs
        self.profile = profile
        self.basalProfile = basalProfile
        self.autosens = autosens
        self.reservoir = reservoir
        self.preferences = preferences
        self.trioCustomOrefVariables = trioCustomOrefVariables
        self.currentTemp = currentTemp
        self.microBolusAllowed = microBolusAllowed
    }
}

/// A JSON document kept as text. `null` is the literal `null`.
public struct RawJSONDocument: Codable, Equatable, ExpressibleByStringLiteral {
    public var text: String

    public init(_ text: String) { self.text = text }
    public init(stringLiteral value: String) { text = value }
    public static let null = RawJSONDocument("null")

    /// Build from any JSON-serialisable Foundation object (arrays, dictionaries, numbers…).
    public init(jsonObject: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.fragmentsAllowed])
        text = String(decoding: data, as: UTF8.self)
    }

    /// Decode as a Foundation JSON object (`nil` for the literal `null`).
    public func jsonObject() throws -> Any? {
        guard text != "null" else { return nil }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    // Encode/decode as a plain string so traces stay readable and byte-exact.
    public init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// What the core produced for one loop: the three intermediate/final documents as the
/// JavaScript emitted them (pretty-printed with `JSON.stringify(x, null, 4)`), plus a
/// parsed summary of the fields the pipeline and the harness score.
public struct CoreOutput: Codable, Equatable {
    public var iob: RawJSONDocument
    public var meal: RawJSONDocument
    public var determination: RawJSONDocument
    public var summary: DeterminationSummary

    public init(iob: RawJSONDocument, meal: RawJSONDocument, determination: RawJSONDocument) throws {
        self.iob = iob
        self.meal = meal
        self.determination = determination
        summary = try DeterminationSummary(determination: determination)
    }
}

/// The decision fields of a determination. Numbers are `Double` here (the JS emits IEEE
/// doubles); the app's `Determination` keeps `Decimal`, which is a presentation concern.
public struct DeterminationSummary: Codable, Equatable {
    public var rate: Double?
    public var duration: Double?
    public var units: Double?
    public var eventualBG: Double?
    public var insulinReq: Double?
    public var carbsReq: Double?
    public var bg: Double?
    public var iob: Double?
    public var cob: Double?
    public var minGuardBG: Double?
    public var minPredBG: Double?
    public var threshold: Double?
    public var deliverAt: String?
    public var reason: String
    public var predBGs: [String: [Double]]

    public init(determination: RawJSONDocument) throws {
        guard let obj = try determination.jsonObject() as? [String: Any] else {
            throw DosingCoreError.malformedOutput("determination is not a JSON object")
        }
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        rate = num("rate")
        duration = num("duration")
        units = num("units")
        eventualBG = num("eventualBG")
        insulinReq = num("insulinReq")
        carbsReq = num("carbsReq")
        bg = num("bg")
        iob = num("IOB")
        cob = num("COB")
        minGuardBG = num("minGuardBG")
        minPredBG = num("minPredBG")
        threshold = num("threshold")
        deliverAt = obj["deliverAt"] as? String
        reason = obj["reason"] as? String ?? ""
        var preds: [String: [Double]] = [:]
        if let p = obj["predBGs"] as? [String: Any] {
            for (k, v) in p {
                if let arr = v as? [NSNumber] { preds[k] = arr.map(\.doubleValue) }
            }
        }
        predBGs = preds
    }
}

public enum DosingCoreError: Error, Equatable {
    case timeZoneMismatch(requested: String, process: String)
    case javaScript(String)
    case malformedOutput(String)
    case missingResource(String)
}

/// The dosing core as a pure function of its inputs and the clock.
///
/// Contract: the same `inputs`, `clock` and `timeZone` always give the same `CoreOutput`.
/// Implementations must not read Core Data, settings files, or wall-clock time.
public protocol DosingCore {
    /// Human-readable name recorded in traces (e.g. `"js-oref"`).
    var name: String { get }
    /// Identity of the algorithm code that ran, recorded in every trace and report.
    var fingerprint: AlgorithmFingerprint { get }
    /// Run `iob → meal → determine-basal` for one loop.
    func run(_ inputs: LoopInputs, clock: Date, timeZone: TimeZone) throws -> CoreOutput
}

/// Identity of the algorithm code: the package's git SHA (supplied by the host, since a
/// package cannot run git at build time), the SHA-256 of every script it evaluates, and the
/// time zone the process ran in (schedule lookups inside the bundle use local time).
public struct AlgorithmFingerprint: Codable, Equatable {
    public var coreName: String
    public var gitSHA: String?
    public var scriptSHA256: [String: String]
    public var timeZoneIdentifier: String

    public init(coreName: String, gitSHA: String?, scriptSHA256: [String: String], timeZoneIdentifier: String) {
        self.coreName = coreName
        self.gitSHA = gitSHA
        self.scriptSHA256 = scriptSHA256
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public extension Date {
    /// ISO-8601 with fractional seconds, UTC — the encoding the app uses for every date it
    /// hands to the JavaScript (`Formatter.iso8601withFractionalSeconds`).
    var orefISO8601: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: self)
    }

    static func fromOrefISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
