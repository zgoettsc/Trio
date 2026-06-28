import Foundation

/// Row schema for `telemetry/<localDate>/meals.jsonl` and
/// `telemetry/meals/history/<mealId>.jsonl`.
///
/// One row per closed SavedMealInstance. See
/// docs/MEAL_INTELLIGENCE_DESIGN.md §7.2.
struct SavedMealTelemetryRow: Encodable {
    let kind: String  // always "savedMealInstance"
    let instanceId: String
    let savedMealId: String
    let savedMealName: String?
    let savedMealNamePrivate: Bool
    let windowId: String
    let startedAt: Date
    let closedAt: Date
    let deviceTimeZone: String?
    let macros: Macros?
    let carbBucket: String?
    let initialClassification: String?
    let finalClassification: String?
    let bgCurveJSON: String?
    let smbsJSON: String?
    let floorActivationsJSON: String?
    let classifierUpgradesJSON: String?
    let outcomeScore: Int
    let metrics: Metrics
    /// Sensitivity/BG context captured at window activation. All optional —
    /// nil when the source value wasn't available (fresh install, sensor
    /// outage, Smart-Sense disabled, <30 min of glucose history). Enables
    /// "does Autosens/Smart-Sense predict excursion size?" analysis.
    let context: ActivationContext?
    let buildSchema: Int

    struct Macros: Encodable {
        let carbs: Double?
        let fat: Double?
        let protein: Double?
    }

    struct Metrics: Encodable {
        let peakBG: Double
        let timeInRangeMinutes: Int
        let timeAboveRangeMinutes: Int
        let timeBelowRangeMinutes: Int
        let lowsCount: Int
        let timeToBaselineMinutes: Int
        let totalInsulinDeliveredU: Double
        let smbCount: Int
        let floorActivationCount: Int
    }

    struct ActivationContext: Encodable {
        /// BG (mg/dL) at the moment the window opened.
        let bgAtActivation: Double?
        /// Δ BG over the prior 30 min (mg/dL). Positive = rising into the
        /// meal; negative = falling.
        let bgTrendAtActivation: Double?
        /// Oref Autosens ratio (1.0 = neutral, >1 = resistant, <1 = sensitive).
        let autosensRatioAtActivation: Double?
        /// Smart Sense final blended ratio (post-Autosens, post-Garmin).
        let smartSenseRatioAtActivation: Double?
        /// Effective ISF (mg/dL per U) used by oref at activation — already
        /// adjusted by Autosens. Useful for comparing dosing pressure across
        /// instances of the same meal at different sensitivity readings.
        let effectiveISFAtActivation: Double?
        /// CR (g/U) at activation. Needed for the "estimated carbs from BG
        /// response" back-calculation: 1g carbs raises BG by ISF/CR mg/dL,
        /// so given observed rise + delivered insulin we can solve for the
        /// implied carbs the meal "looked like."
        let carbRatioAtActivation: Double?
    }
}

/// Snapshot of all SavedMeal definitions, rewritten on every CRUD action.
/// Written to `telemetry/meals/definitions.json`. See §7.3.
struct SavedMealDefinitionsSnapshot: Encodable {
    let lastUpdated: Date
    let deviceTimeZone: String?
    let meals: [String: MealDef]

    struct MealDef: Encodable {
        let id: String
        let name: String?
        let icon: String?
        let createdAt: Date?
        let updatedAt: Date?
        let defaults: Defaults
        let stats: Stats

        struct Defaults: Encodable {
            let carbs: Double?
            let fat: Double?
            let protein: Double?
            let classification: String?
            let extendedDurationMinutes: Int?
            let phantomCOBEnabled: Bool?
            let phantomCOBGrams: Double?
        }

        struct Stats: Encodable {
            let instanceCount: Int
            let recommendedClassification: String?
        }
    }
}
