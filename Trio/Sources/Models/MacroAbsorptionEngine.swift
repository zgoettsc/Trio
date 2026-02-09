import Foundation

// MARK: - Phase A: Three-Curve Macro Absorption Engine
//
// Replaces the linear FPU distribution (Warsaw Method) with physiologically
// accurate gamma/sigmoid/gaussian curves for carb, protein, and fat effects.
// Implements curve-driven split dosing to prevent mixed-meal hypoglycemia.

// MARK: - Result Type

/// The result of generating macro absorption entries for a meal.
/// `upfrontCarbs` is the bolus recommendation (NOT stored as entries).
/// `futureEntries` are curve-shaped entries stored to Core Data for oref.
struct MacroAbsorptionResult {
    let mealID: String
    let upfrontCarbs: Double            // grams, demand-adjusted — for bolus recommendation only
    let upfrontPercent: Double          // 0-1, fraction of carbs in upfront bolus
    let curveSuggestedPercent: Double   // 0-1, what the gamma CDF calculated
    let futureEntries: [CarbsEntry]     // entries AFTER safe window — stored for oref
    let insulinDemandFactor: Double     // from Garmin model (1.0 = normal)
    let originalCarbs: Double           // grams eaten
    let originalFat: Double             // grams eaten
    let originalProtein: Double         // grams eaten
    let originalFiber: Double           // grams eaten (#15)
    let tauCarb: Double                 // fat-and-fiber-modified time constant (minutes)
    let proteinFactor: Double           // 0-0.35, from smooth ramp
    let fatTotalEquiv: Double           // total fat carb-equivalent (grams)
    let safeWindowMinutes: Int          // window used for split

    /// Total effective carbs oref will see (upfront via bolus + future entries)
    var totalEffectiveCarbs: Double {
        upfrontCarbs + futureEntries.reduce(0.0) { $0 + Double(truncating: $1.carbs as NSDecimalNumber) }
    }
}

// MARK: - Insulin Type

/// Insulin type affects the default safe window for split dosing.
/// Faster insulins need shorter windows to avoid outpacing carb absorption.
/// V2 insulin type classification for safe window calculation.
/// Named V2InsulinType to avoid collision with LoopKit.InsulinType.
enum V2InsulinType: String, Codable {
    case ultraRapid    // Fiasp, Lyumjev — peaks at 30-45 min
    case rapidActing   // Humalog, Novolog — peaks at 60-90 min

    var defaultSafeWindowMinutes: Int {
        switch self {
        case .ultraRapid: return 30
        case .rapidActing: return 45
        }
    }
}

// MARK: - Engine

struct MacroAbsorptionEngine {

    // MARK: - Main Entry Point

    /// Generate future carb entries for a mixed meal using the three-curve model.
    ///
    /// CRITICAL SAFETY INVARIANT: Carb entries are ONLY generated for the portion
    /// AFTER the safe window. The upfront portion is returned as `upfrontCarbs`
    /// for the bolus recommendation — NO entries are created for it. This prevents
    /// double-counting: the bolus covers upfront carbs, oref sees only future entries.
    ///
    /// - Parameters:
    ///   - carbs: Total carbohydrate grams from the meal
    ///   - fat: Total fat grams from the meal
    ///   - protein: Total protein grams from the meal
    ///   - fiber: Total dietary fiber grams from the meal (#15)
    ///   - mealTime: When the meal was detected/eaten
    ///   - insulinDemandFactor: From Garmin model. 1.0 = normal, 1.25 = 25% more insulin needed
    ///   - upfrontPercent: User override for upfront %. nil = use curve-calculated default with fat-scaled floor
    ///   - insulinType: User's insulin type (affects safe window default)
    ///   - curveParameters: Personal curve parameters (learned or manually tuned). nil = use defaults
    ///   - safeWindowOverride: User override for safe window minutes. nil = use insulin type default
    ///   - minUpfrontFloor: Absolute minimum upfront % for the fattiest meals (0-1). nil = 0.25.
    ///     Low-fat meals get up to 70% upfront; the floor sets the minimum for high-fat (≥50g) meals.
    ///     Prevents simple carb meals from being under-bolused by the CDF calculation alone.
    static func generateEntries(
        carbs: Double,
        fat: Double,
        protein: Double,
        fiber: Double = 0,
        mealTime: Date,
        insulinDemandFactor: Double = 1.0,
        upfrontPercent: Double? = nil,
        insulinType: V2InsulinType = .rapidActing,
        curveParameters: V2PersonalCurveParameters? = nil,
        safeWindowOverride: Int? = nil,
        minUpfrontFloor: Double? = nil
    ) -> MacroAbsorptionResult {

        let params = curveParameters ?? V2PersonalCurveParameters()

        let mealID = UUID().uuidString

        // Determine safe window based on insulin type (or user override)
        let safeWindowMinutes = safeWindowOverride ?? insulinType.defaultSafeWindowMinutes

        // --- Curve 1: Carbohydrate absorption (gamma-shaped) ---
        let tauCarb = carbTau(baseTau: params.effectiveCarbTau, fatGrams: fat, fiberGrams: fiber, fiberCoefficient: params.effectiveFiberCoefficient)
        let curveSuggestedPercent = gammaCDFValue(tau: tauCarb, atMinutes: Double(safeWindowMinutes))

        // Fat-scaled minimum upfront: prevents simple carb meals from being under-bolused.
        // Low-fat meals get ~80% upfront (close to standard AID); high-fat meals get the floor.
        // User override bypasses this — if someone explicitly sets upfront %, use it exactly.
        let fatMinUpfront = fatScaledMinUpfront(fatGrams: fat, floor: minUpfrontFloor ?? 0.25)
        let effectivePercent = upfrontPercent ?? max(curveSuggestedPercent, fatMinUpfront)

        // Only generate entries for carbs AFTER the safe window.
        // The upfront portion is covered by the bolus — no entries for it.
        let remainingCarbGrams = carbs * (1.0 - effectivePercent)
        let carbDuration = carbAbsorptionDuration(tau: tauCarb)

        var futureEntries: [CarbsEntry] = []

        if remainingCarbGrams > 0.5 { // don't create entries for trivial amounts
            let carbEntries = generateGammaCurveEntries(
                totalAmount: remainingCarbGrams,
                tau: tauCarb,
                mealTime: mealTime,
                startAfterMinutes: safeWindowMinutes,
                endMinutes: Int(carbDuration),
                intervalMinutes: 10,
                mealID: mealID,
                note: "carb-absorption"
            )
            futureEntries.append(contentsOf: carbEntries)
        }

        // --- Curve 2: Protein gluconeogenesis (delayed sigmoid, smooth ramp) ---
        // Uses personal curve parameters for threshold, plateau, and max factor.
        // individualAdjustmentFactor is NOT applied here — V2 has its own tunable coefficients.
        let proteinFactor = proteinGlucoFactor(
            proteinGrams: protein,
            threshold: params.effectiveProteinThreshold,
            plateau: params.effectiveProteinPlateau,
            maxFactor: params.effectiveProteinFactor
        )
        if proteinFactor > 0 {
            let glucoseEquiv = protein * proteinFactor
            if glucoseEquiv > 0.5 {
                let proteinEntries = generateProteinCurveEntries(
                    totalGlucose: glucoseEquiv,
                    mealTime: mealTime,
                    intervalMinutes: 15,
                    mealID: mealID
                )
                futureEntries.append(contentsOf: proteinEntries)
            }
        }

        // --- Curve 3: Fat insulin resistance (normalized gaussian) ---
        // Below 5g fat, effect is negligible — skip entirely.
        // (#6) Uses nonlinear saturating ramp instead of linear coefficient.
        // At moderate fat levels, tau modification already handles timing shift;
        // Curve 3 entries only add substantial demand at high fat levels where
        // insulin resistance becomes the primary concern (Bell 2020).
        let fatTotalEquiv: Double
        if fat >= 5 {
            fatTotalEquiv = fatCarbEquivalent(
                fatGrams: fat,
                maxCoeff: params.effectiveFatTotalCoeff
            )
            if fatTotalEquiv > 0.5 {
                let fatEntries = generateNormalizedFatResistanceEntries(
                    totalEquiv: fatTotalEquiv,
                    mealTime: mealTime,
                    intervalMinutes: 15,
                    mealID: mealID
                )
                futureEntries.append(contentsOf: fatEntries)
            }
        } else {
            fatTotalEquiv = 0
        }

        // --- Apply insulin demand factor to ALL future entries ---
        // insulinDemandFactor > 1.0 means more resistant (e.g., 1.25 = bad sleep)
        // Multiply entries to increase insulin demand. Self-documenting.
        let adjustedEntries: [CarbsEntry]
        if abs(insulinDemandFactor - 1.0) > 0.01 {
            adjustedEntries = futureEntries.map { entry in
                CarbsEntry(
                    id: entry.id,
                    createdAt: entry.createdAt,
                    actualDate: entry.actualDate,
                    carbs: Decimal(Double(truncating: entry.carbs as NSDecimalNumber) * insulinDemandFactor),
                    fat: entry.fat,
                    protein: entry.protein,
                    note: entry.note,
                    enteredBy: entry.enteredBy,
                    isFPU: entry.isFPU,
                    fpuID: entry.fpuID
                )
            }
        } else {
            adjustedEntries = futureEntries
        }

        // Upfront carbs for bolus recommendation (NOT stored as entries)
        let upfrontCarbs = carbs * effectivePercent * insulinDemandFactor

        return MacroAbsorptionResult(
            mealID: mealID,
            upfrontCarbs: upfrontCarbs,
            upfrontPercent: effectivePercent,
            curveSuggestedPercent: curveSuggestedPercent,
            futureEntries: adjustedEntries,
            insulinDemandFactor: insulinDemandFactor,
            originalCarbs: carbs,
            originalFat: fat,
            originalProtein: protein,
            originalFiber: fiber,
            tauCarb: tauCarb,
            proteinFactor: proteinFactor,
            fatTotalEquiv: fatTotalEquiv,
            safeWindowMinutes: safeWindowMinutes
        )
    }

    // MARK: - Nonlinear Fat Coefficient (#6)

    /// Nonlinear fat carb-equivalent calculation using a saturating ramp.
    /// At moderate fat levels (< threshold), the effect is minimal because the tau
    /// modification already handles timing shift. At high fat levels (> plateau),
    /// the full coefficient applies for insulin resistance demand.
    ///
    /// Based on Bell (2020): fat dose-response is nonlinear — 20g fat needs +6%,
    /// 40g needs +6%, but 60g needs +21%. A single linear coefficient overcharges
    /// moderate-fat meals.
    static func fatCarbEquivalent(
        fatGrams: Double,
        maxCoeff: Double = 0.69,
        threshold: Double = 10,
        plateau: Double = 50
    ) -> Double {
        guard fatGrams >= 5 else { return 0 }
        if fatGrams <= threshold { return fatGrams * 0.05 } // minimal effect — tau handles timing
        if fatGrams >= plateau { return fatGrams * maxCoeff }
        let rampFraction = (fatGrams - threshold) / (plateau - threshold)
        let effectiveCoeff = 0.05 + rampFraction * (maxCoeff - 0.05)
        return fatGrams * effectiveCoeff
    }

    // MARK: - Fat-Scaled Minimum Upfront Percentage

    /// Compute a fat-scaled minimum upfront bolus percentage.
    ///
    /// The Gamma CDF alone under-boluses simple carb meals (e.g., rice bowl gets only
    /// 34% upfront). This function provides a floor that scales with fat content:
    /// - 0g fat → 80% upfront (close to standard AID full-bolus behavior)
    /// - 50g+ fat → `floor` (default 25%, aggressive splitting for HFHP meals)
    ///
    /// The formula is a linear interpolation: `lerp(0.80, floor, clamp(fatGrams/50, 0, 1))`
    ///
    /// The effective upfront percent is `max(CDF, fatScaledMinUpfront)`, so the CDF
    /// still matters for very high-fat meals where it may exceed the floor.
    static func fatScaledMinUpfront(
        fatGrams: Double,
        floor: Double = 0.25,
        lowFatUpfront: Double = 0.80,
        fatCap: Double = 50.0
    ) -> Double {
        let t = min(max(fatGrams / fatCap, 0), 1)
        return lowFatUpfront + (floor - lowFatUpfront) * t
    }

    // MARK: - Curve 1: Gamma(2, tau) for Carbohydrates

    /// Fat- and fiber-modified time constant for the carb absorption gamma curve.
    /// More fat = slower gastric emptying = larger tau = later peak.
    /// (#15) Fiber independently slows gastric emptying and glucose absorption
    /// (Torsdottir 1991, Jenkins 1978). The 0.3 min/g coefficient is conservative;
    /// fiber's effect is real but smaller than fat's. The 5g threshold avoids
    /// adjusting for trace amounts.
    static func carbTau(baseTau: Double, fatGrams: Double, fiberGrams: Double = 0, fiberCoefficient: Double = 0.3) -> Double {
        let fatSlowingCoefficient = 0.8   // minutes per gram of fat
        let fiberThreshold = 5.0          // below this, fiber effect is negligible

        let fatDelay = fatGrams * fatSlowingCoefficient
        let fiberDelay = max(0, fiberGrams - fiberThreshold) * fiberCoefficient

        return baseTau + fatDelay + fiberDelay
    }

    /// Gamma(2, tau) CDF: fraction of carbs absorbed by time t.
    /// CDF(t) = 1 - (1 + t/tau) * exp(-t/tau)
    static func gammaCDFValue(tau: Double, atMinutes t: Double) -> Double {
        guard tau > 0, t > 0 else { return 0 }
        return 1.0 - (1.0 + t / tau) * exp(-t / tau)
    }

    /// Gamma(2, tau) PDF value at time t (unnormalized — for relative weighting).
    /// PDF(t) = (t / tau^2) * exp(-t / tau)
    static func gammaPDFValue(tau: Double, atMinutes t: Double) -> Double {
        guard tau > 0, t > 0 else { return 0 }
        return (t / (tau * tau)) * exp(-t / tau)
    }

    /// Duration to 95% absorption for gamma(2, tau).
    static func carbAbsorptionDuration(tau: Double) -> Double {
        tau * 4.74
    }

    /// Generate carb entries along the gamma curve, starting after the safe window.
    /// The entries represent the REMAINING carbs (not covered by the upfront bolus).
    /// Entry amounts are proportional to the gamma PDF, normalized so they sum to totalAmount.
    static func generateGammaCurveEntries(
        totalAmount: Double,
        tau: Double,
        mealTime: Date,
        startAfterMinutes: Int,
        endMinutes: Int,
        intervalMinutes: Int,
        mealID: String,
        note: String
    ) -> [CarbsEntry] {
        guard totalAmount > 0, tau > 0, intervalMinutes > 0 else { return [] }

        // Sample the gamma PDF at each time point
        var timePoints: [(minutes: Int, weight: Double)] = []
        var totalWeight: Double = 0

        var t = startAfterMinutes
        while t <= endMinutes {
            let w = gammaPDFValue(tau: tau, atMinutes: Double(t))
            if w > 1e-6 {
                timePoints.append((minutes: t, weight: w))
                totalWeight += w
            }
            t += intervalMinutes
        }

        guard totalWeight > 0, !timePoints.isEmpty else { return [] }

        // Normalize weights so entries sum to exactly totalAmount
        return timePoints.compactMap { point in
            let carbAmount = totalAmount * (point.weight / totalWeight)
            guard carbAmount >= 0.1 else { return nil } // skip negligible entries

            return CarbsEntry(
                id: UUID().uuidString,
                createdAt: mealTime,
                actualDate: mealTime.addingTimeInterval(Double(point.minutes) * 60),
                carbs: Decimal(round(carbAmount * 10) / 10), // round to 0.1g
                fat: 0,
                protein: 0,
                note: note,
                enteredBy: CarbsEntry.local,
                isFPU: true,
                fpuID: mealID
            )
        }
    }

    // MARK: - Curve 2: Protein Gluconeogenesis (Delayed Sigmoid)

    /// Smooth protein ramp factor: 0 at <=threshold, linear to maxFactor at plateau, plateau above.
    /// Replaces the hard 28g cutoff — no physiological cliff at any threshold.
    /// Parameters are tunable via V2 settings sliders or outcome learning.
    static func proteinGlucoFactor(
        proteinGrams: Double,
        threshold: Double = 15,
        plateau: Double = 40,
        maxFactor: Double = 0.35
    ) -> Double {
        if proteinGrams <= threshold { return 0.0 }
        if proteinGrams >= plateau { return maxFactor }
        return (proteinGrams - threshold) / (plateau - threshold) * maxFactor
    }

    /// Protein sigmoid value at time t.
    /// sigmoid(t) = 1 / (1 + exp(-(t - onset) / steepness))
    /// Combined with decay after peak.
    static func proteinCurveValue(atMinutes t: Double) -> Double {
        let onset: Double = 180   // center of sigmoid = 3h
        let steepness: Double = 40
        let peak: Double = 300    // 5h
        let decaySigma: Double = 120

        let sigmoid = 1.0 / (1.0 + exp(-(t - onset) / steepness))
        let decay: Double = t > peak ? exp(-pow(t - peak, 2) / (2 * decaySigma * decaySigma)) : 1.0

        return sigmoid * decay
    }

    /// Generate protein gluconeogenesis entries along the delayed sigmoid curve.
    static func generateProteinCurveEntries(
        totalGlucose: Double,
        mealTime: Date,
        intervalMinutes: Int,
        mealID: String
    ) -> [CarbsEntry] {
        guard totalGlucose > 0, intervalMinutes > 0 else { return [] }

        let startMinutes = 90
        let endMinutes = 480 // 8 hours

        var timePoints: [(minutes: Int, weight: Double)] = []
        var totalWeight: Double = 0

        var t = startMinutes
        while t <= endMinutes {
            let w = proteinCurveValue(atMinutes: Double(t))
            if w > 1e-6 {
                timePoints.append((minutes: t, weight: w))
                totalWeight += w
            }
            t += intervalMinutes
        }

        guard totalWeight > 0, !timePoints.isEmpty else { return [] }

        return timePoints.compactMap { point in
            let carbAmount = totalGlucose * (point.weight / totalWeight)
            guard carbAmount >= 0.1 else { return nil }

            return CarbsEntry(
                id: UUID().uuidString,
                createdAt: mealTime,
                actualDate: mealTime.addingTimeInterval(Double(point.minutes) * 60),
                carbs: Decimal(round(carbAmount * 10) / 10),
                fat: 0,
                protein: 0,
                note: "protein-gluconeogenesis",
                enteredBy: CarbsEntry.local,
                isFPU: true,
                fpuID: mealID
            )
        }
    }

    // MARK: - Curve 3: Fat Insulin Resistance (Normalized Gaussian)

    /// Gaussian value at time t, centered at tPeak with standard deviation sigma.
    static func gaussianValue(atMinutes t: Double, tPeak: Double = 360, sigma: Double = 90) -> Double {
        guard t >= 120 else { return 0 } // no resistance before 2h (FFA elevation)
        return exp(-pow(t - tPeak, 2) / (2 * sigma * sigma))
    }

    /// Generate fat resistance entries using a normalized Gaussian.
    /// The entries always sum to exactly `totalEquiv` regardless of spacing.
    /// Coefficient is parameterized via V2PersonalCurveParameters (default 0.69 from Wolpert).
    static func generateNormalizedFatResistanceEntries(
        totalEquiv: Double,
        mealTime: Date,
        intervalMinutes: Int,
        mealID: String
    ) -> [CarbsEntry] {
        guard totalEquiv > 0, intervalMinutes > 0 else { return [] }

        let startMinutes = 120  // 2h — no resistance before FFA elevation
        let endMinutes = 540    // 9h

        var timePoints: [(minutes: Int, weight: Double)] = []
        var totalWeight: Double = 0

        var t = startMinutes
        while t <= endMinutes {
            let w = gaussianValue(atMinutes: Double(t))
            if w > 1e-6 {
                timePoints.append((minutes: t, weight: w))
                totalWeight += w
            }
            t += intervalMinutes
        }

        guard totalWeight > 0, !timePoints.isEmpty else { return [] }

        // Normalize so entries sum to exactly totalEquiv
        return timePoints.compactMap { point in
            let carbAmount = totalEquiv * (point.weight / totalWeight)
            guard carbAmount >= 0.1 else { return nil }

            return CarbsEntry(
                id: UUID().uuidString,
                createdAt: mealTime,
                actualDate: mealTime.addingTimeInterval(Double(point.minutes) * 60),
                carbs: Decimal(round(carbAmount * 10) / 10),
                fat: 0,
                protein: 0,
                note: "fat-resistance",
                enteredBy: CarbsEntry.local,
                isFPU: true,
                fpuID: mealID
            )
        }
    }
}
