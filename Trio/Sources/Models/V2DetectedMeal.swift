import Foundation

/// A meal detected from HealthKit/Cronometer observer for the V2 treatment flow.
/// Used in the V2 meal feed to show recent meals the user can select for dosing.
struct V2DetectedMeal: Identifiable {
    let id = UUID()
    let date: Date
    let label: String       // "Lunch", "Snack", or Cronometer meal name
    let carbs: Double
    let fat: Double
    let protein: Double
    let fiber: Double
    let source: String      // "Cronometer", "Apple Health", "Manual"
    let isDosed: Bool       // Whether this meal was already processed through V2
    let healthKitID: String? // HealthKit sample ID for deduplication

    /// Convenience: total calories estimate
    var estimatedCalories: Int {
        Int(carbs * 4 + fat * 9 + protein * 4)
    }

    /// Minutes since this meal was logged
    var minutesAgo: Double {
        Date().timeIntervalSince(date) / 60
    }

    /// Whether this meal is "late" (>60 minutes old)
    var isLate: Bool {
        minutesAgo > 60
    }
}
