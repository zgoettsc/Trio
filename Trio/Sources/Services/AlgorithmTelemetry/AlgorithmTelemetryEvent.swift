import Foundation

/// All telemetry payloads are sum-typed under `AlgorithmTelemetryEvent` so a single JSONL stream
/// can carry multiple event kinds. Each row in `events.jsonl` is one of these.
///
/// Per-loop-pass observations are written to a separate file (`loop.jsonl`) and use
/// `AlgorithmTelemetryLoopSample` so the row shape is consistent and easy to fold into pandas
/// /jq for analysis.
///
/// All timestamps are ISO-8601 with fractional seconds, in UTC.

enum AlgorithmTelemetryEventKind: String, Codable {
    case mealWindowActivated
    case mealWindowCancelled
    case mealWindowExpired
    case mealWindowCarbsConfirmed
    case insulinReqFloorActivated
    case smbDelivered     // any SMB the loop enacts; useful even outside meal windows
    case userBolus        // manual bolus initiated through the Trio bolus screen
    case externalBolus    // user-recorded "external" insulin administered outside Trio
    case carbEntry        // every local carb/fat/protein entry, regardless of meal window
}

struct AlgorithmTelemetryEvent: Codable {
    let kind: AlgorithmTelemetryEventKind
    let timestamp: Date
    /// Stable UUID per meal-window so all events for one window can be joined together.
    let windowId: String?
    /// Free-form payload — fields vary by event kind.
    let payload: [String: AlgorithmTelemetryJSONValue]
}

/// Per-loop-pass observation. One row per `determineBasal` cycle. Currently we only
/// write these while a meal-window is active (to keep volume manageable); a future
/// upgrade could log continuously.
struct AlgorithmTelemetryLoopSample: Codable {
    let timestamp: Date
    let windowId: String?
    let minutesSinceWindowOpen: Double?

    // BG signal
    let bg: Double?
    let smoothedBG: Double?
    let velocity: Double?
    let acceleration: Double?
    let jerk: Double?
    let delta5m: Double?
    let shortAvgDelta: Double?
    let longAvgDelta: Double?
    let mealDetection: String?

    // Loop math
    let iob: Double?
    let cob: Double?
    let bayesianCOB: Double?
    let eventualBG: Double?
    let minPredBG: Double?
    let insulinReq: Double?
    let smbDelivered: Double?
    let tempBasalRate: Double?
    let sensitivityRatio: Double?

    // Meal-window state
    let mealWindowActive: Bool
    let mealWindowMinutesRemaining: Double?
    let mealWindowCarbsConfirmed: Bool
    let mealWindowEstimatedCarbs: Double?
    let floorActivated: Bool
    let floorPriorInsulinReq: Double?
    let floorMagnitude: Double?
    let floorVelocityFactor: Double?

    // Context
    let target: Double?
    let isf: Double?
    let carbRatio: Double?
    let maxIOB: Double?

    // Full oref reason string — invaluable for debugging
    let reason: String?
}

/// Per-meal-window outcome rollup. Written at +6h after the window closed so we
/// capture the full post-prandial trajectory.
struct AlgorithmTelemetryWindowSummary: Codable {
    let windowId: String
    let activatedAt: Date
    let closedAt: Date
    let closeReason: String // "expired", "userCancelled", "liveActivityCancelled", "urlCancelled"

    let estimatedCarbsHint: Double?
    let realCarbsLogged: Double?
    let realFatLogged: Double?
    let realProteinLogged: Double?
    let carbsConfirmed: Bool

    let bgAtActivation: Double?
    let iobAtActivation: Double?
    let cobAtActivation: Double?
    let velocityAtActivation: Double?
    let accelerationAtActivation: Double?
    let mealDetectionAtActivation: String?

    // Outcomes computed from BG samples in the [activatedAt, closedAt + 6h] window
    let peakBG: Double?
    let peakBGMinutesAfterActivation: Double?
    let nadirBG: Double?
    let nadirBGMinutesAfterActivation: Double?
    let bgAt2hr: Double?
    let bgAt4hr: Double?
    let bgAt6hr: Double?
    let minutesAbove180: Double?
    let minutesAbove250: Double?
    let minutesBelow70: Double?

    // Insulin delivered between activatedAt and closedAt + 6h
    let totalSMBInsulin: Double?
    let totalScheduledBasalInsulin: Double?
    let totalManualBolusInsulin: Double?
    let floorActivationCount: Int

    // Snapshot of relevant settings at activation time
    let target: Double?
    let isf: Double?
    let carbRatio: Double?
    let maxIOB: Double?
    let smbDeliveryRatio: Double?
    let maxSMBBasalMinutes: Double?
    let maxUAMSMBBasalMinutes: Double?
}

/// Daily snapshot of the algorithm's full configuration. One file per day, replaced
/// on each push so we always see today's current state.
struct AlgorithmTelemetrySettingsSnapshot: Codable {
    let timestamp: Date
    let mealWindowDurationMinutes: Double
    let mealWindowExtendedDurationMinutes: Double
    let target: Double?
    let isf: Double?
    let carbRatio: Double?
    let maxIOB: Double?
    let smbDeliveryRatio: Double?
    let maxSMBBasalMinutes: Double?
    let maxUAMSMBBasalMinutes: Double?
    let smbInterval: Double?
    let enableUAM: Bool?
    let enableSMBAlways: Bool?
    let enableSMBWithCOB: Bool?
    let enableSMBAfterCarbs: Bool?
    let enableSMBWithTemptarget: Bool?
    let enableSMBHighBG: Bool?
    let enableSMBHighBGTarget: Double?
    let toughMealEnabled: Bool?
    let activeOverrideName: String?
    let activeTempTargetTarget: Double?
}

/// Type-erased JSON value so payload dictionaries can carry mixed types without
/// hand-writing a Codable adapter at every call site.
enum AlgorithmTelemetryJSONValue: Codable {
    case string(String)
    case double(Double)
    case bool(Bool)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

/// Convenience builders so call sites don't have to spell out the enum.
extension AlgorithmTelemetryJSONValue {
    static func from(_ value: Any?) -> AlgorithmTelemetryJSONValue {
        switch value {
        case nil: return .null
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as Decimal: return .double(Double(truncating: v as NSDecimalNumber))
        case let v as String: return .string(v)
        default: return .string(String(describing: value!))
        }
    }
}

/// Shared encoder/decoder so every file uses identical date formatting.
enum AlgorithmTelemetryCoding {
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateFormatter.string(from: date))
        }
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = dateFormatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }()
}
