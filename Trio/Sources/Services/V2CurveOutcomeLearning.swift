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

    // Garmin per-metric contributions captured at meal time (critique item #10).
    // Stored so exports reflect the weights that were active when the meal was dosed,
    // not the current weights which may have changed via recalibration.
    let garminContributions: [V2GarminContribution]?

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

    // Actual insulin the user chose to deliver (may differ from engine recommendation
    // if user moved slider or typed a custom amount). nil for legacy outcomes.
    var actualBolusDelivered: Double?

    // When the meal was detected in HealthKit (eating time proxy).
    // Differs from `date` (dose time) when user delays dosing after eating.
    // nil for legacy outcomes or when meal time couldn't be determined.
    var mealDetectedAt: Date?

    struct AdaptiveAdjustmentRecord: Codable {
        let timestamp: Date
        let scalingFactor: Double
        let cumulativeScaling: Double
        let actualBG: Double
        let predictedBG: Double
    }

    /// Return a copy with a different mealID (used to link outcome to engine-generated Core Data entries).
    func withMealID(_ newMealID: String) -> V2MealOutcome {
        var copy = V2MealOutcome(
            id: id, date: date, mealID: newMealID,
            carbs: carbs, fat: fat, protein: protein, fiber: fiber,
            tauCarb: tauCarb, proteinFactor: proteinFactor, fatTotalEquiv: fatTotalEquiv,
            upfrontPercent: upfrontPercent, curveSuggestedPercent: curveSuggestedPercent,
            insulinDemandFactor: insulinDemandFactor, safeWindowMinutes: safeWindowMinutes,
            garminSnapshot: garminSnapshot, garminContributions: garminContributions,
            bgAtMeal: bgAtMeal,
            carbRatioAtMeal: carbRatioAtMeal, isfAtMeal: isfAtMeal,
            mealSMBMultiplier: mealSMBMultiplier, mealModeWasActive: mealModeWasActive,
            adaptiveAdjustments: adaptiveAdjustments, checkpoints: checkpoints,
            hasConfoundingMeal: hasConfoundingMeal
        )
        copy.actualBolusDelivered = actualBolusDelivered
        copy.mealDetectedAt = mealDetectedAt
        return copy
    }

    /// Return a copy with a Garmin snapshot (and its contributions) attached.
    func withGarminSnapshot(_ snapshot: GarminContextSnapshot?) -> V2MealOutcome {
        // Compute contributions at attachment time so they reflect current weights
        let contributions: [V2GarminContribution]? = snapshot.map { _ in
            GarminSensitivityModel.computeDemandFactor(from: snapshot).contributions.map {
                V2GarminContribution(metric: $0.metric, value: $0.value,
                                     impact: $0.impact, description: $0.description)
            }
        }
        var copy = V2MealOutcome(
            id: id, date: date, mealID: mealID,
            carbs: carbs, fat: fat, protein: protein, fiber: fiber,
            tauCarb: tauCarb, proteinFactor: proteinFactor, fatTotalEquiv: fatTotalEquiv,
            upfrontPercent: upfrontPercent, curveSuggestedPercent: curveSuggestedPercent,
            insulinDemandFactor: insulinDemandFactor, safeWindowMinutes: safeWindowMinutes,
            garminSnapshot: snapshot, garminContributions: contributions,
            bgAtMeal: bgAtMeal,
            carbRatioAtMeal: carbRatioAtMeal, isfAtMeal: isfAtMeal,
            mealSMBMultiplier: mealSMBMultiplier, mealModeWasActive: mealModeWasActive,
            adaptiveAdjustments: adaptiveAdjustments, checkpoints: checkpoints,
            hasConfoundingMeal: hasConfoundingMeal
        )
        copy.actualBolusDelivered = actualBolusDelivered
        copy.mealDetectedAt = mealDetectedAt
        return copy
    }
}

/// BG checkpoint for V2 outcome tracking with curve attribution.
struct V2BGCheckpoint: Codable {
    let hoursAfterMeal: Double
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
    /// Generates 16 checkpoints at 30-minute intervals from 0.5h to 8.0h for
    /// high-resolution BG tracking across all absorption phases.
    static func computePhases(
        carbs: Double,
        fat: Double,
        protein: Double,
        proteinThreshold: Double
    ) -> [V2BGCheckpoint] {
        let hasProtein = protein > proteinThreshold
        let hasFat = fat >= 5

        // Phase attribution by time window:
        // 0.5–2.0h: carb absorption (gamma curve peak ~1–1.5h, tail to ~3h)
        // 2.5–3.0h: protein onset if present, else late carb tail
        // 3.5–5.0h: protein peak (4–5h) / fat onset / overlap
        // 5.5–8.0h: fat insulin resistance (gaussian peak ~5–7h)
        return [
            // Carb phase: early absorption window
            V2BGCheckpoint(hoursAfterMeal: 0.5, bgValue: nil, isClean: true, curvePhase: .carb),
            V2BGCheckpoint(hoursAfterMeal: 1.0, bgValue: nil, isClean: true, curvePhase: .carb),
            V2BGCheckpoint(hoursAfterMeal: 1.5, bgValue: nil, isClean: true, curvePhase: .carb),
            V2BGCheckpoint(hoursAfterMeal: 2.0, bgValue: nil, isClean: true, curvePhase: .carb),
            // Transition: protein onset or late carb
            V2BGCheckpoint(hoursAfterMeal: 2.5, bgValue: nil, isClean: true,
                           curvePhase: hasProtein ? .protein : .carb),
            V2BGCheckpoint(hoursAfterMeal: 3.0, bgValue: nil, isClean: true,
                           curvePhase: hasProtein ? .protein : .carb),
            // Mid window: protein peak and fat onset
            V2BGCheckpoint(hoursAfterMeal: 3.5, bgValue: nil, isClean: true,
                           curvePhase: hasProtein ? .protein : hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 4.0, bgValue: nil, isClean: true,
                           curvePhase: hasProtein && hasFat ? .overlap :
                                       hasProtein ? .protein : hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 4.5, bgValue: nil, isClean: true,
                           curvePhase: hasProtein && hasFat ? .overlap :
                                       hasProtein ? .protein : hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 5.0, bgValue: nil, isClean: true,
                           curvePhase: hasProtein ? .protein : hasFat ? .fat : .skip),
            // Late window: fat insulin resistance
            V2BGCheckpoint(hoursAfterMeal: 5.5, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 6.0, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 6.5, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 7.0, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 7.5, bgValue: nil, isClean: true,
                           curvePhase: hasFat ? .fat : .skip),
            V2BGCheckpoint(hoursAfterMeal: 8.0, bgValue: nil, isClean: true,
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
    var fiberCoefficient: Double?   // base: 0.30 min/g, user-adjustable

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
    var effectiveFiberCoefficient: Double { fiberCoefficient ?? 0.30 }
}

// MARK: - Parameter History (critique item #9)

/// A timestamped snapshot of curve parameters, stored for rollback.
struct V2ParameterSnapshot: Codable {
    let date: Date
    let source: String          // "learning", "claude", "manual", "reset"
    let parameters: V2PersonalCurveParameters
}

// MARK: - Outcome Learning Store

/// Persistent store for V2 meal outcomes and personal parameter learning.
/// Uses Core Data for outcome storage (#13) with a one-time migration from UserDefaults.
/// Parameters remain in UserDefaults (small, infrequently updated).
final class V2OutcomeLearningStore {
    static let shared = V2OutcomeLearningStore()

    private let legacyOutcomesKey = "V2MealOutcomes"
    private let migrationCompletedKey = "V2OutcomesMigratedToCoreData"
    private let parametersKey = "V2PersonalCurveParameters"
    private let parameterHistoryKey = "V2ParameterHistory"
    private static let maxHistoryEntries = 10
    private let retentionDays = 90
    private let icrMatchTolerance = 0.10

    /// Background backfill runs at most once per this interval (seconds).
    private static let backgroundBackfillInterval: TimeInterval = 6 * 3600 // 6 hours
    private static let lastBackfillKey = "V2LastBackgroundBackfill"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var migrationAttempted = false

    private init() {}

    /// Ensure migration has been attempted before any Core Data access.
    /// Called lazily on first save/load/update rather than in init() to avoid
    /// racing with CoreDataStack.initializeStack() during app launch.
    private func ensureMigrated() {
        guard !migrationAttempted else { return }
        migrationAttempted = true
        migrateFromUserDefaultsIfNeeded()
    }

    /// Check if the Core Data persistent store is loaded and ready.
    private var isStoreReady: Bool {
        !CoreDataStack.shared.persistentContainer.persistentStoreCoordinator.persistentStores.isEmpty
    }

    // MARK: - Core Data ↔ Struct Conversion

    private func toStored(_ outcome: V2MealOutcome, in context: NSManagedObjectContext) -> V2MealOutcomeStored {
        let stored = V2MealOutcomeStored(context: context)
        stored.id = outcome.id
        stored.date = outcome.date
        stored.mealID = outcome.mealID
        stored.carbs = outcome.carbs
        stored.fat = outcome.fat
        stored.protein = outcome.protein
        stored.fiber = outcome.fiber
        stored.tauCarb = outcome.tauCarb
        stored.proteinFactor = outcome.proteinFactor
        stored.fatTotalEquiv = outcome.fatTotalEquiv
        stored.upfrontPercent = outcome.upfrontPercent
        stored.curveSuggestedPercent = outcome.curveSuggestedPercent
        stored.insulinDemandFactor = outcome.insulinDemandFactor
        stored.safeWindowMinutes = Int16(outcome.safeWindowMinutes)
        stored.bgAtMeal = Int16(outcome.bgAtMeal)
        stored.carbRatioAtMeal = outcome.carbRatioAtMeal
        stored.isfAtMeal = outcome.isfAtMeal
        stored.mealSMBMultiplier = outcome.mealSMBMultiplier
        stored.mealModeWasActive = outcome.mealModeWasActive
        stored.hasConfoundingMeal = outcome.hasConfoundingMeal
        stored.actualBolusDelivered = outcome.actualBolusDelivered ?? 0
        stored.mealDetectedAt = outcome.mealDetectedAt
        stored.checkpointsJSON = try? encoder.encode(outcome.checkpoints)
        stored.adaptiveAdjustmentsJSON = try? encoder.encode(outcome.adaptiveAdjustments)
        stored.garminSnapshotJSON = try? encoder.encode(outcome.garminSnapshot)
        stored.garminContributionsJSON = try? encoder.encode(outcome.garminContributions)
        return stored
    }

    private func toOutcome(_ stored: V2MealOutcomeStored) -> V2MealOutcome? {
        guard let id = stored.id, let date = stored.date else { return nil }

        let checkpoints: [V2BGCheckpoint] = stored.checkpointsJSON
            .flatMap { try? decoder.decode([V2BGCheckpoint].self, from: $0) } ?? []
        let adjustments: [V2MealOutcome.AdaptiveAdjustmentRecord] = stored.adaptiveAdjustmentsJSON
            .flatMap { try? decoder.decode([V2MealOutcome.AdaptiveAdjustmentRecord].self, from: $0) } ?? []
        let garmin: GarminContextSnapshot? = stored.garminSnapshotJSON
            .flatMap { try? decoder.decode(GarminContextSnapshot.self, from: $0) }
        let garminContribs: [V2GarminContribution]? = stored.garminContributionsJSON
            .flatMap { try? decoder.decode([V2GarminContribution].self, from: $0) }

        var outcome = V2MealOutcome(
            id: id, date: date, mealID: stored.mealID ?? "",
            carbs: stored.carbs, fat: stored.fat, protein: stored.protein, fiber: stored.fiber,
            tauCarb: stored.tauCarb, proteinFactor: stored.proteinFactor, fatTotalEquiv: stored.fatTotalEquiv,
            upfrontPercent: stored.upfrontPercent, curveSuggestedPercent: stored.curveSuggestedPercent,
            insulinDemandFactor: stored.insulinDemandFactor, safeWindowMinutes: Int(stored.safeWindowMinutes),
            garminSnapshot: garmin, garminContributions: garminContribs,
            bgAtMeal: Int(stored.bgAtMeal),
            carbRatioAtMeal: stored.carbRatioAtMeal, isfAtMeal: stored.isfAtMeal,
            mealSMBMultiplier: stored.mealSMBMultiplier, mealModeWasActive: stored.mealModeWasActive,
            adaptiveAdjustments: adjustments, checkpoints: checkpoints,
            hasConfoundingMeal: stored.hasConfoundingMeal
        )
        outcome.actualBolusDelivered = stored.actualBolusDelivered > 0 ? stored.actualBolusDelivered : nil
        outcome.mealDetectedAt = stored.mealDetectedAt
        return outcome
    }

    private func updateStored(_ stored: V2MealOutcomeStored, from outcome: V2MealOutcome) {
        stored.hasConfoundingMeal = outcome.hasConfoundingMeal
        stored.checkpointsJSON = try? encoder.encode(outcome.checkpoints)
        stored.adaptiveAdjustmentsJSON = try? encoder.encode(outcome.adaptiveAdjustments)
    }

    // MARK: - One-Time Migration from UserDefaults (#13)

    private func migrateFromUserDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationCompletedKey) else { return }
        guard isStoreReady else {
            debugPrint("V2OutcomeLearningStore: Core Data store not ready, deferring migration")
            migrationAttempted = false // Allow retry on next access
            return
        }
        guard let data = UserDefaults.standard.data(forKey: legacyOutcomesKey) else {
            UserDefaults.standard.set(true, forKey: migrationCompletedKey)
            return
        }

        do {
            let legacyOutcomes = try decoder.decode([V2MealOutcome].self, from: data)
            guard !legacyOutcomes.isEmpty else {
                UserDefaults.standard.set(true, forKey: migrationCompletedKey)
                return
            }

            let context = CoreDataStack.shared.newTaskContext()
            context.performAndWait {
                for outcome in legacyOutcomes {
                    _ = toStored(outcome, in: context)
                }
                do {
                    try context.save()
                    UserDefaults.standard.set(true, forKey: migrationCompletedKey)
                    UserDefaults.standard.removeObject(forKey: legacyOutcomesKey)
                    debugPrint("V2OutcomeLearningStore: Migrated \(legacyOutcomes.count) outcomes to Core Data")
                } catch {
                    debugPrint("V2OutcomeLearningStore: Migration failed: \(error)")
                }
            }
        } catch {
            debugPrint("V2OutcomeLearningStore: Failed to decode legacy outcomes for migration: \(error)")
        }
    }

    // MARK: - Outcome Storage (Core Data)

    func save(_ outcome: V2MealOutcome) {
        ensureMigrated()
        guard isStoreReady else {
            debugPrint("V2OutcomeLearningStore: Core Data not ready, cannot save outcome")
            return
        }
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            _ = toStored(outcome, in: context)
            try? context.save()
        }
    }

    func loadAll() -> [V2MealOutcome] {
        ensureMigrated()
        guard isStoreReady else { return [] }
        let context = CoreDataStack.shared.newTaskContext()
        var results: [V2MealOutcome] = []
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()

        context.performAndWait {
            let request = V2MealOutcomeStored.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            guard let fetched = try? context.fetch(request) else { return }
            results = fetched.compactMap { toOutcome($0) }
        }
        return results
    }

    func update(_ outcome: V2MealOutcome) {
        guard isStoreReady else { return }
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            let request = V2MealOutcomeStored.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", outcome.id as CVarArg)
            request.fetchLimit = 1

            if let stored = (try? context.fetch(request))?.first {
                updateStored(stored, from: outcome)
                try? context.save()
            }
        }
    }

    // MARK: - Personal Parameters (still in UserDefaults — small, infrequently updated)

    func loadParameters() -> V2PersonalCurveParameters {
        guard let data = UserDefaults.standard.data(forKey: parametersKey),
              let params = try? decoder.decode(V2PersonalCurveParameters.self, from: data)
        else {
            return V2PersonalCurveParameters()
        }
        return params
    }

    func saveParameters(_ params: V2PersonalCurveParameters) {
        if let data = try? encoder.encode(params) {
            UserDefaults.standard.set(data, forKey: parametersKey)
        }
    }

    /// Save parameters with a history snapshot for rollback (critique item #9).
    /// Captures the current parameters before overwriting so the user can undo bad changes.
    func saveParametersWithHistory(_ params: V2PersonalCurveParameters, source: String) {
        // Snapshot the *current* parameters before overwriting
        let current = loadParameters()
        appendParameterSnapshot(current, source: source)
        saveParameters(params)
    }

    /// Load the parameter change history (most recent first).
    func loadParameterHistory() -> [V2ParameterSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: parameterHistoryKey),
              let history = try? decoder.decode([V2ParameterSnapshot].self, from: data)
        else { return [] }
        return history.sorted { $0.date > $1.date }
    }

    /// Rollback to a specific snapshot.
    func rollbackToSnapshot(_ snapshot: V2ParameterSnapshot) {
        saveParameters(snapshot.parameters)
    }

    private func appendParameterSnapshot(_ params: V2PersonalCurveParameters, source: String) {
        var history = loadParameterHistory()
        let snapshot = V2ParameterSnapshot(date: Date(), source: source, parameters: params)
        history.insert(snapshot, at: 0)

        // Keep only the most recent entries
        if history.count > Self.maxHistoryEntries {
            history = Array(history.prefix(Self.maxHistoryEntries))
        }

        if let data = try? encoder.encode(history) {
            UserDefaults.standard.set(data, forKey: parameterHistoryKey)
        }
    }

    // MARK: - Confounding Meal Detection (#4)

    /// Detect confounding meals: if another meal was recorded within the 8h window
    /// of a given outcome, mark individual checkpoints as dirty where the overlap occurs.
    func detectConfoundingMeals() {
        var outcomes = loadAll()
        guard outcomes.count > 1 else { return }

        for i in 0 ..< outcomes.count {
            let mealTime = outcomes[i].date
            let windowEnd = mealTime.addingTimeInterval(8 * 3600)

            // Find any overlapping meals that are large enough to meaningfully confound.
            // Small snacks (<15g carbs AND <5g fat) don't produce enough glucose impact
            // to contaminate late-phase checkpoints (critique item #6).
            let overlappingMeals = outcomes.filter { other in
                other.id != outcomes[i].id &&
                    other.date > mealTime &&
                    other.date < windowEnd &&
                    (other.carbs >= 15 || other.fat >= 5)
            }

            var modified = false

            if overlappingMeals.isEmpty {
                if outcomes[i].hasConfoundingMeal {
                    outcomes[i].hasConfoundingMeal = false
                    modified = true
                }
            } else {
                // Per-checkpoint clean/dirty marking based on whether a confounding meal's
                // absorption window overlaps that specific checkpoint time
                outcomes[i].hasConfoundingMeal = true
                modified = true
                for j in 0 ..< outcomes[i].checkpoints.count {
                    let cpTime = mealTime.addingTimeInterval(
                        outcomes[i].checkpoints[j].hoursAfterMeal * 3600
                    )
                    let isDirty = overlappingMeals.contains { $0.date < cpTime }
                    if isDirty {
                        outcomes[i].checkpoints[j].isClean = false
                    }
                }
            }

            if modified {
                update(outcomes[i])
            }
        }
    }

    // MARK: - Outcome Backfill

    /// Backfill BG outcomes for pending V2 meal outcomes.
    func backfillOutcomes(context: NSManagedObjectContext) async {
        var outcomes = loadAll()

        for i in 0 ..< outcomes.count {
            var updated = false

            for j in 0 ..< outcomes[i].checkpoints.count {
                guard outcomes[i].checkpoints[j].bgValue == nil else { continue }

                let hoursAfter = outcomes[i].checkpoints[j].hoursAfterMeal
                let targetTime = outcomes[i].date.addingTimeInterval(hoursAfter * 3600)

                guard Date() > targetTime.addingTimeInterval(30 * 60) else { continue }

                if let bg = await fetchClosestGlucose(near: targetTime, withinMinutes: 15, context: context) {
                    outcomes[i].checkpoints[j].bgValue = bg
                    updated = true
                }
            }

            if updated {
                update(outcomes[i])
            }
        }

        // (#4) After backfilling BG data, detect confounding meals and mark dirty checkpoints
        detectConfoundingMeals()
    }

    /// Background backfill: called from the loop cycle (via MacroAdaptiveService) with
    /// rate limiting. Runs at most once every 6 hours so that outcome learning doesn't
    /// depend on the user opening a specific UI screen.
    func backgroundBackfillIfNeeded(context: NSManagedObjectContext) async {
        let lastRun = UserDefaults.standard.double(forKey: Self.lastBackfillKey)
        let now = Date().timeIntervalSince1970
        guard now - lastRun >= Self.backgroundBackfillInterval else { return }

        UserDefaults.standard.set(now, forKey: Self.lastBackfillKey)
        await backfillOutcomes(context: context)
        debugPrint("V2OutcomeLearningStore: background backfill completed")
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
    /// Learn personal curve parameters from completed outcomes.
    ///
    /// Error model: target-based with dead zone (critique item #1).
    /// Instead of the original 70–180 dead zone (which produced zero learning signal for
    /// a user consistently landing at 170), errors are computed relative to a configurable
    /// target BG (default 110) with a ±deadZone band (default ±30 → 80–140).
    /// BG values inside the dead zone produce zero error; values outside produce a
    /// proportional signal relative to the target, not the dead-zone edge.
    func recalculateCurveParameters(
        targetBG: Int = 110,
        deadZone: Int = 30,
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

                // Target-based error with dead zone (critique item #1).
                // A user landing at 170 now produces a learning signal (+0.60)
                // instead of being silently ignored by the old 70–180 band.
                let error: Double
                let deadZoneLow = targetBG - deadZone  // default 80
                let deadZoneHigh = targetBG + deadZone  // default 140
                if bg > deadZoneHigh {
                    error = Double(bg - targetBG) / 100.0 // positive = under-dosed, relative to target
                } else if bg < deadZoneLow {
                    error = -Double(targetBG - bg) / 100.0 // negative = over-dosed, relative to target
                } else {
                    continue // within dead zone around target, no adjustment needed
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
                    // Critique item #3: The 4h overlap checkpoint distributes error at 30%
                    // weight to all three curves, producing noise-level adjustments (e.g.,
                    // 0.003 to protein factor per 100 mg/dL). The 5h and 6h checkpoints
                    // provide cleaner single-curve signal for protein and fat respectively.
                    // Treating overlap as .skip for learning eliminates parameter coupling
                    // with no meaningful loss of information.
                    break

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

        saveParametersWithHistory(params, source: "learning")
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

        // Capture Garmin per-metric contributions at meal time (critique item #10)
        // so exports reflect the weights that were active when dosing occurred.
        let contributions: [V2GarminContribution]? = garminSnapshot.map { _ in
            GarminSensitivityModel.computeDemandFactor(from: garminSnapshot).contributions.map {
                V2GarminContribution(metric: $0.metric, value: $0.value,
                                     impact: $0.impact, description: $0.description)
            }
        }

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
            garminContributions: contributions,
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
    func exportForRecalibration(lastDays: Int = 14) -> V2RecalibrationExport {
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

            // Use stored contributions if available (critique item #10); fall back to
            // re-derivation for legacy outcomes recorded before contributions were stored.
            let garminContributions: [V2GarminContribution]
            if let stored = outcome.garminContributions {
                garminContributions = stored
            } else {
                let garminResult = GarminSensitivityModel.computeDemandFactor(from: outcome.garminSnapshot)
                garminContributions = garminResult.contributions.map {
                    V2GarminContribution(
                        metric: $0.metric,
                        value: $0.value,
                        impact: $0.impact,
                        description: $0.description
                    )
                }
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

            // Fetch insulin delivery during the absorption window: boluses + temp basals
            let bolusEvents = await fetchBolusEvents(
                from: outcome.date,
                to: min(postMealEnd, Date()),
                context: context
            )

            let tempBasalEvents = await fetchTempBasalEvents(
                from: outcome.date,
                to: min(postMealEnd, Date()),
                context: context
            )

            // Fetch oref loop decisions during the absorption window
            let loopDecisions = await fetchLoopDecisions(
                from: outcome.date,
                to: min(postMealEnd, Date()),
                context: context
            )

            let record = V2MealExportRecord(
                outcome: outcome,
                preMealBGTrace: preMealBG,
                postMealBGTrace: postMealBG,
                scheduledEntries: scheduled,
                garminContributions: garminContributions,
                dosingSummary: dosingSummary,
                bolusEvents: bolusEvents,
                tempBasalEvents: tempBasalEvents,
                loopDecisions: loopDecisions
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

    /// Fetch all bolus events (manual + SMB) in a time range.
    private func fetchBolusEvents(
        from start: Date,
        to end: Date,
        context: NSManagedObjectContext
    ) async -> [V2BolusEvent] {
        await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "BolusStored")
            request.predicate = NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                start as NSDate,
                end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "pumpEvent.timestamp", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }

            return results.compactMap { bolus -> V2BolusEvent? in
                guard let pumpEvent = bolus.value(forKey: "pumpEvent") as? NSManagedObject,
                      let timestamp = pumpEvent.value(forKey: "timestamp") as? Date
                else { return nil }

                let amount = (bolus.value(forKey: "amount") as? NSDecimalNumber)?.doubleValue ?? 0
                guard amount > 0 else { return nil }

                return V2BolusEvent(
                    date: timestamp,
                    amount: amount,
                    isSMB: bolus.value(forKey: "isSMB") as? Bool ?? false,
                    isExternal: bolus.value(forKey: "isExternal") as? Bool ?? false
                )
            }
        }
    }

    /// Fetch all temp basal events in a time range.
    private func fetchTempBasalEvents(
        from start: Date,
        to end: Date,
        context: NSManagedObjectContext
    ) async -> [V2TempBasalEvent] {
        await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "TempBasalStored")
            request.predicate = NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                start as NSDate,
                end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "pumpEvent.timestamp", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }

            return results.compactMap { tb -> V2TempBasalEvent? in
                guard let pumpEvent = tb.value(forKey: "pumpEvent") as? NSManagedObject,
                      let timestamp = pumpEvent.value(forKey: "timestamp") as? Date
                else { return nil }

                let rate = (tb.value(forKey: "rate") as? NSDecimalNumber)?.doubleValue ?? 0
                let duration = (tb.value(forKey: "duration") as? Int16) ?? 0

                return V2TempBasalEvent(
                    date: timestamp,
                    rate: rate,
                    duration: Int(duration)
                )
            }
        }
    }

    /// Fetch oref loop decisions in a time range.
    /// Each decision represents one loop cycle (~5 min) with the loop's state and actions.
    private func fetchLoopDecisions(
        from start: Date,
        to end: Date,
        context: NSManagedObjectContext
    ) async -> [V2LoopDecision] {
        await context.perform {
            let request = OrefDetermination.fetchRequest()
            request.predicate = NSPredicate(
                format: "deliverAt >= %@ AND deliverAt <= %@",
                start as NSDate,
                end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }

            return results.compactMap { det -> V2LoopDecision? in
                guard let date = det.deliverAt else { return nil }

                // Truncate reason string to avoid bloating the export
                let reason = det.reason.map { String($0.prefix(200)) }

                return V2LoopDecision(
                    date: date,
                    glucose: Int((det.glucose ?? 0).doubleValue),
                    iob: (det.iob ?? 0).doubleValue,
                    cob: Int(det.cob),
                    eventualBG: Int((det.eventualBG ?? 0).doubleValue),
                    insulinReq: (det.insulinReq ?? 0).doubleValue,
                    smbToDeliver: (det.smbToDeliver ?? 0).doubleValue,
                    tempBasalRate: det.rate?.doubleValue,
                    scheduledBasal: (det.scheduledBasal ?? 0).doubleValue,
                    sensitivityRatio: (det.sensitivityRatio ?? 1).doubleValue,
                    reason: reason
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

/// A bolus event (manual or SMB) delivered during the meal's absorption window.
struct V2BolusEvent: Codable {
    let date: Date
    let amount: Double          // insulin units
    let isSMB: Bool             // true = automatic SMB from oref
    let isExternal: Bool        // true = pen injection (not pump)
}

/// A temp basal rate change during the meal's absorption window.
struct V2TempBasalEvent: Codable {
    let date: Date
    let rate: Double            // units per hour
    let duration: Int           // minutes
}

/// An oref loop decision during the meal's absorption window.
/// Shows what the loop "saw" and decided at each cycle (~5 min intervals).
struct V2LoopDecision: Codable {
    let date: Date
    let glucose: Int            // current BG (mg/dL)
    let iob: Double             // insulin on board (units)
    let cob: Int                // carbs on board (grams)
    let eventualBG: Int         // oref's predicted eventual BG
    let insulinReq: Double      // insulin oref calculated as needed
    let smbToDeliver: Double    // SMB oref decided to deliver
    let tempBasalRate: Double?  // temp basal rate set (nil if unchanged)
    let scheduledBasal: Double  // scheduled basal rate for context
    let sensitivityRatio: Double // autosens ratio
    let reason: String?         // oref's reasoning string (truncated)
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

    // All bolus events during the 8h absorption window — manual boluses + oref SMBs.
    // Shows when and how much insulin the loop actually delivered.
    let bolusEvents: [V2BolusEvent]

    // Temp basal rate changes during the 8h absorption window.
    // Shows how the loop modulated basal delivery in response to the meal.
    let tempBasalEvents: [V2TempBasalEvent]

    // Oref loop decisions during the 8h absorption window (~5 min intervals).
    // Shows what the loop "saw" (IOB, COB, eventualBG) and decided at each cycle.
    let loopDecisions: [V2LoopDecision]
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
