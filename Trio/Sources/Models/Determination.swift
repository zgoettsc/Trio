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

// Explicit decoders. Two earlier attempts (drop-JSON, make-fields-optional)
// failed despite round-7 diagnostics proving the JSON arrives intact. Synthesized
// Codable was silently producing nil instances for these nested types. Hand-rolled
// init(from:) bypasses whatever interaction was breaking synthesis and gives us
// an obvious error path if any field can't decode.
struct MealWindowFloorData: Codable, Equatable {
    let activated: Bool?
    let prior: Decimal?
    let floored: Decimal?
    let factor: Decimal?
    let risingDelta: Decimal?
    let bg: Decimal?
    let target: Decimal?

    enum CodingKeys: String, CodingKey {
        case activated, prior, floored, factor, risingDelta, bg, target
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activated = try c.decodeIfPresent(Bool.self, forKey: .activated)
        prior = try c.decodeIfPresent(Decimal.self, forKey: .prior)
        floored = try c.decodeIfPresent(Decimal.self, forKey: .floored)
        factor = try c.decodeIfPresent(Decimal.self, forKey: .factor)
        risingDelta = try c.decodeIfPresent(Decimal.self, forKey: .risingDelta)
        bg = try c.decodeIfPresent(Decimal.self, forKey: .bg)
        target = try c.decodeIfPresent(Decimal.self, forKey: .target)
    }
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

    enum CodingKeys: String, CodingKey {
        case smbDeliveryRatio, maxSMBBasalMinutes, maxUAMSMBBasalMinutes
        case toughMealCapPercent, floorBehavior, forcedUAM
        case phantomCOBGrams, relaxedRisingGuard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smbDeliveryRatio = try c.decodeIfPresent(Decimal.self, forKey: .smbDeliveryRatio)
        maxSMBBasalMinutes = try c.decodeIfPresent(Decimal.self, forKey: .maxSMBBasalMinutes)
        maxUAMSMBBasalMinutes = try c.decodeIfPresent(Decimal.self, forKey: .maxUAMSMBBasalMinutes)
        toughMealCapPercent = try c.decodeIfPresent(Decimal.self, forKey: .toughMealCapPercent)
        floorBehavior = try c.decodeIfPresent(String.self, forKey: .floorBehavior)
        forcedUAM = try c.decodeIfPresent(Bool.self, forKey: .forcedUAM)
        phantomCOBGrams = try c.decodeIfPresent(Decimal.self, forKey: .phantomCOBGrams)
        relaxedRisingGuard = try c.decodeIfPresent(Bool.self, forKey: .relaxedRisingGuard)
    }
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
