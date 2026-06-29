import CoreData
import Foundation
import Swinject

/// CRUD + history-cap operations for SavedMeal / SavedMealInstance.
/// See docs/MEAL_INTELLIGENCE_DESIGN.md §3 for the data model.
///
/// All operations run on `CoreDataStack.shared.newTaskContext()` for writes
/// and `viewContext` for reads-returning-to-UI. UI views fetch via
/// @FetchRequest directly when possible; this service is for the
/// programmatic write paths (activation, window close, settings CRUD).
protocol SavedMealStorage {
    func allMeals() -> [SavedMeal]
    func meal(id: UUID) -> SavedMeal?
    func instance(forWindowId windowId: String) -> SavedMealInstance?
    /// Permanently delete one instance row. Refreshes the parent meal's
    /// cachedInstanceCount and pushes a fresh definitions snapshot.
    func deleteInstance(id: UUID)
    @discardableResult
    func createMeal(name: String, icon: String) -> SavedMeal
    func updateMeal(_ meal: SavedMeal, applying changes: (SavedMeal) -> Void)
    func deleteMeal(_ meal: SavedMeal)
    func duplicateMeal(_ meal: SavedMeal) -> SavedMeal

    /// Called when the user picks a saved meal to start a new window.
    /// Creates an instance row linked to the window and returns the instance id.
    /// When the caller has actual entered macros (e.g. from the Treatments
    /// picker after user edited the fields), pass them as overrides — they
    /// take precedence over the SavedMeal's defaults so the instance reflects
    /// what was really eaten this time.
    @discardableResult
    func startInstance(
        meal: SavedMeal,
        windowId: String,
        startedAt: Date,
        actualCarbs: Decimal?,
        actualFat: Decimal?,
        actualProtein: Decimal?,
        bgAtActivation: Double?,
        bgTrendAtActivation: Double?,
        autosensRatio: Double?,
        smartSenseRatio: Double?,
        effectiveISF: Double?,
        carbRatio: Double?
    ) -> UUID

    /// Called when a meal window closes. Backfills instance fields with the
    /// computed outcome and trims the per-meal history to the cap (20).
    func closeInstance(
        instanceId: UUID,
        closedAt: Date,
        finalClassification: MealClassification,
        bgCurveJSON: String?,
        smbsJSON: String?,
        floorActivationsJSON: String?,
        classifierUpgradesJSON: String?,
        outcomeScore: Int,
        metrics: SavedMealInstanceMetrics
    )
}

struct SavedMealInstanceMetrics {
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

final class BaseSavedMealStorage: SavedMealStorage, Injectable {
    /// Holds the resolver so we can lazily look up the telemetry manager when
    /// it's actually needed. We can't `@Injected` it directly because
    /// AlgorithmTelemetryManager also injects SavedMealStorage — eager
    /// resolution at init() time recurses and crashes the app at launch.
    private let resolver: Resolver

    private let context: NSManagedObjectContext
    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    /// Maximum instances kept per meal locally. Older instances are removed
    /// from CoreData but already-uploaded telemetry rows on the remote branch
    /// remain (append-only). Matches MEAL_INTELLIGENCE_DESIGN.md §3 cap.
    private let perMealHistoryCap = 20

    init(resolver: Resolver, context: NSManagedObjectContext? = nil) {
        self.resolver = resolver
        self.context = context ?? CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
    }

    /// Forwards a definitions snapshot to telemetry so meals/definitions.json
    /// stays in sync with local CoreData. Called after every CRUD action.
    /// Resolved lazily — see init comment for why we can't @Injected this.
    private func notifyDefinitionsChanged() {
        resolver.resolve(AlgorithmTelemetryManager.self)?.emitMealDefinitionsSnapshot()
    }

    // MARK: - Read

    func allMeals() -> [SavedMeal] {
        var results: [SavedMeal] = []
        viewContext.performAndWait {
            let req = SavedMeal.fetchRequest()
            req.sortDescriptors = [
                NSSortDescriptor(key: "cachedInstanceCount", ascending: false),
                NSSortDescriptor(key: "updatedAt", ascending: false)
            ]
            results = (try? viewContext.fetch(req)) ?? []
        }
        return results
    }

    func meal(id: UUID) -> SavedMeal? {
        var found: SavedMeal?
        viewContext.performAndWait {
            let req = SavedMeal.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            found = (try? viewContext.fetch(req))?.first
        }
        return found
    }

    func instance(forWindowId windowId: String) -> SavedMealInstance? {
        var found: SavedMealInstance?
        viewContext.performAndWait {
            let req = SavedMealInstance.fetchRequest()
            req.predicate = NSPredicate(format: "windowId == %@", windowId)
            req.fetchLimit = 1
            found = (try? viewContext.fetch(req))?.first
        }
        return found
    }

    func deleteInstance(id: UUID) {
        context.performAndWait {
            let req = SavedMealInstance.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            guard let inst = (try? context.fetch(req))?.first else { return }
            let parent = inst.savedMeal
            context.delete(inst)
            // Refresh parent's cached count.
            if let parent {
                let remaining = (parent.instances?.allObjects as? [SavedMealInstance]) ?? []
                parent.cachedInstanceCount = Int32(
                    remaining.filter { $0 != inst && $0.closedAt != nil }.count
                )
                parent.updatedAt = Date()
            }
            try? context.save()
        }
        notifyDefinitionsChanged()
    }

    // MARK: - Meal CRUD

    @discardableResult
    func createMeal(name: String, icon: String) -> SavedMeal {
        var created: SavedMeal!
        context.performAndWait {
            let meal = SavedMeal(context: context)
            meal.id = UUID()
            meal.name = name
            meal.icon = icon
            let now = Date()
            meal.createdAt = now
            meal.updatedAt = now
            meal.cachedInstanceCount = 0
            try? context.save()
            created = meal
        }
        notifyDefinitionsChanged()
        return forwardToView(created)
    }

    func updateMeal(_ meal: SavedMeal, applying changes: (SavedMeal) -> Void) {
        context.performAndWait {
            // Re-fetch in the write context to mutate safely
            guard let id = meal.id,
                  let writable = fetchMealInWriteContext(id: id) else { return }
            changes(writable)
            writable.updatedAt = Date()
            try? context.save()
        }
        notifyDefinitionsChanged()
    }

    func deleteMeal(_ meal: SavedMeal) {
        context.performAndWait {
            guard let id = meal.id,
                  let writable = fetchMealInWriteContext(id: id) else { return }
            context.delete(writable)
            try? context.save()
        }
        notifyDefinitionsChanged()
    }

    func duplicateMeal(_ meal: SavedMeal) -> SavedMeal {
        var created: SavedMeal!
        context.performAndWait {
            guard let id = meal.id,
                  let source = fetchMealInWriteContext(id: id) else {
                created = meal  // fallback shouldn't happen
                return
            }
            let copy = SavedMeal(context: context)
            copy.id = UUID()
            copy.name = (source.name ?? "Meal") + " (copy)"
            copy.icon = source.icon
            let now = Date()
            copy.createdAt = now
            copy.updatedAt = now
            copy.cachedInstanceCount = 0
            copy.defaultCarbs = source.defaultCarbs
            copy.defaultFat = source.defaultFat
            copy.defaultProtein = source.defaultProtein
            copy.defaultClassification = source.defaultClassification
            copy.defaultExtendedDurationMinutes = source.defaultExtendedDurationMinutes
            copy.defaultPhantomCOBEnabled = source.defaultPhantomCOBEnabled
            copy.defaultPhantomCOBGrams = source.defaultPhantomCOBGrams
            try? context.save()
            created = copy
        }
        notifyDefinitionsChanged()
        return forwardToView(created)
    }

    // MARK: - Instance lifecycle

    @discardableResult
    func startInstance(
        meal: SavedMeal,
        windowId: String,
        startedAt: Date,
        actualCarbs: Decimal? = nil,
        actualFat: Decimal? = nil,
        actualProtein: Decimal? = nil,
        bgAtActivation: Double? = nil,
        bgTrendAtActivation: Double? = nil,
        autosensRatio: Double? = nil,
        smartSenseRatio: Double? = nil,
        effectiveISF: Double? = nil,
        carbRatio: Double? = nil,
        garminContextJSON: String? = nil,
        pumpSiteAgeHours: Double? = nil
    ) -> UUID {
        let instanceId = UUID()
        context.performAndWait {
            guard let mealId = meal.id,
                  let mealInCtx = fetchMealInWriteContext(id: mealId) else { return }
            let inst = SavedMealInstance(context: context)
            inst.id = instanceId
            inst.windowId = windowId
            inst.startedAt = startedAt
            // Actual entered macros take precedence; fall back to meal defaults
            // when not supplied (e.g. zero-entry Action Button flow).
            inst.carbsAtActivation = actualCarbs.map(NSDecimalNumber.init(decimal:)) ?? mealInCtx.defaultCarbs
            inst.fatAtActivation = actualFat.map(NSDecimalNumber.init(decimal:)) ?? mealInCtx.defaultFat
            inst.proteinAtActivation = actualProtein.map(NSDecimalNumber.init(decimal:)) ?? mealInCtx.defaultProtein
            inst.initialClassification = mealInCtx.defaultClassification ?? MealClassification.simple.rawValue
            inst.carbBucketSource = (actualCarbs != nil || mealInCtx.defaultCarbs != nil) ? "macros" : "inferred"
            inst.bgAtActivation = bgAtActivation.map(NSDecimalNumber.init(value:))
            inst.bgTrendAtActivation = bgTrendAtActivation.map(NSDecimalNumber.init(value:))
            inst.autosensRatioAtActivation = autosensRatio.map(NSDecimalNumber.init(value:))
            inst.smartSenseRatioAtActivation = smartSenseRatio.map(NSDecimalNumber.init(value:))
            inst.effectiveISFAtActivation = effectiveISF.map(NSDecimalNumber.init(value:))
            inst.carbRatioAtActivation = carbRatio.map(NSDecimalNumber.init(value:))
            inst.garminContextAtActivationJSON = garminContextJSON
            inst.pumpSiteAgeHours = pumpSiteAgeHours.map { NSNumber(value: $0) }
            mealInCtx.addToInstances(inst)
            mealInCtx.updatedAt = startedAt
            try? context.save()
        }
        return instanceId
    }

    func closeInstance(
        instanceId: UUID,
        closedAt: Date,
        finalClassification: MealClassification,
        bgCurveJSON: String?,
        smbsJSON: String?,
        floorActivationsJSON: String?,
        classifierUpgradesJSON: String?,
        outcomeScore: Int,
        metrics: SavedMealInstanceMetrics
    ) {
        context.performAndWait {
            guard let inst = fetchInstanceInWriteContext(id: instanceId) else { return }
            inst.closedAt = closedAt
            inst.finalClassification = finalClassification.rawValue
            inst.bgCurveJSON = bgCurveJSON
            inst.smbsJSON = smbsJSON
            inst.floorActivationsJSON = floorActivationsJSON
            inst.classifierUpgradesJSON = classifierUpgradesJSON
            inst.outcomeScore = Int32(outcomeScore)
            inst.peakBG = metrics.peakBG
            inst.timeInRangeMinutes = Int32(metrics.timeInRangeMinutes)
            inst.timeAboveRangeMinutes = Int32(metrics.timeAboveRangeMinutes)
            inst.timeBelowRangeMinutes = Int32(metrics.timeBelowRangeMinutes)
            inst.lowsCount = Int32(metrics.lowsCount)
            inst.timeToBaselineMinutes = Int32(metrics.timeToBaselineMinutes)
            inst.totalInsulinDeliveredU = metrics.totalInsulinDeliveredU
            inst.smbCount = Int32(metrics.smbCount)
            inst.floorActivationCount = Int32(metrics.floorActivationCount)

            // Refresh parent meal's cached stats + prune to history cap.
            if let meal = inst.savedMeal {
                let allInstances = (meal.instances?.allObjects as? [SavedMealInstance]) ?? []
                let closed = allInstances.filter { $0.closedAt != nil }
                meal.cachedInstanceCount = Int32(closed.count)
                meal.cachedRecommendedClassification = recommendDefaultClassification(from: closed)
                meal.updatedAt = closedAt
                pruneExcessInstances(meal: meal)
            }
            try? context.save()
        }
    }

    // MARK: - Internals

    /// Look up by id in the WRITE context (different MOC from viewContext).
    private func fetchMealInWriteContext(id: UUID) -> SavedMeal? {
        let req = SavedMeal.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    private func fetchInstanceInWriteContext(id: UUID) -> SavedMealInstance? {
        let req = SavedMealInstance.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    /// Bridges a write-context object to the view context for UI consumption.
    /// Returns the same object instance fetched via the viewContext, which
    /// is safe to read from MainActor.
    private func forwardToView(_ obj: SavedMeal) -> SavedMeal {
        var found: SavedMeal?
        viewContext.performAndWait {
            guard let id = obj.id else { return }
            let req = SavedMeal.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            found = (try? viewContext.fetch(req))?.first
        }
        return found ?? obj
    }

    /// Recommends the most common classification from closed instances.
    /// Returns nil for meals with <3 closed instances (not enough data).
    private func recommendDefaultClassification(from instances: [SavedMealInstance]) -> String? {
        guard instances.count >= 3 else { return nil }
        let counts = instances.reduce(into: [String: Int]()) { acc, inst in
            if let c = inst.finalClassification { acc[c, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// Removes the oldest instances when the cap is exceeded.
    /// Only deletes CLOSED instances — open ones (no closedAt) are spared.
    private func pruneExcessInstances(meal: SavedMeal) {
        guard let all = meal.instances?.allObjects as? [SavedMealInstance] else { return }
        let closed = all.filter { $0.closedAt != nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        guard closed.count > perMealHistoryCap else { return }
        let toDelete = closed.dropFirst(perMealHistoryCap)
        for inst in toDelete {
            context.delete(inst)
        }
    }
}
