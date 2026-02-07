import Foundation

// MARK: - Phase E: Macros On Board (MOB) Tracking System
//
// Tracks active meals being absorbed, manages dosing state per meal,
// and provides double-dose protection.

// MARK: - Dosing State

/// Tracks whether the user has dosed for a detected meal.
enum MealDosingState: Codable, Equatable {
    case undosed                                        // meal detected, user hasn't responded
    case dosed(at: Date, units: Double)                 // user confirmed bolus
    case adjusted(at: Date, units: Double, overridePercent: Double) // user used slider
    case skipped(at: Date)                              // user chose to skip

    var isDosed: Bool {
        switch self {
        case .dosed, .adjusted: return true
        case .undosed, .skipped: return false
        }
    }

    var dosedUnits: Double? {
        switch self {
        case .dosed(_, let units), .adjusted(_, let units, _): return units
        default: return nil
        }
    }
}

// MARK: - Active Meal

/// A detected meal currently being absorbed by the three-curve engine.
struct ActiveMeal: Identifiable, Codable {
    let id: String                      // unique mealID (matches fpuID on entries)
    let detectedAt: Date
    let originalCarbs: Double
    let originalFat: Double
    let originalProtein: Double
    let insulinDemandFactor: Double
    let upfrontCarbs: Double            // demand-adjusted carbs for bolus
    let upfrontPercent: Double
    let curveSuggestedPercent: Double
    let tauCarb: Double
    let fatTotalEquiv: Double
    let safeWindowMinutes: Int
    var dosingState: MealDosingState
    var adjustmentHistory: [AdjustmentRecord]

    struct AdjustmentRecord: Codable {
        let timestamp: Date
        let scalingFactor: Double
    }

    /// Estimated time when this meal's absorption is complete (95% of gamma curve)
    var estimatedCompletionTime: Date {
        let duration = MacroAbsorptionEngine.carbAbsorptionDuration(tau: tauCarb)
        // Use the maximum of carb duration and fat resistance window (9h)
        let maxDuration = max(duration, fatTotalEquiv > 0 ? 540 : duration)
        return detectedAt.addingTimeInterval(maxDuration * 60)
    }

    /// Whether this meal still has entries being absorbed
    var isActive: Bool {
        Date() < estimatedCompletionTime
    }
}

// MARK: - MOB Tracker

/// Tracks all active meals and provides double-dose protection.
final class MacrosOnBoardTracker: ObservableObject {

    @Published var activeMeals: [ActiveMeal] = []

    /// Storage key for persistence
    private static let storageKey = "MacrosOnBoardActiveMeals"

    // MARK: - Meal Management

    /// Register a new detected meal. Returns false if a duplicate is detected.
    @discardableResult
    func registerMeal(from result: MacroAbsorptionResult) -> Bool {
        // Double-dose protection: check for duplicate meals
        if isDuplicate(carbs: result.originalCarbs, fat: result.originalFat,
                       protein: result.originalProtein, mealTime: Date())
        {
            return false
        }

        let meal = ActiveMeal(
            id: result.mealID,
            detectedAt: Date(),
            originalCarbs: result.originalCarbs,
            originalFat: result.originalFat,
            originalProtein: result.originalProtein,
            insulinDemandFactor: result.insulinDemandFactor,
            upfrontCarbs: result.upfrontCarbs,
            upfrontPercent: result.upfrontPercent,
            curveSuggestedPercent: result.curveSuggestedPercent,
            tauCarb: result.tauCarb,
            fatTotalEquiv: result.fatTotalEquiv,
            safeWindowMinutes: result.safeWindowMinutes,
            dosingState: .undosed,
            adjustmentHistory: []
        )

        activeMeals.append(meal)
        pruneCompletedMeals()
        save()
        return true
    }

    /// Update dosing state for a meal.
    func updateDosingState(mealID: String, state: MealDosingState) {
        guard let index = activeMeals.firstIndex(where: { $0.id == mealID }) else { return }
        activeMeals[index].dosingState = state
        save()
    }

    /// Record a BG-adaptive adjustment for a meal.
    func recordAdjustment(mealID: String, scalingFactor: Double) {
        guard let index = activeMeals.firstIndex(where: { $0.id == mealID }) else { return }
        activeMeals[index].adjustmentHistory.append(
            ActiveMeal.AdjustmentRecord(timestamp: Date(), scalingFactor: scalingFactor)
        )
        save()
    }

    // MARK: - Double-Dose Protection

    /// Check if a meal with similar macros was recently detected (within 15 min).
    /// Uses 70% overlap threshold to catch duplicates while allowing distinct meals.
    func isDuplicate(carbs: Double, fat: Double, protein: Double, mealTime: Date) -> Bool {
        let window: TimeInterval = 15 * 60 // 15 minutes

        return activeMeals.contains { meal in
            let timeDiff = abs(mealTime.timeIntervalSince(meal.detectedAt))
            guard timeDiff <= window else { return false }

            // Check macro similarity (>70% overlap)
            let carbOverlap = macroOverlap(meal.originalCarbs, carbs)
            let fatOverlap = macroOverlap(meal.originalFat, fat)
            let proteinOverlap = macroOverlap(meal.originalProtein, protein)

            return carbOverlap > 0.7 && fatOverlap > 0.7 && proteinOverlap > 0.7
        }
    }

    /// Check if the user has already dosed for a meal close to these macros.
    /// Used to warn when user navigates to manual bolus.
    func recentlyDosedMeal(nearCarbs carbs: Double, withinMinutes: Int = 120) -> ActiveMeal? {
        let window = TimeInterval(withinMinutes * 60)
        return activeMeals.first { meal in
            meal.dosingState.isDosed &&
                abs(Date().timeIntervalSince(meal.detectedAt)) <= window &&
                macroOverlap(meal.originalCarbs, carbs) > 0.5
        }
    }

    /// Merge new macros into an existing active meal (for multi-item Cronometer entries
    /// arriving within the 15-min grouping window).
    func mergeIntoExistingMeal(mealID: String, additionalCarbs: Double, additionalFat: Double, additionalProtein: Double) {
        // Merging requires regenerating entries — this is handled by the caller
        // who will delete old entries for this mealID and regenerate with updated macros.
        // The tracker just needs to know the updated totals.
        guard let index = activeMeals.firstIndex(where: { $0.id == mealID }) else { return }

        // Create updated meal with combined macros
        var updated = activeMeals[index]
        let newMeal = ActiveMeal(
            id: updated.id,
            detectedAt: updated.detectedAt,
            originalCarbs: updated.originalCarbs + additionalCarbs,
            originalFat: updated.originalFat + additionalFat,
            originalProtein: updated.originalProtein + additionalProtein,
            insulinDemandFactor: updated.insulinDemandFactor,
            upfrontCarbs: updated.upfrontCarbs,
            upfrontPercent: updated.upfrontPercent,
            curveSuggestedPercent: updated.curveSuggestedPercent,
            tauCarb: updated.tauCarb,
            fatTotalEquiv: updated.fatTotalEquiv,
            safeWindowMinutes: updated.safeWindowMinutes,
            dosingState: updated.dosingState,
            adjustmentHistory: updated.adjustmentHistory
        )
        activeMeals[index] = newMeal
        save()
    }

    // MARK: - Computed Properties

    /// Any undosed meal waiting for user response
    var hasUndosedMeal: Bool {
        activeMeals.contains { $0.dosingState == .undosed && $0.isActive }
    }

    /// The most recent undosed meal (for the banner)
    var latestUndosedMeal: ActiveMeal? {
        activeMeals.last { $0.dosingState == .undosed && $0.isActive }
    }

    /// Whether any meal is currently in its absorption window
    var hasMealInAbsorptionWindow: Bool {
        activeMeals.contains { $0.isActive }
    }

    /// Set of active mealIDs (for meal-mode SMB gate)
    var activeMealIDs: Set<String> {
        Set(activeMeals.filter { $0.isActive }.map { $0.id })
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(activeMeals) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let meals = try? JSONDecoder().decode([ActiveMeal].self, from: data)
        else { return }
        activeMeals = meals
        pruneCompletedMeals()
    }

    private func pruneCompletedMeals() {
        // Remove meals that completed more than 2 hours ago
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        activeMeals.removeAll { !$0.isActive && $0.estimatedCompletionTime < cutoff }
    }

    // MARK: - Helpers

    private func macroOverlap(_ a: Double, _ b: Double) -> Double {
        guard a > 0 || b > 0 else { return 1.0 } // both zero = perfect match
        guard a > 0 && b > 0 else { return 0.0 } // one zero, other not = no match
        return min(a, b) / max(a, b)
    }
}

// Extend MealDosingState for Equatable on associated values
extension MealDosingState {
    static func == (lhs: MealDosingState, rhs: MealDosingState) -> Bool {
        switch (lhs, rhs) {
        case (.undosed, .undosed): return true
        case (.skipped, .skipped): return true
        case let (.dosed(at1, u1), .dosed(at2, u2)): return at1 == at2 && u1 == u2
        case let (.adjusted(at1, u1, p1), .adjusted(at2, u2, p2)): return at1 == at2 && u1 == u2 && p1 == p2
        default: return false
        }
    }
}
