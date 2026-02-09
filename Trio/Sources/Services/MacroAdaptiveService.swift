import CoreData
import Foundation

// MARK: - Phase B: BG-Adaptive Real-Time Correction
//
// Runs BEFORE oref each loop cycle. Compares predicted BG from our
// three-curve model to actual CGM, adjusts remaining future entries,
// and evaluates meal-mode SMB enhancement.

// MARK: - Meal Insulin Record (S1: IOB Decay)

/// A single insulin delivery event attributed to a meal, with a timestamp
/// so we can model decay using the user's DIA.
struct MealInsulinRecord: Codable {
    let units: Double
    let timestamp: Date
}

// MARK: - IOB Decay Curves (ported from trio-oref/lib/iob/calculate.js)

/// Models insulin-on-board decay using the same curves as oref.
/// Supports bilinear, rapid-acting (exponential), and ultra-rapid (exponential) models.
enum IOBDecayCurve {
    case bilinear
    case exponential(peakMinutes: Double) // rapid-acting: 75, ultra-rapid: 55

    /// Compute the fraction of insulin remaining (IOB) at `minsAgo` minutes after delivery.
    /// Matches oref's iobCalc output exactly.
    func fractionRemaining(minsAgo: Double, diaHours: Double) -> Double {
        guard minsAgo >= 0, diaHours > 0 else { return minsAgo < 0 ? 1.0 : 0.0 }

        switch self {
        case .bilinear:
            return bilinearIOB(minsAgo: minsAgo, diaHours: diaHours)
        case .exponential(let peakMinutes):
            return exponentialIOB(minsAgo: minsAgo, diaHours: diaHours, peak: peakMinutes)
        }
    }

    /// Bilinear model — piecewise quadratic polynomials.
    /// Ported from iobCalcBilinear in trio-oref/lib/iob/calculate.js
    private func bilinearIOB(minsAgo: Double, diaHours: Double) -> Double {
        let defaultDIA: Double = 3.0
        let peak: Double = 75.0
        let end: Double = 180.0

        let timeScalar = defaultDIA / diaHours
        let scaledMinsAgo = timeScalar * minsAgo

        if scaledMinsAgo >= end { return 0.0 }

        if scaledMinsAgo < peak {
            let x1 = (scaledMinsAgo / 5.0) + 1.0
            return (-0.001852 * x1 * x1) + (0.001852 * x1) + 1.0
        } else {
            let x2 = (scaledMinsAgo - peak) / 5.0
            return (0.001323 * x2 * x2) + (-0.054233 * x2) + 0.555560
        }
    }

    /// Exponential model — from LoopKit/Loop.
    /// Ported from iobCalcExponential in trio-oref/lib/iob/calculate.js
    private func exponentialIOB(minsAgo: Double, diaHours: Double, peak: Double) -> Double {
        let end = diaHours * 60.0 // end of insulin activity in minutes

        guard minsAgo < end else { return 0.0 }

        // Formula from https://github.com/LoopKit/Loop/issues/388#issuecomment-317938473
        let tau = peak * (1.0 - peak / end) / (1.0 - 2.0 * peak / end)
        let a = 2.0 * tau / end
        let S = 1.0 / (1.0 - a + (1.0 + a) * exp(-end / tau))

        let iobContrib = 1.0 - S * (1.0 - a) * (
            (pow(minsAgo, 2) / (tau * end * (1.0 - a)) - minsAgo / tau - 1.0) * exp(-minsAgo / tau) + 1.0
        )
        return max(0, iobContrib)
    }
}

// MARK: - Meal Mode State

/// Evaluates whether meal-mode SMB enhancement should be active.
/// All safety gates must pass independently each cycle.
struct MealModeState {
    let isActive: Bool
    let effectiveMaxSMBMinutes: Decimal // user's maxSMBBasalMinutes, or enhanced value

    /// Hysteresis flag for Gate 3 trend threshold.
    /// Once the gate fails (trend drops below threshold), require trend to recover
    /// to reEnableThreshold before re-enabling — prevents rapid toggling near CGM noise floor.
    private static let gate3Lock = NSLock()
    private static var _gate3FailedLastCycle = false
    private static var gate3FailedLastCycle: Bool {
        get { gate3Lock.lock(); defer { gate3Lock.unlock() }; return _gate3FailedLastCycle }
        set { gate3Lock.lock(); defer { gate3Lock.unlock() }; _gate3FailedLastCycle = newValue }
    }

    /// Evaluate all safety gates for meal-mode SMB enhancement.
    /// If ANY gate fails, maxSMB reverts to the user's base value instantly.
    static func evaluate(
        hasActiveMealEntries: Bool,
        currentBG: Double?,
        bgTrend: Double?,           // mg/dL per 5min, positive = rising
        cgmAgeSeconds: TimeInterval?,
        currentIOB: Double,
        remainingCarbsForActiveMeals: Double,
        carbRatio: Double,
        userMaxSMBMinutes: Decimal,
        mealSMBMultiplier: Double,  // user setting, default 2.0
        bgFloor: Double,            // user setting, default 90 mg/dL
        compositeDemandFactor: Double = 1.0 // current composite demand (Garmin × adaptive)
    ) -> MealModeState {
        let baseState = MealModeState(isActive: false, effectiveMaxSMBMinutes: userMaxSMBMinutes)

        // Gate 1: Active meal entries exist in the future
        guard hasActiveMealEntries else { return baseState }

        // Gate 2: BG data available and above floor
        guard let bg = currentBG, bg > bgFloor else { return baseState }

        // Gate 3: BG trend flat or rising, with hysteresis (#7)
        // Threshold of -3.0 matches whitepaper range; hysteresis prevents toggling near noise floor
        let trendThreshold: Double = -3.0
        let reEnableThreshold: Double = 0.0

        if gate3FailedLastCycle {
            // Once failed, require trend to recover to 0 before re-enabling
            guard let trend = bgTrend, trend >= reEnableThreshold else {
                gate3FailedLastCycle = true
                return baseState
            }
            gate3FailedLastCycle = false
        } else {
            guard let trend = bgTrend, trend >= trendThreshold else {
                gate3FailedLastCycle = true
                return baseState
            }
        }

        // Gate 4: CGM data is fresh (< 10 minutes old)
        guard let age = cgmAgeSeconds, age < 600 else { return baseState }

        // Gate 5: IOB should not exceed remaining predicted need (#5)
        // Prevents insulin stacking where BG looks fine but IOB is accumulating
        if carbRatio > 0, remainingCarbsForActiveMeals > 0 {
            let remainingInsulinNeed = remainingCarbsForActiveMeals / carbRatio
            guard currentIOB <= remainingInsulinNeed * 1.2 else { return baseState } // 20% buffer
        }

        // All gates pass: enable meal-mode enhanced SMBs.
        // When composite demand (Garmin × adaptive) is already high, reduce the SMB rate multiplier
        // to avoid front-loading a large insulin commitment before BG data can confirm it's needed.
        var effectiveMultiplier = mealSMBMultiplier
        if compositeDemandFactor > 2.0 {
            // Above 2.0x composite demand, cap SMB multiplier at 1.5x
            effectiveMultiplier = min(effectiveMultiplier, 1.5)
        } else if compositeDemandFactor > 1.5 {
            // Between 1.5-2.0x, linearly reduce from full multiplier toward 1.5x
            let ratio = (compositeDemandFactor - 1.5) / 0.5 // 0.0 at 1.5x, 1.0 at 2.0x
            effectiveMultiplier = effectiveMultiplier - ratio * max(0, effectiveMultiplier - 1.5)
        }

        if effectiveMultiplier < mealSMBMultiplier {
            debug(
                .apsManager,
                "S2b SMB rate reduced: composite demand \(String(format: "%.2f", compositeDemandFactor))x " +
                "→ SMB multiplier \(String(format: "%.1f", mealSMBMultiplier))x reduced to " +
                "\(String(format: "%.1f", effectiveMultiplier))x"
            )
        }

        let enhancedMinutes = Decimal(Double(truncating: userMaxSMBMinutes as NSDecimalNumber) * effectiveMultiplier)
        return MealModeState(
            isActive: true,
            effectiveMaxSMBMinutes: enhancedMinutes
        )
    }

    /// Reset hysteresis state (for testing)
    static func resetHysteresis() {
        gate3FailedLastCycle = false
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

    /// (S2) Default maximum composite demand multiplier (Garmin demand × adaptive scaling).
    /// Prevents compounding multipliers from delivering more than 2.5x the base engine calculation.
    private static let defaultMaxCompositeDemand: Double = 2.5

    /// (L1) Minimum buffer time (seconds) before counting an entry as "absorbed".
    /// Actual buffer is max(this, timeSinceLastLoop) — adapts to delayed loop cycles.
    private static let minAbsorptionBuffer: TimeInterval = 5 * 60 // one standard oref cycle

    /// Auto-degradation: if a meal hits the composite ceiling this many consecutive times,
    /// decay its cumulativeScaling toward 1.0 to reduce aggressiveness.
    private static let ceilingHitDegradationThreshold = 3
    private static let degradationDecayFactor = 0.8 // multiply cumulative by this on degradation

    // MARK: - Thread Safety

    /// Protects all mutable instance state from concurrent access.
    /// runAdaptiveCycle is called from the loop timer; recordMealInsulin can be called
    /// from bolus delivery paths. This lock covers cumulativeScaling, mealInsulinRecords,
    /// mealDemandFactors, lastAdjustmentTime, adjustmentHistory, and ceilingHitCounts.
    private let stateLock = NSLock()

    // MARK: - State

    private var lastAdjustmentTime: Date?
    private var cumulativeScaling: [String: Double] = [:] // mealID -> cumulative factor
    private var adjustmentHistory: [AdaptiveAdjustment] = []

    /// (S1) Per-meal timestamped insulin records for decay-aware IOB tracking.
    private var mealInsulinRecords: [String: [MealInsulinRecord]] = [:]

    /// (S2) Per-meal demand factor from Garmin/engine at meal creation time.
    private var mealDemandFactors: [String: Double] = [:]

    /// Auto-degradation: consecutive ceiling hits per meal.
    private var ceilingHitCounts: [String: Int] = [:]

    // MARK: - Persistence Keys (for #9: survive app restart)

    private static let cumulativeScalingKey = "V2CumulativeScaling"
    private static let insulinRecordsKey = "V2MealInsulinRecords"
    private static let demandFactorsKey = "V2MealDemandFactors"

    /// Restore persisted state on init.
    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cumulativeScalingKey),
           let restored = try? JSONDecoder().decode([String: Double].self, from: data)
        {
            cumulativeScaling = restored
        }
        if let data = UserDefaults.standard.data(forKey: Self.insulinRecordsKey),
           let restored = try? JSONDecoder().decode([String: [MealInsulinRecord]].self, from: data)
        {
            mealInsulinRecords = restored
        }
        if let data = UserDefaults.standard.data(forKey: Self.demandFactorsKey),
           let restored = try? JSONDecoder().decode([String: Double].self, from: data)
        {
            mealDemandFactors = restored
        }
        pruneExpiredInsulinRecords()
    }

    /// Persist cumulative scaling to UserDefaults so it survives app restarts (#9).
    private func persistCumulativeScaling() {
        if let data = try? JSONEncoder().encode(cumulativeScaling) {
            UserDefaults.standard.set(data, forKey: Self.cumulativeScalingKey)
        }
    }

    /// Persist insulin records to UserDefaults.
    private func persistInsulinRecords() {
        if let data = try? JSONEncoder().encode(mealInsulinRecords) {
            UserDefaults.standard.set(data, forKey: Self.insulinRecordsKey)
        }
    }

    /// Persist demand factors to UserDefaults.
    private func persistDemandFactors() {
        if let data = try? JSONEncoder().encode(mealDemandFactors) {
            UserDefaults.standard.set(data, forKey: Self.demandFactorsKey)
        }
    }

    /// Remove insulin records older than maxAge (DIA + 1 hour buffer) to prevent unbounded growth.
    private func pruneExpiredInsulinRecords(maxAge: TimeInterval = 7 * 3600) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        for (mealID, records) in mealInsulinRecords {
            let filtered = records.filter { $0.timestamp > cutoff }
            if filtered.isEmpty {
                mealInsulinRecords.removeValue(forKey: mealID)
            } else {
                mealInsulinRecords[mealID] = filtered
            }
        }
    }

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
    ///   - mealStartBGs: Map of mealID -> BG at meal start (from V2MealOutcome.bgAtMeal)
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
        mealStartBGs: [String: Double] = [:],
        context: NSManagedObjectContext,
        userMaxSMBMinutes: Decimal,
        mealSMBMultiplier: Double = 2.0,
        bgFloor: Double = 90.0,
        diaHours: Double = 6.0,                    // S1: duration of insulin action in hours
        iobCurve: IOBDecayCurve = .exponential(peakMinutes: 75), // S1: oref-matching IOB curve
        lastLoopDate: Date? = nil               // L1: for dynamic absorption buffer
    ) async -> MealModeState {
        // L1: Dynamic absorption buffer — at least 5min, but longer if the loop is delayed
        let timeSinceLastLoop = lastLoopDate.map { Date().timeIntervalSince($0) } ?? Self.minAbsorptionBuffer
        let absorptionBuffer = max(Self.minAbsorptionBuffer, timeSinceLastLoop)
        let hasActiveMeals = !activeMealIDs.isEmpty

        let cgmAge: TimeInterval? = cgmTimestamp.map { Date().timeIntervalSince($0) }

        // Compute total remaining carbs across all active meals for Gate 5 (#5)
        var totalRemainingCarbs = 0.0
        for mealID in activeMealIDs {
            let info = await fetchAbsorbedAndRemainingCarbs(mealID: mealID, context: context, absorptionBuffer: absorptionBuffer)
            totalRemainingCarbs += info.remaining
        }

        // Compute maximum composite demand across active meals for rate limiting
        var maxComposite = 1.0
        stateLock.lock()
        for mealID in activeMealIDs {
            let demand = mealDemandFactors[mealID] ?? 1.0
            let cumulative = cumulativeScaling[mealID] ?? 1.0
            maxComposite = max(maxComposite, demand * cumulative)
        }
        stateLock.unlock()

        // Always evaluate meal-mode state (independent of adaptive adjustments)
        let mealMode = MealModeState.evaluate(
            hasActiveMealEntries: hasActiveMeals,
            currentBG: currentBG,
            bgTrend: bgTrend,
            cgmAgeSeconds: cgmAge,
            currentIOB: currentIOB,
            remainingCarbsForActiveMeals: totalRemainingCarbs,
            carbRatio: cr,
            userMaxSMBMinutes: userMaxSMBMinutes,
            mealSMBMultiplier: mealSMBMultiplier,
            bgFloor: bgFloor,
            compositeDemandFactor: maxComposite
        )

        // Adaptive entry adjustment (only if we have data and active meals)
        guard let bg = currentBG,
              let age = cgmAge,
              age < Self.maxCGMAge,
              hasActiveMeals
        else {
            return mealMode
        }

        // Check damping interval
        stateLock.lock()
        let lastTime = lastAdjustmentTime
        stateLock.unlock()
        if let lastTime, Date().timeIntervalSince(lastTime) < Self.dampingInterval {
            return mealMode
        }

        // Safety guards
        guard bg >= Self.lowBGGuard else { return mealMode } // don't increase entries when low
        guard bg <= Self.highBGGuard else { return mealMode } // don't chase extreme highs

        // BG-Adaptive Real-Time Correction
        //
        // For each active meal, estimate the predicted BG impact from its curve entries
        // and compare with actual CGM. If reality diverges, scale remaining entries.
        //
        // Change #1: Use meal-attributed IOB instead of total system IOB to avoid
        // double-correcting when a prior correction bolus inflates total IOB.
        //
        // Change #2: Use cumulative BG delta (currentBG - mealStartBG) instead of
        // trend extrapolation, which produces wildly inaccurate results.

        for mealID in activeMealIDs {
            // Compute absorbed carbs: sum of past entries for this meal
            let absorbedAndRemaining = await fetchAbsorbedAndRemainingCarbs(
                mealID: mealID,
                context: context,
                absorptionBuffer: absorptionBuffer
            )

            let absorbedCarbs = absorbedAndRemaining.absorbed
            let remainingCarbs = absorbedAndRemaining.remaining

            // Skip if no entries have been absorbed yet
            guard absorbedCarbs > 0, remainingCarbs > 0 else { continue }

            // (#1) Use meal-attributed IOB with oref-matching decay curve (S1)
            let mealIOB = getMealAttributedIOB(mealID: mealID, diaHours: diaHours, curve: iobCurve)

            // Predicted BG impact: absorbed carbs raise BG, meal-attributed IOB lowers it
            let predictedBGImpact = (absorbedCarbs / cr) * isf - mealIOB * isf

            // (#2) Use cumulative BG delta instead of trend extrapolation
            // This reflects what actually happened, not a linear projection of the current rate
            let mealStartBG = mealStartBGs[mealID] ?? bg
            let actualBGDelta = bg - mealStartBG
            let error = actualBGDelta - predictedBGImpact

            // Only adjust if error exceeds threshold
            guard abs(error) > Self.errorThreshold else { continue }

            // Compute scaling factor: 1.0 + (error / scalingConstant)
            let rawScaling = 1.0 + (error / Self.scalingConstant)

            // Blend: apply 50% of correction immediately (prevents overreaction)
            let blendedScaling = 1.0 + (rawScaling - 1.0) * 0.5

            // Scale future entries (S2: with hardcoded composite ceiling)
            await scaleFutureEntries(
                mealID: mealID,
                scalingFactor: blendedScaling,
                context: context
            )

            // Record adjustment for audit trail
            stateLock.lock()
            let recordedCumulative = cumulativeScaling[mealID] ?? 1.0
            let adjustment = AdaptiveAdjustment(
                timestamp: Date(),
                actualBG: bg,
                predictedBG: mealStartBG + predictedBGImpact,
                error: error,
                trendError: 0,
                scalingFactor: blendedScaling,
                cumulativeScaling: recordedCumulative,
                mealID: mealID
            )
            adjustmentHistory.append(adjustment)
            stateLock.unlock()
        }

        return mealMode
    }

    // MARK: - Meal-Attributed IOB Tracking (S1: decay-aware)

    /// Record insulin attributed to a specific meal with a timestamp for decay modeling.
    /// Thread-safe: may be called from bolus delivery path concurrent with loop timer.
    func recordMealInsulin(mealID: String, units: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var records = mealInsulinRecords[mealID] ?? []
        records.append(MealInsulinRecord(units: units, timestamp: Date()))
        mealInsulinRecords[mealID] = records
        persistInsulinRecords()
    }

    /// (S1) Get the decay-adjusted meal-attributed IOB for a specific meal.
    /// Uses the same insulin curve model as oref (bilinear or exponential) so that
    /// meal-attributed IOB tracks system IOB accurately.
    /// Thread-safe.
    func getMealAttributedIOB(mealID: String, diaHours: Double = 6.0, curve: IOBDecayCurve = .exponential(peakMinutes: 75)) -> Double {
        stateLock.lock()
        let records = mealInsulinRecords[mealID]
        stateLock.unlock()
        guard let records else { return 0 }
        let now = Date()
        return records.reduce(0.0) { total, record in
            let minsAgo = now.timeIntervalSince(record.timestamp) / 60.0
            let fraction = curve.fractionRemaining(minsAgo: minsAgo, diaHours: diaHours)
            return total + record.units * fraction
        }
    }

    /// Get the total (non-decayed) insulin ever attributed to a meal. Useful for outcome reporting.
    /// Thread-safe.
    func getTotalMealInsulin(mealID: String) -> Double {
        stateLock.lock()
        let records = mealInsulinRecords[mealID]
        stateLock.unlock()
        guard let records else { return 0 }
        return records.reduce(0.0) { $0 + $1.units }
    }

    // MARK: - Demand Factor Tracking (S2)

    /// Record the Garmin/engine demand factor for a meal at creation time.
    /// Thread-safe.
    func recordMealDemandFactor(mealID: String, factor: Double) {
        stateLock.lock()
        mealDemandFactors[mealID] = factor
        persistDemandFactors()
        stateLock.unlock()
    }

    /// Get the recorded demand factor for a meal (defaults to 1.0 if unknown).
    /// Thread-safe.
    func getMealDemandFactor(mealID: String) -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mealDemandFactors[mealID] ?? 1.0
    }

    // MARK: - Entry Analysis

    /// Fetch absorbed (past) and remaining (future) carbs for a meal.
    /// (L1) Uses a dynamic absorption buffer: max(5min, timeSinceLastLoop).
    /// Entries are only counted as "absorbed" after oref has had at least one cycle to act on them.
    func fetchAbsorbedAndRemainingCarbs(
        mealID: String,
        context: NSManagedObjectContext,
        absorptionBuffer: TimeInterval? = nil
    ) async -> (absorbed: Double, remaining: Double, minutesSinceFirst: Double) {
        let buffer = absorptionBuffer ?? Self.minAbsorptionBuffer
        return await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "fpuID == %@", UUID(uuidString: mealID)! as CVarArg),
                NSPredicate(format: "isFPU == YES")
            ])
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            do {
                let entries = try context.fetch(fetchRequest)
                let now = Date()
                // (L1) Only count entries as absorbed after oref has had at least one cycle
                let effectiveNow = now.addingTimeInterval(-buffer)
                var absorbed = 0.0
                var remaining = 0.0
                var earliestDate: Date?

                for entry in entries {
                    guard let entryDate = entry.date else { continue }
                    if earliestDate == nil { earliestDate = entryDate }

                    if entryDate <= effectiveNow {
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
    /// (S2) Enforces hardcoded composite ceiling: demand factor × cumulative scaling ≤ 2.5x.
    /// The ceiling is intentionally not configurable — it's a safety boundary, not a preference.
    /// Auto-degrades if the ceiling is hit repeatedly (reduces aggressiveness automatically).
    /// Thread-safe.
    func scaleFutureEntries(
        mealID: String,
        scalingFactor: Double,
        context: NSManagedObjectContext
    ) async {
        // Clamp single-cycle scaling
        let clampedFactor = min(Self.maxCycleScaling, max(Self.minCycleScaling, scalingFactor))

        stateLock.lock()

        // Track cumulative scaling
        let currentCumulative = cumulativeScaling[mealID] ?? 1.0
        var newCumulative = currentCumulative * clampedFactor
        newCumulative = min(Self.maxCumulativeScaling, max(Self.minCumulativeScaling, newCumulative))

        // (S2) Composite ceiling: demand factor × cumulative scaling must stay within bounds.
        let demandFactor = mealDemandFactors[mealID] ?? 1.0
        let compositeDemand = newCumulative * demandFactor
        var ceilingWasHit = false
        if compositeDemand > Self.defaultMaxCompositeDemand, demandFactor > 0 {
            let cappedCumulative = Self.defaultMaxCompositeDemand / demandFactor
            ceilingWasHit = true

            // Auto-degradation: track consecutive ceiling hits
            let hitCount = (ceilingHitCounts[mealID] ?? 0) + 1
            ceilingHitCounts[mealID] = hitCount

            if hitCount >= Self.ceilingHitDegradationThreshold {
                // Engine is consistently hitting the ceiling — decay scaling toward 1.0
                // to reduce aggressiveness automatically (no user intervention needed)
                let degradedCumulative = cappedCumulative * Self.degradationDecayFactor
                newCumulative = max(Self.minCumulativeScaling, degradedCumulative)
                ceilingHitCounts[mealID] = 0 // reset counter after degradation

                stateLock.unlock()
                debug(
                    .apsManager,
                    "S2 AUTO-DEGRADE for meal \(mealID.prefix(8)): " +
                    "\(hitCount) consecutive ceiling hits → " +
                    "decaying scaling from \(String(format: "%.2f", cappedCumulative))x " +
                    "to \(String(format: "%.2f", newCumulative))x"
                )
                stateLock.lock()
            } else {
                newCumulative = cappedCumulative

                stateLock.unlock()
                debug(
                    .apsManager,
                    "S2 composite ceiling hit for meal \(mealID.prefix(8)): " +
                    "demand=\(String(format: "%.2f", demandFactor))x × " +
                    "scaling=\(String(format: "%.2f", currentCumulative * clampedFactor))x = " +
                    "\(String(format: "%.2f", compositeDemand))x > " +
                    "\(String(format: "%.1f", Self.defaultMaxCompositeDemand))x ceiling. " +
                    "Capping scaling to \(String(format: "%.2f", newCumulative))x " +
                    "(hit \(hitCount)/\(Self.ceilingHitDegradationThreshold))"
                )
                stateLock.lock()
            }
        } else {
            // No ceiling hit — reset consecutive counter
            ceilingHitCounts[mealID] = 0
        }

        let finalCumulative = min(Self.maxCumulativeScaling, max(Self.minCumulativeScaling, newCumulative))
        let effectiveFactor = finalCumulative / currentCumulative

        guard abs(effectiveFactor - 1.0) > 0.01 else {
            stateLock.unlock()
            return // skip trivial adjustments
        }

        cumulativeScaling[mealID] = finalCumulative
        lastAdjustmentTime = Date()
        persistCumulativeScaling() // (#9) survive app restart
        stateLock.unlock()

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
    /// Thread-safe.
    func mealCompleted(mealID: String) {
        stateLock.lock()
        cumulativeScaling.removeValue(forKey: mealID)
        mealInsulinRecords.removeValue(forKey: mealID)
        mealDemandFactors.removeValue(forKey: mealID)
        ceilingHitCounts.removeValue(forKey: mealID)
        persistCumulativeScaling()
        persistInsulinRecords()
        persistDemandFactors()
        stateLock.unlock()
    }
}
