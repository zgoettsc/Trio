import Foundation

struct Determination: JSON, Equatable {
    let id: UUID?
    var reason: String
    let units: Decimal?
    let insulinReq: Decimal?
    var eventualBG: Int?
    let sensitivityRatio: Decimal?
    let rate: Decimal?
    let duration: Decimal?
    let iob: Decimal?
    let cob: Decimal?
    var predictions: Predictions?
    var deliverAt: Date?
    let carbsReq: Decimal?
    let temp: TempType?
    var bg: Decimal?
    let reservoir: Decimal?
    var isf: Decimal?
    var timestamp: Date?

    /// `tdd` (Total Daily Dose) is included so it can be part of the
    /// enacted and suggested devicestatus data that gets uploaded to Nightscout.
    var tdd: Decimal?

    var current_target: Decimal?
    let insulinForManualBolus: Decimal?
    let manualBolusErrorString: Decimal?
    var minDelta: Decimal?
    var expectedDelta: Decimal?
    var minGuardBG: Decimal?
    var minPredBG: Decimal?
    var threshold: Decimal?
    let carbRatio: Decimal?
    let received: Bool?

    /// Optional structured data attached by determine-basal.js when the meal-window
    /// insulinReq floor fires. Read by AlgorithmTelemetry to avoid having to parse
    /// the human-readable `reason` string. Nil when the floor did not activate.
    var mealWindowFloor: MealWindowFloorData?

    /// Snapshot of the eating-mode tuning values actually applied this pass
    /// (PLAN.md items 1-6). Populated by JS whenever the meal window is active.
    var mealWindowApplied: MealWindowAppliedData?
}

// Plain Codable, NOT the JSON protocol. The JSON protocol's `init?(from: String)`
// extension was preventing the Codable synthesizer from generating the
// `init(from decoder: Decoder)` these need to decode as nested fields of
// Determination — round-7 diagnostics proved the JSON arrives intact but the
// inner decode silently fails. These types are never decoded standalone, so
// they don't need JSON's String-to-self plumbing.
struct MealWindowFloorData: Codable, Equatable {
    let activated: Bool?
    let prior: Decimal?
    let floored: Decimal?
    let factor: Decimal?
    let risingDelta: Decimal?
    let bg: Decimal?
    let target: Decimal?
}

struct MealWindowAppliedData: Codable, Equatable {
    let smbDeliveryRatio: Decimal?
    let maxSMBBasalMinutes: Decimal?
    let maxUAMSMBBasalMinutes: Decimal?
    let toughMealCapPercent: Decimal?
    let floorBehavior: String?          // "off" / "replacement" / "additive"
    let forcedUAM: Bool?
    let phantomCOBGrams: Decimal?       // 0 if none injected this pass
    let relaxedRisingGuard: Bool?
}

struct Predictions: JSON, Equatable {
    let iob: [Int]?
    let zt: [Int]?
    let cob: [Int]?
    let uam: [Int]?
}

extension Determination {
    private enum CodingKeys: String, CodingKey {
        case id
        case reason
        case units
        case insulinReq
        case eventualBG
        case sensitivityRatio
        case rate
        case duration
        case iob = "IOB"
        case cob = "COB"
        case predictions = "predBGs"
        case deliverAt
        case carbsReq
        case temp
        case bg
        case reservoir
        case timestamp
        case isf = "ISF"
        case current_target
        case tdd = "TDD"
        case insulinForManualBolus
        case manualBolusErrorString
        case minDelta
        case expectedDelta
        case minGuardBG
        case minPredBG
        case threshold
        case carbRatio = "CR"
        case received
        case mealWindowFloor
        case mealWindowApplied
    }
}

extension Predictions {
    private enum CodingKeys: String, CodingKey {
        case iob = "IOB"
        case zt = "ZT"
        case cob = "COB"
        case uam = "UAM"
    }
}

protocol DeterminationObserver {
    func determinationDidUpdate(_ determination: Determination)
}

extension Determination {
    var reasonParts: [String] {
        reason.components(separatedBy: "; ").first?.components(separatedBy: ", ") ?? []
    }

    var reasonConclusion: String {
        reason.components(separatedBy: "; ").last ?? ""
    }
}
