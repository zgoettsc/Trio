import CoreData
import Foundation

// MARK: - Data Models

/// A single BG checkpoint measured at a specific interval after a meal recommendation
struct BGCheckpoint: Codable {
    let hoursAfterMeal: Int // 2, 4, 6, 8, or 10
    var bgValue: Int? // mg/dL, nil if not yet measured
    var isClean: Bool // No confounding meals detected before this checkpoint
    var confoundingMealTime: Date? // When the first confounding meal was detected (if any)
}

/// A meal detected after the recommendation was applied (confounding event)
struct SubsequentMealEvent: Codable {
    let detectedAt: Date
    let hoursAfterRecommendation: Double
    let carbs: Double
    let fat: Double
    let protein: Double
    let source: String // "Trio" or "Cronometer"
}

/// A logged Cronometer meal recommendation with outcome tracking
struct CronometerMealRecommendation: Codable, Identifiable {
    let id: UUID
    let date: Date // When the recommendation was applied

    // What Cronometer reported (actual nutrition)
    let cronometerCarbs: Double
    let cronometerFat: Double
    let cronometerProtein: Double
    let cronometerCalories: Double

    // What was recommended to enter
    let recommendedCarbs: Double
    let recommendedFat: Double
    let recommendedProtein: Double

    // What the user actually entered (after potential manual adjustments)
    let appliedCarbs: Double
    let appliedFat: Double
    let appliedProtein: Double

    // Dosing context
    let bgAtMeal: Int // BG when recommendation was applied
    let carbRatioAtMeal: Double
    let isfAtMeal: Double
    let adjustmentFactor: Double // The personal factor used for this recommendation

    // Simulation predictions at time of recommendation
    let predictedEventualBG: Int?
    let predictedMinBG: Int?

    // BG Outcomes (filled in over time via backfill)
    var checkpoints: [BGCheckpoint]

    // Confounding events detected in the observation window
    var subsequentMeals: [SubsequentMealEvent]

    // Computed: outcome quality metrics
    var isComplete: Bool {
        // Complete when we have BG data for at least the 2h and 4h checkpoints
        let earlyCheckpoints = checkpoints.filter { $0.hoursAfterMeal <= 4 }
        return earlyCheckpoints.allSatisfy { $0.bgValue != nil }
    }

    var hasCleanEarlyWindow: Bool {
        // First 4 hours have no confounding meals
        checkpoints.filter { $0.hoursAfterMeal <= 4 }.allSatisfy { $0.isClean }
    }

    var peakBG: Int? {
        checkpoints.compactMap { $0.bgValue }.max()
    }

    var nadirBG: Int? {
        checkpoints.compactMap { $0.bgValue }.min()
    }

    /// How well did BG stay in range? Returns fraction of clean checkpoints in range (70-180)
    func inRangeScore(targetLow: Int = 70, targetHigh: Int = 180) -> Double? {
        let cleanWithValues = checkpoints.filter { $0.isClean && $0.bgValue != nil }
        guard !cleanWithValues.isEmpty else { return nil }
        let inRange = cleanWithValues.filter { $0.bgValue! >= targetLow && $0.bgValue! <= targetHigh }
        return Double(inRange.count) / Double(cleanWithValues.count)
    }

    /// Create a new recommendation with empty checkpoints
    static func create(
        cronometerCarbs: Double,
        cronometerFat: Double,
        cronometerProtein: Double,
        recommendedCarbs: Double,
        recommendedFat: Double,
        recommendedProtein: Double,
        appliedCarbs: Double,
        appliedFat: Double,
        appliedProtein: Double,
        bgAtMeal: Int,
        carbRatioAtMeal: Double,
        isfAtMeal: Double,
        adjustmentFactor: Double,
        predictedEventualBG: Int?,
        predictedMinBG: Int?
    ) -> CronometerMealRecommendation {
        let calories = cronometerCarbs * 4 + cronometerFat * 9 + cronometerProtein * 4
        return CronometerMealRecommendation(
            id: UUID(),
            date: Date(),
            cronometerCarbs: cronometerCarbs,
            cronometerFat: cronometerFat,
            cronometerProtein: cronometerProtein,
            cronometerCalories: calories,
            recommendedCarbs: recommendedCarbs,
            recommendedFat: recommendedFat,
            recommendedProtein: recommendedProtein,
            appliedCarbs: appliedCarbs,
            appliedFat: appliedFat,
            appliedProtein: appliedProtein,
            bgAtMeal: bgAtMeal,
            carbRatioAtMeal: carbRatioAtMeal,
            isfAtMeal: isfAtMeal,
            adjustmentFactor: adjustmentFactor,
            predictedEventualBG: predictedEventualBG,
            predictedMinBG: predictedMinBG,
            checkpoints: [
                BGCheckpoint(hoursAfterMeal: 2, bgValue: nil, isClean: true, confoundingMealTime: nil),
                BGCheckpoint(hoursAfterMeal: 4, bgValue: nil, isClean: true, confoundingMealTime: nil),
                BGCheckpoint(hoursAfterMeal: 6, bgValue: nil, isClean: true, confoundingMealTime: nil),
                BGCheckpoint(hoursAfterMeal: 8, bgValue: nil, isClean: true, confoundingMealTime: nil),
                BGCheckpoint(hoursAfterMeal: 10, bgValue: nil, isClean: true, confoundingMealTime: nil),
            ],
            subsequentMeals: []
        )
    }
}

/// Summary statistics for Cronometer recommendation outcomes
struct CronometerOutcomeStats {
    let totalApplied: Int
    let completedCount: Int
    let inRangeCount: Int
    let averagePeakBG: Int?
    let cleanWindowCount: Int
}

// MARK: - Recommendation Store

/// Persistent store for Cronometer meal recommendations with outcome tracking and factor learning
final class CronometerRecommendationStore {
    static let shared = CronometerRecommendationStore()

    private let storageKey = "CronometerRecommendations"
    private let factorKey = "CronometerPersonalFactor"
    private let retentionDays = 90

    private init() {}

    // MARK: - Storage

    func save(_ recommendation: CronometerMealRecommendation) {
        var all = loadAll()
        all.append(recommendation)
        persist(all)
    }

    func loadAll() -> [CronometerMealRecommendation] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        do {
            var recommendations = try JSONDecoder().decode([CronometerMealRecommendation].self, from: data)
            // Prune old entries
            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
            recommendations = recommendations.filter { $0.date >= cutoff }
            return recommendations.sorted { $0.date < $1.date }
        } catch {
            debugPrint("CronometerRecommendationStore: Failed to decode recommendations: \(error)")
            return []
        }
    }

    func update(_ recommendation: CronometerMealRecommendation) {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == recommendation.id }) {
            all[index] = recommendation
            persist(all)
        }
    }

    /// Get recommendations that need BG outcome backfill
    func pendingOutcomes() -> [CronometerMealRecommendation] {
        loadAll().filter { rec in
            // Needs backfill if any checkpoint is missing BG and enough time has passed
            let now = Date()
            return rec.checkpoints.contains { checkpoint in
                guard checkpoint.bgValue == nil else { return false }
                let checkpointTime = rec.date.addingTimeInterval(TimeInterval(checkpoint.hoursAfterMeal * 3600))
                // Allow 30 minutes of grace after the checkpoint time
                return now > checkpointTime.addingTimeInterval(30 * 60)
            }
        }
    }

    /// Get completed recommendations (at least 2h and 4h BG available)
    func completedRecommendations() -> [CronometerMealRecommendation] {
        loadAll().filter { $0.isComplete }
    }

    private func persist(_ recommendations: [CronometerMealRecommendation]) {
        do {
            let data = try JSONEncoder().encode(recommendations)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            debugPrint("CronometerRecommendationStore: Failed to encode recommendations: \(error)")
        }
    }

    // MARK: - Personal Adjustment Factor

    /// Get the current personal adjustment factor (how much of Cronometer carbs to enter)
    /// Returns a value between 0.2 and 1.5. Default is 0.5 if no history.
    func personalAdjustmentFactor() -> Double {
        // Check for manually saved factor override
        if UserDefaults.standard.object(forKey: factorKey) != nil {
            return UserDefaults.standard.double(forKey: factorKey)
        }
        // Calculate from history or return default
        return calculateFactorFromHistory() ?? 0.5
    }

    /// Save a manually adjusted factor
    func savePersonalFactor(_ factor: Double) {
        let clamped = max(0.2, min(1.5, factor))
        UserDefaults.standard.set(clamped, forKey: factorKey)
    }

    /// Recalculate the personal factor from recommendation outcomes
    /// This is the learning algorithm.
    func recalculateFactorFromOutcomes(targetLow: Int = 70, targetHigh: Int = 180) -> Double {
        let completed = completedRecommendations()
        guard !completed.isEmpty else { return personalAdjustmentFactor() }

        var currentFactor = personalAdjustmentFactor()

        // Process each completed recommendation, weighted by recency
        let now = Date()
        var totalWeight = 0.0
        var totalAdjustment = 0.0

        for rec in completed {
            // Only learn from recommendations with clean early windows
            guard rec.hasCleanEarlyWindow else { continue }

            // Recency weight: more recent = more weight
            let ageInDays = now.timeIntervalSince(rec.date) / 86400
            let recencyWeight = max(0.1, 1.0 - (ageInDays / Double(retentionDays)))

            // Analyze clean checkpoints to determine needed adjustment
            let cleanCheckpoints = rec.checkpoints.filter { $0.isClean && $0.bgValue != nil }
            guard !cleanCheckpoints.isEmpty else { continue }

            // Weight checkpoints: earlier ones are more reliable (less confounding)
            let checkpointWeights: [Int: Double] = [2: 1.0, 4: 1.0, 6: 0.7, 8: 0.4, 10: 0.2]

            var checkpointAdjustment = 0.0
            var checkpointTotalWeight = 0.0

            for cp in cleanCheckpoints {
                guard let bg = cp.bgValue, let cpWeight = checkpointWeights[cp.hoursAfterMeal] else { continue }

                let adjustment: Double
                if bg > targetHigh {
                    // BG too high → need more insulin → increase factor
                    let overshoot = Double(bg - targetHigh)
                    adjustment = 0.02 * (overshoot / 100.0)
                } else if bg < targetLow {
                    // BG too low → need less insulin → decrease factor
                    let undershoot = Double(targetLow - bg)
                    adjustment = -0.02 * (undershoot / 100.0)
                } else {
                    adjustment = 0 // In range, no adjustment needed
                }

                checkpointAdjustment += adjustment * cpWeight
                checkpointTotalWeight += cpWeight
            }

            if checkpointTotalWeight > 0 {
                let weightedAdj = checkpointAdjustment / checkpointTotalWeight
                totalAdjustment += weightedAdj * recencyWeight
                totalWeight += recencyWeight
            }
        }

        if totalWeight > 0 {
            let avgAdjustment = totalAdjustment / totalWeight
            currentFactor += avgAdjustment
            currentFactor = max(0.2, min(1.5, currentFactor))
            savePersonalFactor(currentFactor)
        }

        return currentFactor
    }

    /// Calculate initial factor from historical data (before any recommendations exist)
    private func calculateFactorFromHistory() -> Double? {
        // Uses the nutrition analysis estimation ratio if available
        // This is: average(trioCarbs / cronometerCarbs)
        // If the user has been entering 50g when eating 100g, this would be ~0.5
        // We'll try to get this from UserDefaults where NutritionAnalysisService may have stored it
        let key = "NutritionAverageEstimationRatio"
        if UserDefaults.standard.object(forKey: key) != nil {
            let ratio = UserDefaults.standard.double(forKey: key)
            if ratio > 0.1, ratio < 2.0 {
                return max(0.2, min(1.5, ratio))
            }
        }
        return nil
    }

    // MARK: - Outcome Backfill

    /// Backfill BG outcomes for pending recommendations using glucose data from CoreData
    func backfillOutcomes(context: NSManagedObjectContext) async {
        let pending = pendingOutcomes()
        guard !pending.isEmpty else { return }

        for var rec in pending {
            var updated = false

            for i in 0 ..< rec.checkpoints.count {
                guard rec.checkpoints[i].bgValue == nil else { continue }

                let hoursAfter = rec.checkpoints[i].hoursAfterMeal
                let targetTime = rec.date.addingTimeInterval(TimeInterval(hoursAfter * 3600))
                let now = Date()

                // Only backfill if enough time has passed
                guard now > targetTime.addingTimeInterval(30 * 60) else { continue }

                // Find closest glucose reading within 30 minutes of the target time
                if let bg = await fetchClosestGlucose(near: targetTime, withinMinutes: 30, context: context) {
                    rec.checkpoints[i].bgValue = bg
                    updated = true
                }
            }

            // Detect confounding meals (Trio entries or Cronometer snapshots in the window)
            let confoundingMeals = await detectConfoundingMeals(after: rec.date, context: context)
            if !confoundingMeals.isEmpty {
                rec.subsequentMeals = confoundingMeals

                // Mark checkpoints after the first confounding meal as not clean
                if let firstConfounding = confoundingMeals.min(by: { $0.detectedAt < $1.detectedAt }) {
                    for i in 0 ..< rec.checkpoints.count {
                        let checkpointTime = rec.date
                            .addingTimeInterval(TimeInterval(rec.checkpoints[i].hoursAfterMeal * 3600))
                        if checkpointTime > firstConfounding.detectedAt {
                            rec.checkpoints[i].isClean = false
                            rec.checkpoints[i].confoundingMealTime = firstConfounding.detectedAt
                        }
                    }
                }
                updated = true
            }

            if updated {
                update(rec)
            }
        }
    }

    /// Find the closest glucose reading to a target time
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

            // Find the reading closest to the target time
            let closest = results.min { a, b in
                guard let dateA = a.date, let dateB = b.date else { return false }
                return abs(dateA.timeIntervalSince(targetTime)) < abs(dateB.timeIntervalSince(targetTime))
            }

            return closest.map { Int($0.glucose) }
        }
    }

    /// Detect meals eaten after a recommendation was applied (confounding events)
    private func detectConfoundingMeals(
        after startDate: Date,
        context: NSManagedObjectContext
    ) async -> [SubsequentMealEvent] {
        var events: [SubsequentMealEvent] = []
        let endDate = startDate.addingTimeInterval(10 * 3600) // 10 hour window

        // 1. Check Trio carb entries (non-FPU, non-zero carbs)
        let trioMeals = await fetchTrioCarbEntries(from: startDate, to: endDate, context: context)
        for meal in trioMeals {
            let hoursAfter = meal.date.timeIntervalSince(startDate) / 3600
            // Skip entries within 15 minutes of the recommendation (part of the same meal)
            guard hoursAfter > 0.25 else { continue }
            events.append(SubsequentMealEvent(
                detectedAt: meal.date,
                hoursAfterRecommendation: hoursAfter,
                carbs: meal.carbs,
                fat: meal.fat,
                protein: meal.protein,
                source: "Trio"
            ))
        }

        // 2. Check Cronometer inferred meals from snapshots
        let cronometerMeals = NutritionSnapshotStore.shared.inferredMealEvents(forLastHours: 12)
        for meal in cronometerMeals {
            guard meal.detectedAt > startDate, meal.detectedAt <= endDate else { continue }
            let hoursAfter = meal.detectedAt.timeIntervalSince(startDate) / 3600
            guard hoursAfter > 0.25 else { continue }
            // Avoid duplicates with Trio entries (if within 30 min of a Trio entry, skip)
            let isDuplicate = events.contains { abs($0.detectedAt.timeIntervalSince(meal.detectedAt)) < 1800 }
            guard !isDuplicate else { continue }
            events.append(SubsequentMealEvent(
                detectedAt: meal.detectedAt,
                hoursAfterRecommendation: hoursAfter,
                carbs: meal.carbsDelta,
                fat: meal.fatDelta,
                protein: meal.proteinDelta,
                source: "Cronometer"
            ))
        }

        return events.sorted { $0.detectedAt < $1.detectedAt }
    }

    /// Fetch Trio carb entries in a date range
    private func fetchTrioCarbEntries(
        from startDate: Date,
        to endDate: Date,
        context: NSManagedObjectContext
    ) async -> [(date: Date, carbs: Double, fat: Double, protein: Double)] {
        await context.perform {
            let request = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@ AND isFPU == NO AND carbs > 0",
                startDate as NSDate,
                endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }
            return results.compactMap { entry in
                guard let date = entry.date else { return nil }
                return (date: date, carbs: entry.carbs, fat: entry.fat, protein: entry.protein)
            }
        }
    }

    // MARK: - Statistics for UI

    /// Summary stats for display in the recommendation view
    func outcomeStats(targetLow: Int = 70, targetHigh: Int = 180) -> CronometerOutcomeStats {
        let all = loadAll()
        let completed = all.filter { $0.isComplete }
        let inRange = completed.filter { rec in
            guard let score = rec.inRangeScore(targetLow: targetLow, targetHigh: targetHigh) else { return false }
            return score >= 0.5 // At least half of clean checkpoints in range
        }
        let cleanCompleted = completed.filter { $0.hasCleanEarlyWindow }

        let avgPeak: Int? = {
            let peaks = completed.compactMap { $0.peakBG }
            guard !peaks.isEmpty else { return nil }
            return peaks.reduce(0, +) / peaks.count
        }()

        return CronometerOutcomeStats(
            totalApplied: all.count,
            completedCount: completed.count,
            inRangeCount: inRange.count,
            averagePeakBG: avgPeak,
            cleanWindowCount: cleanCompleted.count
        )
    }
}
