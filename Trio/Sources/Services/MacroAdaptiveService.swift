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

        // BG-Adaptive Real-Time Correction
        //
        // For each active meal, estimate the predicted BG impact from its curve entries
        // and compare with actual BG. If reality diverges, scale remaining entries.
        //
        // Predicted BG impact = sum of carb entries already absorbed * (1/CR) * ISF
        //   (how much BG should have risen from absorbed carbs minus IOB action)
        // Actual BG delta = currentBG - BG at meal start (or baseline)
        // Error = actual delta - predicted delta
        //   Positive error: BG higher than expected → scale UP remaining entries
        //   Negative error: BG lower than expected → scale DOWN remaining entries

        for mealID in activeMealIDs {
            // Compute absorbed carbs: sum of past entries for this meal
            let absorbedAndRemaining = await fetchAbsorbedAndRemainingCarbs(
                mealID: mealID,
                context: context
            )

            let absorbedCarbs = absorbedAndRemaining.absorbed
            let remainingCarbs = absorbedAndRemaining.remaining

            // Skip if no entries have been absorbed yet
            guard absorbedCarbs > 0, remainingCarbs > 0 else { continue }

            // Predicted BG impact: absorbed carbs → insulin needed → BG effect
            // Each absorbed gram of carb-equivalent should raise BG by ISF/CR mg/dL
            // IOB is working to bring it down. So predicted BG = baseline + (absorbed/CR)*ISF - IOB*ISF
            let predictedBGImpact = (absorbedCarbs / cr) * isf - currentIOB * isf

            // We don't know the pre-meal baseline BG, but we can use the trend:
            // If actual BG is higher than predicted, the model is under-estimating the meal impact.
            // The key signal: is BG rising faster/higher than the curve predicted?
            //
            // Simplified approach: use the BG error relative to predicted impact.
            // error = (actual trend * minutes_since_first_entry / 5) vs predictedBGImpact
            let trendBasedActual = trend * (absorbedAndRemaining.minutesSinceFirst / 5.0)
            let error = trendBasedActual - predictedBGImpact

            // Only adjust if error exceeds threshold
            guard abs(error) > Self.errorThreshold else { continue }

            // Compute scaling factor: 1.0 + (error / scalingConstant)
            let rawScaling = 1.0 + (error / Self.scalingConstant)

            // Blend: apply 50% of trend correction immediately (prevents overreaction)
            let blendedScaling = 1.0 + (rawScaling - 1.0) * 0.5

            // Scale future entries
            await scaleFutureEntries(
                mealID: mealID,
                scalingFactor: blendedScaling,
                context: context
            )

            // Record adjustment for audit trail
            let adjustment = AdaptiveAdjustment(
                timestamp: Date(),
                actualBG: bg,
                predictedBG: bg - error,
                error: error,
                trendError: trend - (predictedBGImpact * 5.0 / max(1, absorbedAndRemaining.minutesSinceFirst)),
                scalingFactor: blendedScaling,
                cumulativeScaling: cumulativeScaling[mealID] ?? 1.0,
                mealID: mealID
            )
            adjustmentHistory.append(adjustment)
        }

        return mealMode
    }

    // MARK: - Entry Analysis

    /// Fetch absorbed (past) and remaining (future) carbs for a meal.
    private func fetchAbsorbedAndRemainingCarbs(
        mealID: String,
        context: NSManagedObjectContext
    ) async -> (absorbed: Double, remaining: Double, minutesSinceFirst: Double) {
        await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "fpuID == %@", UUID(uuidString: mealID)! as CVarArg),
                NSPredicate(format: "isFPU == YES")
            ])
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            do {
                let entries = try context.fetch(fetchRequest)
                let now = Date()
                var absorbed = 0.0
                var remaining = 0.0
                var earliestDate: Date?

                for entry in entries {
                    guard let entryDate = entry.date else { continue }
                    if earliestDate == nil { earliestDate = entryDate }

                    if entryDate <= now {
                        absorbed += entry.carbs
                    } else {
                        remaining += entry.carbs
                    }
                }

                let minutesSinceFirst = earliestDate.map { now.timeIntervalSince($0) / 60.0 } ?? 0
                return (absorbed, remaining, minutesSinceFirst)
            } catch {
                return (0, 0, 0)
            }
        }
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
