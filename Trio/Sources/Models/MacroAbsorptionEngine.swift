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
    let tauCarb: Double                 // fat-modified time constant (minutes)
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
enum InsulinType: String, Codable {
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
    ///   - mealTime: When the meal was detected/eaten
    ///   - insulinDemandFactor: From Garmin model. 1.0 = normal, 1.25 = 25% more insulin needed
    ///   - upfrontPercent: User override for upfront %. nil = use curve-calculated default
    ///   - insulinType: User's insulin type (affects safe window default)
    ///   - individualAdjustmentFactor: User's personal adjustment (default 0.5 from settings)
    ///   - safeWindowOverride: User override for safe window minutes. nil = use insulin type default
    static func generateEntries(
        carbs: Double,
        fat: Double,
        protein: Double,
        mealTime: Date,
        insulinDemandFactor: Double = 1.0,
        upfrontPercent: Double? = nil,
        insulinType: InsulinType = .rapidActing,
        individualAdjustmentFactor: Double = 0.5,
        safeWindowOverride: Int? = nil
    ) -> MacroAbsorptionResult {

        let mealID = UUID().uuidString

        // Determine safe window based on insulin type (or user override)
        let safeWindowMinutes = safeWindowOverride ?? insulinType.defaultSafeWindowMinutes

        // --- Curve 1: Carbohydrate absorption (gamma-shaped) ---
        let tauCarb = carbTau(baseTau: 35, fatGrams: fat)
        let curveSuggestedPercent = gammaCDFValue(tau: tauCarb, atMinutes: Double(safeWindowMinutes))
        let effectivePercent = upfrontPercent ?? curveSuggestedPercent

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
        let proteinFactor = proteinGlucoFactor(proteinGrams: protein)
        if proteinFactor > 0 {
            let glucoseEquiv = protein * proteinFactor * individualAdjustmentFactor
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
        let fatTotalEquiv: Double
        if fat >= 5 {
            fatTotalEquiv = fat * 0.69 * individualAdjustmentFactor
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
            tauCarb: tauCarb,
            proteinFactor: proteinFactor,
            fatTotalEquiv: fatTotalEquiv,
            safeWindowMinutes: safeWindowMinutes
        )
    }

    // MARK: - Curve 1: Gamma(2, tau) for Carbohydrates

    /// Fat-modified time constant for the carb absorption gamma curve.
    /// More fat = slower gastric emptying = larger tau = later peak.
    static func carbTau(baseTau: Double, fatGrams: Double) -> Double {
        let fatSlowingCoefficient = 0.8 // minutes per gram of fat
        return baseTau + (fatGrams * fatSlowingCoefficient)
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

    /// Smooth protein ramp factor: 0 at <=15g, linear to 0.35 at 40g, plateau above.
    /// Replaces the hard 28g cutoff — no physiological cliff at any threshold.
    static func proteinGlucoFactor(proteinGrams: Double) -> Double {
        if proteinGrams <= 15 { return 0.0 }
        if proteinGrams >= 40 { return 0.35 }
        return (proteinGrams - 15.0) / (40.0 - 15.0) * 0.35
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
    /// Uses total coefficient of 0.69 g-carb-equiv per g-fat (from Wolpert).
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
