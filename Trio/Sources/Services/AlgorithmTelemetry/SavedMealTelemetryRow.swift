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
