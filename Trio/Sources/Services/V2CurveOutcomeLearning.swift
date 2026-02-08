import CoreData
import Foundation

// MARK: - Phase F: V2 Curve Outcome Learning

/// Stores V2-specific curve parameters and Garmin context with each meal recommendation,
/// then learns personal curve parameters from BG outcomes.
///
/// This extends the existing CronometerRecommendationStore pattern:
/// - Early error (0-2h) → carb tau incorrect
/// - Mid error (2-4h) → protein onset/magnitude wrong
/// - Late error (4-8h) → fat resistance coefficient wrong

// MARK: - V2 Meal Outcome Record

/// A meal outcome record with V2 curve parameters and Garmin context.
struct V2MealOutcome: Codable, Identifiable {
    let id: UUID
    let date: Date
    let mealID: String

    // Original macros
    let carbs: Double
    let fat: Double
    let protein: Double
    let fiber: Double  // (#15) dietary fiber for outcome tracking

    // V2 curve parameters used
    let tauCarb: Double
    let proteinFactor: Double
    let fatTotalEquiv: Double
    let upfrontPercent: Double
    let curveSuggestedPercent: Double
    let insulinDemandFactor: Double
    let safeWindowMinutes: Int

    // Garmin context at meal time (nil if unavailable)
    let garminSnapshot: GarminContextSnapshot?

    // Dosing context
    let bgAtMeal: Int
    let carbRatioAtMeal: Double
    let isfAtMeal: Double

    // SMB enhancement
    let mealSMBMultiplier: Double
    let mealModeWasActive: Bool

    // BG-adaptive adjustments applied during absorption
    var adaptiveAdjustments: [AdaptiveAdjustmentRecord]

    // BG outcomes at checkpoints (filled via backfill)
    var checkpoints: [V2BGCheckpoint]

    // Whether a confounding meal was detected
    var hasConfoundingMeal: Bool

    struct AdaptiveAdjustmentRecord: Codable {
        let timestamp: Date
        let scalingFactor: Double
        let cumulativeScaling: Double
        let actualBG: Double
        let predictedBG: Double
    }
}

/// BG checkpoint for V2 outcome tracking with curve attribution.
struct V2BGCheckpoint: Codable {
    let hoursAfterMeal: Int
    var bgValue: Int?
    var isClean: Bool
    var curvePhase: CurvePhase

    /// Which absorption curve is dominant at this checkpoint time.
    enum CurvePhase: String, Codable {
        case carb       // 0-2h: carb absorption dominant
        case protein    // 2-5h: protein gluconeogenesis onset
        case fat        // 4-9h: fat insulin resistance
        case overlap    // multiple curves active
        case skip       // checkpoint not relevant for this meal's macros
    }

    /// Compute phase attribution dynamically based on actual meal macros (#3).
    /// Prevents attributing errors to curves that weren't active for this meal.
    static func computePhases(
        carbs: Double,
        fat: Double,
        protein: Double,
        proteinThreshold: Double
    ) -> [V2BGCheckpoint] {
        let hasProtein = protein > proteinThreshold
        let hasFat = fat >= 5

        return [
            V2BGCheckpoint(hoursAfterMeal: 1, bgValue: nil, isClean: true, curvePhase: .carb),
            V2BGCheckpoint(hoursAfterMeal: 2, bgValue: nil, isClean: true, curvePhase: .carb),
            V2BGCheckpoint(hoursAfterMeal: 3, bgValue: nil, isClean: true,
                           curvePhase: hasProtein ? .protein : .carb),
            V2BGCheckpoint(hoursAfterMeal: 4, bgValue: nil, isClean: true,
                           curvePhase: hasProtein && hasFat ? .overlap :
                                       hasProtein ? .protein :
                                       hasFat ? .fat : .carb),
            // (#11) 5h checkpoint captures protein peak (4-5h)
            V2BGCheckpoint(hoursAfterMeal: 5, bgValue: nil, isClean: true,
                           curvePhase: hasProtein ? .protein : hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 6, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 8, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
        ]
    }
}

// MARK: - Learnable Personal Parameters

/// Persistent personal curve parameters learned from outcomes.
struct V2PersonalCurveParameters: Codable {
    var carbTau: Double?            // base: 35, learned
    var proteinThreshold: Double?   // base: 15g, learned
    var proteinPlateau: Double?     // base: 40g, learned
    var proteinFactor: Double?      // base: 0.35, learned
    var fatTotalCoeff: Double?      // base: 0.69, learned

    // Garmin sensitivity rule weights (nil = use defaults)
    var sleepWeight: Double?
    var sleepDurationWeight: Double?
    var bodyBatteryWeight: Double?
    var stressWeight: Double?
    var restingHRWeight: Double?
    var hrvWeight: Double?
    var activityYesterdayWeight: Double?
    var activityTodayWeight: Double?

    /// Effective values with defaults
    var effectiveCarbTau: Double { carbTau ?? 35 }
    var effectiveProteinThreshold: Double { proteinThreshold ?? 15 }
    var effectiveProteinPlateau: Double { proteinPlateau ?? 40 }
    var effectiveProteinFactor: Double { proteinFactor ?? 0.35 }
    var effectiveFatTotalCoeff: Double { fatTotalCoeff ?? 0.69 }
}

// MARK: - Outcome Learning Store

/// Persistent store for V2 meal outcomes and personal parameter learning.
final class V2OutcomeLearningStore {
    static let shared = V2OutcomeLearningStore()

    private let outcomesKey = "V2MealOutcomes"
    private let parametersKey = "V2PersonalCurveParameters"
    private let retentionDays = 90
    private let icrMatchTolerance = 0.10

    private init() {}

    // MARK: - Outcome Storage

    func save(_ outcome: V2MealOutcome) {
        var all = loadAll()
        all.append(outcome)
        persistOutcomes(all)
    }

    func loadAll() -> [V2MealOutcome] {
        guard let data = UserDefaults.standard.data(forKey: outcomesKey) else { return [] }
        do {
            var outcomes = try JSONDecoder().decode([V2MealOutcome].self, from: data)
            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
            outcomes = outcomes.filter { $0.date >= cutoff }
            return outcomes.sorted { $0.date < $1.date }
        } catch {
            debugPrint("V2OutcomeLearningStore: Failed to decode outcomes: \(error)")
            return []
        }
    }

    func update(_ outcome: V2MealOutcome) {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == outcome.id }) {
            all[index] = outcome
            persistOutcomes(all)
        }
    }

    private func persistOutcomes(_ outcomes: [V2MealOutcome]) {
        do {
            let data = try JSONEncoder().encode(outcomes)
            UserDefaults.standard.set(data, forKey: outcomesKey)
        } catch {
            debugPrint("V2OutcomeLearningStore: Failed to encode outcomes: \(error)")
        }
    }

    // MARK: - Personal Parameters

    func loadParameters() -> V2PersonalCurveParameters {
        guard let data = UserDefaults.standard.data(forKey: parametersKey),
              let params = try? JSONDecoder().decode(V2PersonalCurveParameters.self, from: data)
        else {
            return V2PersonalCurveParameters()
        }
        return params
    }

    func saveParameters(_ params: V2PersonalCurveParameters) {
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: parametersKey)
        }
    }

    // MARK: - Confounding Meal Detection (#4)

    /// Detect confounding meals: if another meal was recorded within the 8h window
    /// of a given outcome, mark individual checkpoints as dirty where the overlap occurs.
    func detectConfoundingMeals() {
        var outcomes = loadAll()
        guard outcomes.count > 1 else { return }

        var anyUpdated = false

        for i in 0 ..< outcomes.count {
            let mealTime = outcomes[i].date
            let windowEnd = mealTime.addingTimeInterval(8 * 3600)

            // Find any overlapping meals
            let overlappingMeals = outcomes.filter { other in
                other.id != outcomes[i].id &&
                    other.date > mealTime &&
                    other.date < windowEnd
            }

            if overlappingMeals.isEmpty {
                if outcomes[i].hasConfoundingMeal {
                    outcomes[i].hasConfoundingMeal = false
                    anyUpdated = true
                }
                continue
            }

            // Per-checkpoint clean/dirty marking based on whether a confounding meal's
            // absorption window overlaps that specific checkpoint time
            outcomes[i].hasConfoundingMeal = true
            for j in 0 ..< outcomes[i].checkpoints.count {
                let cpTime = mealTime.addingTimeInterval(
                    TimeInterval(outcomes[i].checkpoints[j].hoursAfterMeal * 3600)
                )
                // A checkpoint is dirty if any confounding meal started before the checkpoint time
                // (its absorption is active at that point)
                let isDirty = overlappingMeals.contains { $0.date < cpTime }
                if isDirty {
                    outcomes[i].checkpoints[j].isClean = false
                    anyUpdated = true
                }
            }
        }

        if anyUpdated {
            persistOutcomes(outcomes)
        }
    }

    // MARK: - Outcome Backfill

    /// Backfill BG outcomes for pending V2 meal outcomes.
    func backfillOutcomes(context: NSManagedObjectContext) async {
        var outcomes = loadAll()
        var anyUpdated = false

        for i in 0 ..< outcomes.count {
            var updated = false

            for j in 0 ..< outcomes[i].checkpoints.count {
                guard outcomes[i].checkpoints[j].bgValue == nil else { continue }

                let hoursAfter = outcomes[i].checkpoints[j].hoursAfterMeal
                let targetTime = outcomes[i].date.addingTimeInterval(TimeInterval(hoursAfter * 3600))

                guard Date() > targetTime.addingTimeInterval(30 * 60) else { continue }

                if let bg = await fetchClosestGlucose(near: targetTime, withinMinutes: 30, context: context) {
                    outcomes[i].checkpoints[j].bgValue = bg
                    updated = true
                }
            }

            if updated {
                anyUpdated = true
            }
        }

        if anyUpdated {
            persistOutcomes(outcomes)
        }

        // (#4) After backfilling BG data, detect confounding meals and mark dirty checkpoints
        detectConfoundingMeals()
    }

    private func fetchClosestGlucose(
        near targetTime: Date,
        withinMinutes: Int,
        context: NSManagedObjectContext
    ) async -> Int? {
        let window = TimeInterval(withinMinutes * 60)
        let startDate = targetTime.addingTimeInterval(-window)
        let endDate = targetTime.addingTimeInterval(window)

        return await context.perform {
            let request = GlucoseStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                startDate as NSDate,
                endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            guard let results = try? context.fetch(request), !results.isEmpty else {
                return nil
            }

            let closest = results.min { a, b in
                guard let dateA = a.date, let dateB = b.date else { return false }
                return abs(dateA.timeIntervalSince(targetTime)) < abs(dateB.timeIntervalSince(targetTime))
            }

            return closest.map { Int($0.glucose) }
        }
    }

    // MARK: - Curve Parameter Learning

    /// Learn personal curve parameters from completed outcomes.
    /// Uses per-curve error attribution:
    ///   - Early (0-2h) checkpoints → carb tau
    ///   - Mid (2-5h) checkpoints → protein factor
    ///   - Late (4-9h) checkpoints → fat coefficient
    func recalculateCurveParameters(
        targetLow: Int = 70,
        targetHigh: Int = 180,
        currentCarbRatio: Double? = nil
    ) -> V2PersonalCurveParameters {
        var params = loadParameters()
        let completed = loadAll().filter { outcome in
            !outcome.hasConfoundingMeal &&
                outcome.checkpoints.contains { $0.bgValue != nil }
        }

        guard !completed.isEmpty else { return params }

        var carbTauAdjustment = 0.0
        var carbTauWeight = 0.0
        var proteinAdjustment = 0.0
        var proteinWeight = 0.0
        var fatAdjustment = 0.0
        var fatWeight = 0.0

        let now = Date()

        for outcome in completed {
            // ICR-tagged filtering
            if let currentCR = currentCarbRatio, currentCR > 0 {
                let ratio = outcome.carbRatioAtMeal / currentCR
                guard ratio >= (1.0 - icrMatchTolerance), ratio <= (1.0 + icrMatchTolerance) else { continue }
            }

            let ageInDays = now.timeIntervalSince(outcome.date) / 86400
            let recencyWeight = max(0.1, 1.0 - (ageInDays / Double(retentionDays)))

            for cp in outcome.checkpoints {
                guard let bg = cp.bgValue, cp.isClean else { continue }

                let error: Double
                if bg > targetHigh {
                    error = Double(bg - targetHigh) / 100.0 // positive = under-dosed
                } else if bg < targetLow {
                    error = -Double(targetLow - bg) / 100.0 // negative = over-dosed
                } else {
                    continue // in range, no adjustment needed
                }

                switch cp.curvePhase {
                case .carb:
                    // Early high → carbs absorbed faster than predicted → decrease tau
                    // Early low → carbs absorbed slower → increase tau
                    carbTauAdjustment += -error * 2.0 * recencyWeight // 2 min per 100mg/dL error
                    carbTauWeight += recencyWeight

                case .protein:
                    // Mid high → protein effect stronger than modeled → increase factor
                    // Mid low → protein weaker → decrease factor
                    proteinAdjustment += error * 0.02 * recencyWeight
                    proteinWeight += recencyWeight

                case .fat:
                    // Late high → fat resistance stronger → increase coefficient
                    // Late low → fat resistance weaker → decrease coefficient
                    fatAdjustment += error * 0.05 * recencyWeight
                    fatWeight += recencyWeight

                case .overlap:
                    // Distribute error across active curves with reduced weight
                    carbTauAdjustment += -error * 1.0 * recencyWeight * 0.3
                    carbTauWeight += recencyWeight * 0.3
                    proteinAdjustment += error * 0.01 * recencyWeight * 0.3
                    proteinWeight += recencyWeight * 0.3
                    fatAdjustment += error * 0.025 * recencyWeight * 0.3
                    fatWeight += recencyWeight * 0.3

                case .skip:
                    // (#3) This checkpoint is not relevant for this meal's macros — skip
                    break
                }
            }
        }

        // Apply adjustments with clamping
        if carbTauWeight > 0 {
            let avgAdj = carbTauAdjustment / carbTauWeight
            let current = params.effectiveCarbTau
            params.carbTau = max(20, min(60, current + avgAdj))
        }

        if proteinWeight > 0 {
            let avgAdj = proteinAdjustment / proteinWeight
            let current = params.effectiveProteinFactor
            params.proteinFactor = max(0.10, min(0.80, current + avgAdj)) // (#10) match slider range
        }

        if fatWeight > 0 {
            let avgAdj = fatAdjustment / fatWeight
            let current = params.effectiveFatTotalCoeff
            params.fatTotalCoeff = max(0.30, min(1.20, current + avgAdj))
        }

        saveParameters(params)
        return params
    }

    // MARK: - Create Outcome from Meal

    /// Create a V2 outcome record from a meal absorption result and context.
    /// Uses dynamic phase attribution (#3) based on actual macros instead of hardcoded phases.
    static func createOutcome(
        from result: MacroAbsorptionResult,
        garminSnapshot: GarminContextSnapshot?,
        bgAtMeal: Int,
        carbRatio: Double,
        isf: Double,
        smbMultiplier: Double,
        mealModeActive: Bool,
        proteinThreshold: Double = 15
    ) -> V2MealOutcome {
        // (#3) Dynamic phase attribution based on actual meal composition
        let checkpoints = V2BGCheckpoint.computePhases(
            carbs: result.originalCarbs,
            fat: result.originalFat,
            protein: result.originalProtein,
            proteinThreshold: proteinThreshold
        )

        return V2MealOutcome(
            id: UUID(),
            date: Date(),
            mealID: result.mealID,
            carbs: result.originalCarbs,
            fat: result.originalFat,
            protein: result.originalProtein,
            fiber: result.originalFiber,
            tauCarb: result.tauCarb,
            proteinFactor: result.proteinFactor,
            fatTotalEquiv: result.fatTotalEquiv,
            upfrontPercent: result.upfrontPercent,
            curveSuggestedPercent: result.curveSuggestedPercent,
            insulinDemandFactor: result.insulinDemandFactor,
            safeWindowMinutes: result.safeWindowMinutes,
            garminSnapshot: garminSnapshot,
            bgAtMeal: bgAtMeal,
            carbRatioAtMeal: carbRatio,
            isfAtMeal: isf,
            mealSMBMultiplier: smbMultiplier,
            mealModeWasActive: mealModeActive,
            adaptiveAdjustments: [],
            checkpoints: checkpoints,
            hasConfoundingMeal: false
        )
    }

    // MARK: - Export for Claude Recalibration

    /// Export recent outcomes in a structured format for Claude analysis.
    func exportForRecalibration(lastDays: Int = 7) -> V2RecalibrationExport {
        let cutoff = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date()) ?? Date()
        let recent = loadAll().filter { $0.date >= cutoff }
        let params = loadParameters()

        return V2RecalibrationExport(
            exportDate: Date(),
            periodDays: lastDays,
            outcomes: recent,
            currentParameters: params
        )
    }

    // MARK: - Comprehensive Data Export

    /// Build a full data export for every recorded meal: pre-meal BG trace,
    /// all V2 engine inputs, all curve parameters, Garmin context with contribution
    /// breakdown, user settings, scheduled dosing entries, and BG outcomes.
    func buildComprehensiveExport(context: NSManagedObjectContext) async -> V2ComprehensiveExport {
        let outcomes = loadAll()
        let params = loadParameters()

        // Snapshot current user settings at export time
        let storage = BaseFileStorage()
        let trioSettings = storage.retrieve(OpenAPS.Trio.settings, as: TrioSettings.self)
            ?? TrioSettings()
        let preferences = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
            ?? Preferences()

        let settingsSnapshot = V2UserSettingsSnapshot(
            // V2 engine settings
            useV2MacroAbsorption: trioSettings.useV2MacroAbsorption,
            insulinType: trioSettings.insulinType,
            v2SafeWindowMinutesOverride: trioSettings.v2SafeWindowMinutes,
            mealModeSMBMultiplier: Double(truncating: trioSettings.mealModeSMBMultiplier as NSDecimalNumber),
            mealModeBGFloor: Double(truncating: trioSettings.mealModeBGFloor as NSDecimalNumber),
            garminEnabled: trioSettings.garminEnabled,
            v2OutcomeLearningEnabled: trioSettings.v2OutcomeLearningEnabled,
            claudeRecalibrationEnabled: trioSettings.claudeRecalibrationEnabled,
            // OpenAPS/oref settings that affect dosing
            maxIOB: Double(truncating: preferences.maxIOB as NSDecimalNumber),
            maxSMBBasalMinutes: Double(truncating: preferences.maxSMBBasalMinutes as NSDecimalNumber),
            maxUAMSMBBasalMinutes: Double(truncating: preferences.maxUAMSMBBasalMinutes as NSDecimalNumber),
            smbDeliveryRatio: Double(truncating: preferences.smbDeliveryRatio as NSDecimalNumber),
            smbInterval: Double(truncating: preferences.smbInterval as NSDecimalNumber),
            insulinCurve: preferences.curve.rawValue,
            insulinPeakTime: Double(truncating: preferences.insulinPeakTime as NSDecimalNumber),
            useCustomPeakTime: preferences.useCustomPeakTime,
            maxCOB: Double(truncating: preferences.maxCOB as NSDecimalNumber),
            enableSMBAlways: preferences.enableSMBAlways,
            enableSMBWithCOB: preferences.enableSMBWithCOB,
            enableSMBAfterCarbs: preferences.enableSMBAfterCarbs,
            enableUAM: preferences.enableUAM,
            autosensMax: Double(truncating: preferences.autosensMax as NSDecimalNumber),
            autosensMin: Double(truncating: preferences.autosensMin as NSDecimalNumber)
        )

        var mealExports: [V2MealExportRecord] = []

        for outcome in outcomes {
            // Fetch 2h pre-meal BG trace (every 5 min reading)
            let preMealStart = outcome.date.addingTimeInterval(-2 * 3600)
            let preMealBG = await fetchGlucoseTrace(
                from: preMealStart,
                to: outcome.date,
                context: context
            )

            // Fetch post-meal BG trace through end of absorption window (8h)
            let postMealEnd = outcome.date.addingTimeInterval(8 * 3600)
            let postMealBG = await fetchGlucoseTrace(
                from: outcome.date,
                to: min(postMealEnd, Date()),
                context: context
            )

            // Fetch all scheduled V2 dosing entries for this meal (past + future)
            let scheduled = await fetchScheduledEntries(
                mealID: outcome.mealID,
                context: context
            )

            // Re-derive Garmin sensitivity contributions from stored snapshot
            let garminResult = GarminSensitivityModel.computeDemandFactor(from: outcome.garminSnapshot)
            let garminContributions = garminResult.contributions.map {
                V2GarminContribution(
                    metric: $0.metric,
                    value: $0.value,
                    impact: $0.impact,
                    description: $0.description
                )
            }

            // Compute dosing summary from stored outcome fields
            let upfrontCarbs = outcome.carbs * outcome.upfrontPercent * outcome.insulinDemandFactor
            let proteinEquiv = outcome.protein * outcome.proteinFactor
            let futureEntrySum = scheduled.reduce(0.0) { $0 + $1.carbEquivalent }
            let totalEffectiveCarbs = upfrontCarbs + futureEntrySum

            let dosingSummary = V2DosingSummary(
                upfrontCarbsForBolus: upfrontCarbs,
                upfrontInsulin: outcome.carbRatioAtMeal > 0
                    ? upfrontCarbs / outcome.carbRatioAtMeal : 0,
                proteinGlucoEquivalent: proteinEquiv,
                fatCarbEquivalent: outcome.fatTotalEquiv,
                totalEffectiveCarbs: totalEffectiveCarbs,
                totalScheduledEntries: scheduled.count,
                pendingEntries: scheduled.filter { !$0.isAbsorbed }.count,
                absorbedEntries: scheduled.filter { $0.isAbsorbed }.count
            )

            let record = V2MealExportRecord(
                outcome: outcome,
                preMealBGTrace: preMealBG,
                postMealBGTrace: postMealBG,
                scheduledEntries: scheduled,
                garminContributions: garminContributions,
                dosingSummary: dosingSummary
            )
            mealExports.append(record)
        }

        return V2ComprehensiveExport(
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            totalMeals: outcomes.count,
            currentParameters: params,
            userSettings: settingsSnapshot,
            meals: mealExports
        )
    }

    /// Fetch all glucose readings in a time range as lightweight structs.
    private func fetchGlucoseTrace(
        from start: Date,
        to end: Date,
        context: NSManagedObjectContext
    ) async -> [V2BGReading] {
        await context.perform {
            let request = GlucoseStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                start as NSDate,
                end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }

            return results.compactMap { entry in
                guard let date = entry.date else { return nil }
                return V2BGReading(
                    date: date,
                    glucose: Int(entry.glucose),
                    direction: entry.direction
                )
            }
        }
    }

    /// Fetch all scheduled carb entries (V2 split-dosing + fat/protein entries) for a meal.
    /// Returns both past (absorbed) and future (pending) entries sorted by date.
    private func fetchScheduledEntries(
        mealID: String,
        context: NSManagedObjectContext
    ) async -> [V2ScheduledEntry] {
        await context.perform {
            guard let uuid = UUID(uuidString: mealID) else { return [] }

            let request: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(format: "fpuID == %@", uuid as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }
            let now = Date()

            return results.compactMap { entry in
                guard let date = entry.date else { return nil }
                return V2ScheduledEntry(
                    date: date,
                    carbEquivalent: entry.carbs,
                    entryType: entry.note ?? "unknown",
                    isAbsorbed: date <= now,
                    isFPU: entry.isFPU
                )
            }
        }
    }
}

// MARK: - Export Format

/// Structured data export for Claude recalibration analysis.
struct V2RecalibrationExport: Codable {
    let exportDate: Date
    let periodDays: Int
    let outcomes: [V2MealOutcome]
    let currentParameters: V2PersonalCurveParameters
}

// MARK: - Comprehensive Export Types

/// A single BG reading for export.
struct V2BGReading: Codable {
    let date: Date
    let glucose: Int        // mg/dL
    let direction: String?  // CGM trend arrow (e.g. "Flat", "FortyFiveUp")
}

/// A single scheduled carb entry from the V2 dosing engine.
/// These are the actual entries written to Core Data that oref sees.
struct V2ScheduledEntry: Codable {
    let date: Date              // when this entry is scheduled to be "absorbed"
    let carbEquivalent: Double  // grams of carb-equivalent (may be from protein/fat curve)
    let entryType: String       // "carb", "protein-gluco", "fat-resistance", or "unknown"
    let isAbsorbed: Bool        // true if date is in the past (already consumed by oref)
    let isFPU: Bool             // true for V2 curve entries (protein/fat/split-carb)
}

/// Garmin sensitivity contribution — one metric's effect on insulin demand.
struct V2GarminContribution: Codable {
    let metric: String          // e.g. "Sleep Score", "Body Battery", "Stress"
    let value: String           // e.g. "42/100", "< 15"
    let impact: Double          // e.g. -0.22 (negative = more resistant)
    let description: String     // e.g. "Terrible sleep: 22% more resistant"
}

/// Computed dosing summary — what the V2 engine actually decided for this meal.
struct V2DosingSummary: Codable {
    let upfrontCarbsForBolus: Double    // carbs * upfrontPercent * demandFactor
    let upfrontInsulin: Double          // upfrontCarbs / carbRatio (units)
    let proteinGlucoEquivalent: Double  // protein * proteinFactor (grams carb-equiv)
    let fatCarbEquivalent: Double       // from nonlinear ramp (grams carb-equiv)
    let totalEffectiveCarbs: Double     // upfront + all scheduled entries
    let totalScheduledEntries: Int      // count of entries in Core Data
    let pendingEntries: Int             // entries still in the future
    let absorbedEntries: Int            // entries already past
}

/// User settings snapshot at export time — all settings that affect V2 dosing.
struct V2UserSettingsSnapshot: Codable {
    // V2 engine settings
    let useV2MacroAbsorption: Bool
    let insulinType: String             // "rapidActing" or "ultraRapid"
    let v2SafeWindowMinutesOverride: Int?
    let mealModeSMBMultiplier: Double
    let mealModeBGFloor: Double
    let garminEnabled: Bool
    let v2OutcomeLearningEnabled: Bool
    let claudeRecalibrationEnabled: Bool

    // OpenAPS/oref settings that affect insulin delivery
    let maxIOB: Double
    let maxSMBBasalMinutes: Double
    let maxUAMSMBBasalMinutes: Double
    let smbDeliveryRatio: Double
    let smbInterval: Double             // minutes between SMBs
    let insulinCurve: String            // "rapidActing", "ultraRapid", "bilinear"
    let insulinPeakTime: Double         // minutes
    let useCustomPeakTime: Bool
    let maxCOB: Double
    let enableSMBAlways: Bool
    let enableSMBWithCOB: Bool
    let enableSMBAfterCarbs: Bool
    let enableUAM: Bool
    let autosensMax: Double
    let autosensMin: Double
}

/// Complete export record for one meal — everything the system knew and did.
struct V2MealExportRecord: Codable {
    // The full outcome record (macros, params, Garmin snapshot, checkpoints, adjustments)
    let outcome: V2MealOutcome

    // 2h pre-meal BG trace — every CGM reading from meal-2h to meal time
    let preMealBGTrace: [V2BGReading]

    // Post-meal BG trace — every CGM reading from meal time through 8h (or now)
    let postMealBGTrace: [V2BGReading]

    // All scheduled dosing entries for this meal — past (absorbed) and future (pending).
    // Shows exactly what the V2 engine wrote to Core Data for oref to process.
    let scheduledEntries: [V2ScheduledEntry]

    // Garmin sensitivity breakdown — which metrics affected the demand factor and by how much.
    // Re-derived from the stored GarminContextSnapshot at export time.
    let garminContributions: [V2GarminContribution]

    // Computed dosing summary — what the engine decided (upfront insulin, effective carbs, etc.)
    let dosingSummary: V2DosingSummary
}

/// Top-level comprehensive export — the whole system picture.
struct V2ComprehensiveExport: Codable {
    let exportDate: Date
    let appVersion: String
    let totalMeals: Int
    let currentParameters: V2PersonalCurveParameters
    let userSettings: V2UserSettingsSnapshot
    let meals: [V2MealExportRecord]
}
