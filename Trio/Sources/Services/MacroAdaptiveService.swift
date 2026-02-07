import CoreData
import Foundation

// MARK: - Phase B: BG-Adaptive Real-Time Correction
//
// Runs BEFORE oref each loop cycle. Compares predicted BG from our
// three-curve model to actual CGM, adjusts remaining future entries,
// and evaluates meal-mode SMB enhancement.

// MARK: - Meal Mode State

/// Evaluates whether meal-mode SMB enhancement should be active.
/// All safety gates must pass independently each cycle.
struct MealModeState {
    let isActive: Bool
    let effectiveMaxSMBMinutes: Decimal // user's maxSMBBasalMinutes, or enhanced value

    /// Evaluate all safety gates for meal-mode SMB enhancement.
    /// If ANY gate fails, maxSMB reverts to the user's base value instantly.
    static func evaluate(
        hasActiveMealEntries: Bool,
        currentBG: Double?,
        bgTrend: Double?,           // mg/dL per 5min, positive = rising
        cgmAgeSeconds: TimeInterval?,
        userMaxSMBMinutes: Decimal,
        mealSMBMultiplier: Double,  // user setting, default 2.0
        bgFloor: Double             // user setting, default 90 mg/dL
    ) -> MealModeState {
        let baseState = MealModeState(isActive: false, effectiveMaxSMBMinutes: userMaxSMBMinutes)

        // Gate 1: Active meal entries exist in the future
        guard hasActiveMealEntries else { return baseState }

        // Gate 2: BG data available and above floor
        guard let bg = currentBG, bg > bgFloor else { return baseState }

        // Gate 3: BG trend flat or rising (allow slight dip, not rapid fall)
        guard let trend = bgTrend, trend >= -1.0 else { return baseState }

        // Gate 4: CGM data is fresh (< 10 minutes old)
        guard let age = cgmAgeSeconds, age < 600 else { return baseState }

        // All gates pass: enable meal-mode enhanced SMBs
        let enhancedMinutes = Decimal(Double(truncating: userMaxSMBMinutes as NSDecimalNumber) * mealSMBMultiplier)
        return MealModeState(
            isActive: true,
            effectiveMaxSMBMinutes: enhancedMinutes
        )
    }
}

// MARK: - Adaptive Adjustment Record

/// Records a single BG-adaptive adjustment for audit/learning.
struct AdaptiveAdjustment: Codable {
    let timestamp: Date
    let actualBG: Double
    let predictedBG: Double
    let error: Double               // actual - predicted
    let trendError: Double          // actual trend - predicted trend
    let scalingFactor: Double       // multiplier applied to remaining entries
    let cumulativeScaling: Double   // total cumulative adjustment from original
    let mealID: String
}

// MARK: - Adaptive Service

/// BG-Adaptive service that runs before oref each loop cycle.
/// Compares predicted BG from the three-curve model to actual CGM
/// and adjusts future entries to correct for model inaccuracy.
final class MacroAdaptiveService {

    // MARK: - Constants

    /// Minimum error (mg/dL) before making an adjustment
    private static let errorThreshold: Double = 15.0

    /// How much a 100 mg/dL error scales remaining entries
    private static let scalingConstant: Double = 100.0

    /// Maximum single-cycle scaling factor (±50%)
    private static let maxCycleScaling: Double = 1.5
    private static let minCycleScaling: Double = 0.5

    /// Maximum cumulative scaling from original (±100%)
    private static let maxCumulativeScaling: Double = 2.0
    private static let minCumulativeScaling: Double = 0.0

    /// Minimum time between adjustments (seconds) to prevent oscillation
    private static let dampingInterval: TimeInterval = 15 * 60 // 15 minutes

    /// BG floor: don't increase entries when BG is low
    private static let lowBGGuard: Double = 80.0

    /// BG ceiling: don't chase extreme highs
    private static let highBGGuard: Double = 300.0

    /// Maximum CGM age for adjustments (seconds)
    private static let maxCGMAge: TimeInterval = 15 * 60 // 15 minutes

    // MARK: - State

    private var lastAdjustmentTime: Date?
    private var cumulativeScaling: [String: Double] = [:] // mealID -> cumulative factor
    private var adjustmentHistory: [AdaptiveAdjustment] = []

    // MARK: - Main Loop Hook

    /// Called BEFORE oref runs each loop cycle.
    /// Returns the meal-mode state (with effective maxSMB) for this cycle.
    ///
    /// - Parameters:
    ///   - currentBG: Latest CGM reading (mg/dL)
    ///   - bgTrend: BG trend (mg/dL per 5 min, positive = rising)
    ///   - cgmTimestamp: When the CGM reading was taken
    ///   - currentIOB: Current insulin on board (units)
    ///   - isf: Current insulin sensitivity factor (mg/dL per unit)
    ///   - cr: Current carb ratio (grams per unit)
    ///   - activeMealIDs: Set of mealIDs that have future entries
    ///   - context: Core Data context for fetching/updating entries
    ///   - userMaxSMBMinutes: User's configured maxSMBBasalMinutes
    ///   - mealSMBMultiplier: Meal-mode multiplier (default 2.0)
    ///   - bgFloor: BG floor for meal-mode activation (default 90)
    func runAdaptiveCycle(
        currentBG: Double?,
        bgTrend: Double?,
        cgmTimestamp: Date?,
        currentIOB: Double,
        isf: Double,
        cr: Double,
        activeMealIDs: Set<String>,
        context: NSManagedObjectContext,
        userMaxSMBMinutes: Decimal,
        mealSMBMultiplier: Double = 2.0,
        bgFloor: Double = 90.0
    ) async -> MealModeState {
        let hasActiveMeals = !activeMealIDs.isEmpty

        let cgmAge: TimeInterval? = cgmTimestamp.map { Date().timeIntervalSince($0) }

        // Always evaluate meal-mode state (independent of adaptive adjustments)
        let mealMode = MealModeState.evaluate(
            hasActiveMealEntries: hasActiveMeals,
            currentBG: currentBG,
            bgTrend: bgTrend,
            cgmAgeSeconds: cgmAge,
            userMaxSMBMinutes: userMaxSMBMinutes,
            mealSMBMultiplier: mealSMBMultiplier,
            bgFloor: bgFloor
        )

        // Adaptive entry adjustment (only if we have data and active meals)
        guard let bg = currentBG,
              let trend = bgTrend,
              let age = cgmAge,
              age < Self.maxCGMAge,
              hasActiveMeals
        else {
            return mealMode
        }

        // Check damping interval
        if let lastTime = lastAdjustmentTime,
           Date().timeIntervalSince(lastTime) < Self.dampingInterval
        {
            return mealMode
        }

        // Safety guards
        guard bg >= Self.lowBGGuard else { return mealMode } // don't increase entries when low
        guard bg <= Self.highBGGuard else { return mealMode } // don't chase extreme highs

        // For now, we skip the predicted BG computation (requires curve state tracking).
        // The BG-adaptive adjustments will be wired up once the full loop integration
        // is connected and we have access to the curve state per meal.
        // The meal-mode SMB enhancement is the primary Phase B deliverable.

        return mealMode
    }

    /// Scale future entries for a given mealID by the adjustment factor.
    /// Only modifies entries with actualDate in the future.
    func scaleFutureEntries(
        mealID: String,
        scalingFactor: Double,
        context: NSManagedObjectContext
    ) async {
        // Clamp single-cycle scaling
        let clampedFactor = min(Self.maxCycleScaling, max(Self.minCycleScaling, scalingFactor))

        // Track cumulative scaling
        let currentCumulative = cumulativeScaling[mealID] ?? 1.0
        let newCumulative = currentCumulative * clampedFactor
        let finalCumulative = min(Self.maxCumulativeScaling, max(Self.minCumulativeScaling, newCumulative))
        let effectiveFactor = finalCumulative / currentCumulative

        guard abs(effectiveFactor - 1.0) > 0.01 else { return } // skip trivial adjustments

        cumulativeScaling[mealID] = finalCumulative
        lastAdjustmentTime = Date()

        await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "fpuID == %@", UUID(uuidString: mealID)! as CVarArg),
                NSPredicate(format: "isFPU == YES"),
                NSPredicate(format: "date > %@", Date() as NSDate)
            ])

            do {
                let entries = try context.fetch(fetchRequest)
                for entry in entries {
                    entry.carbs *= effectiveFactor
                }
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                debugPrint("MacroAdaptiveService: failed to scale entries for meal \(mealID): \(error)")
            }
        }
    }

    /// Check if any mealID has future entries (for meal-mode gate).
    static func hasActiveMealEntries(context: NSManagedObjectContext) async -> Bool {
        await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isFPU == YES"),
                NSPredicate(format: "date > %@", Date() as NSDate)
            ])
            fetchRequest.fetchLimit = 1
            return (try? context.count(for: fetchRequest)) ?? 0 > 0
        }
    }

    /// Get the set of active mealIDs that have future entries.
    static func activeMealIDs(context: NSManagedObjectContext) async -> Set<String> {
        await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isFPU == YES"),
                NSPredicate(format: "date > %@", Date() as NSDate),
                NSPredicate(format: "fpuID != nil")
            ])
            fetchRequest.propertiesToFetch = ["fpuID"]
            fetchRequest.returnsDistinctResults = true

            do {
                let entries = try context.fetch(fetchRequest)
                return Set(entries.compactMap { $0.fpuID?.uuidString })
            } catch {
                return []
            }
        }
    }

    /// Reset state for a completed meal.
    func mealCompleted(mealID: String) {
        cumulativeScaling.removeValue(forKey: mealID)
    }
}
