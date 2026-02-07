import CoreData
import Foundation

// MARK: - Historical Meal Outcome

/// A fully-resolved historical meal outcome: what was eaten, how it was dosed, and what happened to BG
struct HistoricalMealOutcome: Identifiable {
    let id = UUID()
    let date: Date

    // Cronometer nutrition (actual)
    let carbs: Double
    let fat: Double
    let protein: Double
    let calories: Double

    // Macro ratios (for similarity matching). Values 0-1.
    var carbCalorieRatio: Double { calories > 0 ? (carbs * 4) / calories : 0 }
    var fatCalorieRatio: Double { calories > 0 ? (fat * 9) / calories : 0 }
    var proteinCalorieRatio: Double { calories > 0 ? (protein * 4) / calories : 0 }

    // Dosing context — what was entered in Trio vs what Cronometer reported
    let trioEnteredCarbs: Double
    let trioEnteredFat: Double
    let trioEnteredProtein: Double
    let bolusInsulin: Double // Non-SMB boluses within 30 min of meal
    let totalInsulin: Double // All insulin (bolus + SMBs) within 2h of meal
    let bgAtMeal: Int
    let iobAtMeal: Double

    // Entry ratios: what fraction of Cronometer macros was entered in Trio
    var carbEntryRatio: Double? { carbs > 0 && trioEnteredCarbs > 0 ? trioEnteredCarbs / carbs : nil }
    var fatEntryRatio: Double? { fat > 0 && trioEnteredFat > 0 ? trioEnteredFat / fat : nil }
    var proteinEntryRatio: Double? { protein > 0 && trioEnteredProtein > 0 ? trioEnteredProtein / protein : nil }

    // Effective ICR based on actual carbs and bolus given
    var effectiveICR: Double? {
        guard bolusInsulin > 0, carbs > 0 else { return nil }
        return carbs / bolusInsulin
    }

    /// Did BG stay in range at late checkpoints (4h+)? Indicates fat/protein was covered well.
    var hadLateRise: Bool {
        let lateCheckpoints = [bgAt4h, bgAt6h, bgAt8h].compactMap { $0 }
        guard !lateCheckpoints.isEmpty else { return false }
        return lateCheckpoints.contains { $0 > 180 }
    }

    /// Was BG low at late checkpoints? Indicates too much fat/protein was entered.
    var hadLateLow: Bool {
        let lateCheckpoints = [bgAt4h, bgAt6h, bgAt8h].compactMap { $0 }
        guard !lateCheckpoints.isEmpty else { return false }
        return lateCheckpoints.contains { $0 < 70 }
    }

    // BG trajectory (closest reading within 15 min of each checkpoint)
    let bgAt1h: Int?
    let bgAt2h: Int?
    let bgAt3h: Int?
    let bgAt4h: Int?
    let bgAt6h: Int?
    let bgAt8h: Int?
    let bgAt10h: Int?

    // Derived metrics
    var peakBG: Int? {
        [bgAtMeal, bgAt1h, bgAt2h, bgAt3h, bgAt4h, bgAt6h, bgAt8h, bgAt10h]
            .compactMap { $0 }.max()
    }

    var bgRise: Int? {
        guard let peak = peakBG else { return nil }
        return peak - bgAtMeal
    }

    var bgTrajectory: [Int?] { [bgAtMeal, bgAt1h, bgAt2h, bgAt3h, bgAt4h, bgAt6h, bgAt8h, bgAt10h] }

    // Hours of unconfounded BG data before next meal
    let cleanWindowHours: Double

    // Time-of-day bucket (for similarity)
    var mealTimeBucket: MealTimeBucket {
        let hour = Calendar.current.component(.hour, from: date)
        if hour < 10 { return .breakfast }
        if hour < 14 { return .lunch }
        if hour < 18 { return .afternoon }
        return .dinner
    }
}

enum MealTimeBucket: String, CaseIterable {
    case breakfast, lunch, afternoon, dinner
}

// MARK: - Prediction Result

/// Predicted BG response for a meal based on similar historical meals
struct MealOutcomePrediction {
    let similarMealCount: Int
    let averageSimilarity: Double // 0-1, higher = more similar
    let confidence: PredictionConfidence

    // Predicted BG trajectory (weighted average of similar meals)
    let predictedBGAt1h: Int?
    let predictedBGAt2h: Int?
    let predictedBGAt3h: Int?
    let predictedBGAt4h: Int?
    let predictedBGAt6h: Int?

    // Predicted peak
    let predictedPeakBG: Int?
    let predictedBGRise: Int?

    // Recommended effective ICR based on historical outcomes
    let suggestedEffectiveICR: Double?

    // What dose would have kept BG in range for similar meals
    let suggestedBolus: Double?

    // Suggested macro entry based on similar meals with good BG outcomes.
    // Fat/protein interact with carbs: entering more fat/protein → more FPU carb-equivalents →
    // more SMBs from the loop → less upfront carb bolus needed. These are learned as a coupled system.
    let suggestedCarbFactor: Double? // Ratio of Cronometer carbs to enter (0-1.5)
    let suggestedFatFactor: Double? // Ratio of Cronometer fat to enter (0-1.5)
    let suggestedProteinFactor: Double? // Ratio of Cronometer protein to enter (0-1.5)
    let suggestedCarbEntry: Double? // Absolute grams of carbs to enter
    let suggestedFatEntry: Double? // Absolute grams of fat to enter
    let suggestedProteinEntry: Double? // Absolute grams of protein to enter
    // Estimated FPU carb-equivalents from suggested fat/protein entry
    let estimatedFPUCarbEquivalents: Double?

    // Similar meals for display
    let topSimilarMeals: [SimilarMealMatch]

    enum PredictionConfidence: String {
        case high // 5+ similar meals with clean windows
        case medium // 3-4 similar meals
        case low // 1-2 similar meals
        case none // no similar meals found
    }
}

/// A past meal matched by similarity
struct SimilarMealMatch {
    let meal: HistoricalMealOutcome
    let similarity: Double // 0-1
}

// MARK: - Meal Outcome Prediction Service

/// Builds historical meal outcomes and predicts BG response for new meals
final class MealOutcomePredictionService {
    static let shared = MealOutcomePredictionService()

    private var cachedOutcomes: [HistoricalMealOutcome]?
    private var cacheDate: Date?
    private let cacheDurationMinutes = 30.0

    private init() {}

    // MARK: - Public API

    /// Build historical meal outcomes from the last 14 days
    func buildHistoricalOutcomes(context: NSManagedObjectContext) async -> [HistoricalMealOutcome] {
        // Return cache if fresh
        if let cached = cachedOutcomes, let cacheDate = cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheDurationMinutes * 60
        {
            return cached
        }

        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -14, to: endDate) ?? endDate

        // Fetch all data upfront for efficiency
        let allGlucose = await fetchAllGlucose(from: startDate, to: endDate, context: context)
        let allBoluses = await fetchAllBoluses(from: startDate, to: endDate, context: context)
        let allCarbEntries = await fetchAllCarbEntries(from: startDate, to: endDate, context: context)
        let allLoopStates = await fetchAllLoopStates(from: startDate, to: endDate, context: context)

        // Get all inferred meals from snapshots
        var allMeals: [InferredMealEvent] = []
        var day = startDate
        while day <= endDate {
            let dayStart = calendar.startOfDay(for: day)
            allMeals += NutritionSnapshotStore.shared.inferredMealEvents(for: dayStart)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? endDate.addingTimeInterval(1)
        }

        // Sort meals chronologically
        allMeals.sort { $0.detectedAt < $1.detectedAt }

        // Build outcome for each meal
        var outcomes: [HistoricalMealOutcome] = []
        for (index, meal) in allMeals.enumerated() {
            // Skip tiny entries
            guard meal.carbsDelta >= 5 || meal.fatDelta >= 5 || meal.proteinDelta >= 5 else { continue }

            // Find next meal time (for clean window calculation)
            let nextMealTime: Date? = index + 1 < allMeals.count ? allMeals[index + 1].detectedAt : nil
            let cleanWindow: Double
            if let next = nextMealTime {
                cleanWindow = min(10, next.timeIntervalSince(meal.detectedAt) / 3600)
            } else {
                cleanWindow = min(10, endDate.timeIntervalSince(meal.detectedAt) / 3600)
            }

            // Find BG at meal time
            let bgAtMeal = findClosestBG(near: meal.detectedAt, in: allGlucose, withinMinutes: 15) ?? 0
            guard bgAtMeal > 0 else { continue } // Skip if no BG data

            // Find IOB at meal time from loop states
            let iobAtMeal = findClosestIOB(near: meal.detectedAt, in: allLoopStates)

            // Find Trio carb entry near this meal (includes fat/protein)
            let trioEntry = findClosestCarbEntry(near: meal.detectedAt, in: allCarbEntries, withinMinutes: 60)

            // Find meal bolus (non-SMB within 30 min)
            let mealBolus = findMealBoluses(near: meal.detectedAt, in: allBoluses, withinMinutes: 30)

            // Find total insulin (all boluses + SMBs within 2h after meal)
            let totalInsulin = findTotalInsulin(after: meal.detectedAt, in: allBoluses, withinHours: 2)

            // BG trajectory at checkpoints
            let bg1h = findClosestBG(near: meal.detectedAt.addingTimeInterval(1 * 3600), in: allGlucose, withinMinutes: 15)
            let bg2h = findClosestBG(near: meal.detectedAt.addingTimeInterval(2 * 3600), in: allGlucose, withinMinutes: 15)
            let bg3h = findClosestBG(near: meal.detectedAt.addingTimeInterval(3 * 3600), in: allGlucose, withinMinutes: 15)
            let bg4h = findClosestBG(near: meal.detectedAt.addingTimeInterval(4 * 3600), in: allGlucose, withinMinutes: 15)
            let bg6h = cleanWindow >= 6 ? findClosestBG(
                near: meal.detectedAt.addingTimeInterval(6 * 3600), in: allGlucose, withinMinutes: 15
            ) : nil
            let bg8h = cleanWindow >= 8 ? findClosestBG(
                near: meal.detectedAt.addingTimeInterval(8 * 3600), in: allGlucose, withinMinutes: 15
            ) : nil
            let bg10h = cleanWindow >= 10 ? findClosestBG(
                near: meal.detectedAt.addingTimeInterval(10 * 3600), in: allGlucose, withinMinutes: 15
            ) : nil

            let outcome = HistoricalMealOutcome(
                date: meal.detectedAt,
                carbs: meal.carbsDelta,
                fat: meal.fatDelta,
                protein: meal.proteinDelta,
                calories: meal.totalCalories,
                trioEnteredCarbs: trioEntry.carbs,
                trioEnteredFat: trioEntry.fat,
                trioEnteredProtein: trioEntry.protein,
                bolusInsulin: mealBolus,
                totalInsulin: totalInsulin,
                bgAtMeal: bgAtMeal,
                iobAtMeal: iobAtMeal,
                bgAt1h: bg1h,
                bgAt2h: bg2h,
                bgAt3h: bg3h,
                bgAt4h: bg4h,
                bgAt6h: bg6h,
                bgAt8h: bg8h,
                bgAt10h: bg10h,
                cleanWindowHours: cleanWindow
            )

            outcomes.append(outcome)
        }

        cachedOutcomes = outcomes
        cacheDate = Date()
        return outcomes
    }

    /// Predict BG response for a new meal based on similar historical meals
    func predictOutcome(
        forCarbs carbs: Double,
        fat: Double,
        protein: Double,
        currentBG: Int,
        currentIOB: Double,
        history: [HistoricalMealOutcome]
    ) -> MealOutcomePrediction {
        guard !history.isEmpty else {
            return MealOutcomePrediction(
                similarMealCount: 0, averageSimilarity: 0, confidence: .none,
                predictedBGAt1h: nil, predictedBGAt2h: nil, predictedBGAt3h: nil,
                predictedBGAt4h: nil, predictedBGAt6h: nil, predictedPeakBG: nil,
                predictedBGRise: nil, suggestedEffectiveICR: nil, suggestedBolus: nil,
                suggestedCarbFactor: nil, suggestedFatFactor: nil, suggestedProteinFactor: nil,
                suggestedCarbEntry: nil, suggestedFatEntry: nil, suggestedProteinEntry: nil,
                estimatedFPUCarbEquivalents: nil, topSimilarMeals: []
            )
        }

        let targetCalories = carbs * 4 + fat * 9 + protein * 4
        let currentTimeBucket = currentMealTimeBucket()

        // Calculate similarity for each historical meal
        var matches: [SimilarMealMatch] = []
        for meal in history {
            let sim = calculateSimilarity(
                targetCarbs: carbs, targetFat: fat, targetProtein: protein,
                targetCalories: targetCalories, targetBG: currentBG,
                targetIOB: currentIOB, targetTimeBucket: currentTimeBucket,
                historicalMeal: meal
            )
            if sim > 0.3 { // Minimum similarity threshold
                matches.append(SimilarMealMatch(meal: meal, similarity: sim))
            }
        }

        // Sort by similarity (best first)
        matches.sort { $0.similarity > $1.similarity }

        // Take top 10 most similar meals
        let topMatches = Array(matches.prefix(10))

        guard !topMatches.isEmpty else {
            return MealOutcomePrediction(
                similarMealCount: 0, averageSimilarity: 0, confidence: .none,
                predictedBGAt1h: nil, predictedBGAt2h: nil, predictedBGAt3h: nil,
                predictedBGAt4h: nil, predictedBGAt6h: nil, predictedPeakBG: nil,
                predictedBGRise: nil, suggestedEffectiveICR: nil, suggestedBolus: nil,
                suggestedCarbFactor: nil, suggestedFatFactor: nil, suggestedProteinFactor: nil,
                suggestedCarbEntry: nil, suggestedFatEntry: nil, suggestedProteinEntry: nil,
                estimatedFPUCarbEquivalents: nil, topSimilarMeals: []
            )
        }

        // Weighted average of BG trajectories
        let avgSim = topMatches.reduce(0.0) { $0 + $1.similarity } / Double(topMatches.count)

        let predicted1h = weightedAverageBG(topMatches, keyPath: \.meal.bgAt1h, baseBG: currentBG)
        let predicted2h = weightedAverageBG(topMatches, keyPath: \.meal.bgAt2h, baseBG: currentBG)
        let predicted3h = weightedAverageBG(topMatches, keyPath: \.meal.bgAt3h, baseBG: currentBG)
        let predicted4h = weightedAverageBG(topMatches, keyPath: \.meal.bgAt4h, baseBG: currentBG)
        let predicted6h = weightedAverageBG(topMatches, keyPath: \.meal.bgAt6h, baseBG: currentBG)

        let predictedPeak = [predicted1h, predicted2h, predicted3h, predicted4h, predicted6h].compactMap { $0 }.max()
        let predictedRise = predictedPeak.map { $0 - currentBG }

        // Suggested effective ICR from similar meals that had good outcomes
        let goodOutcomes = topMatches.filter { match in
            guard let peak = match.meal.peakBG else { return false }
            return peak <= 180 && (match.meal.bgAt2h ?? 0) >= 70
        }

        let suggestedICR: Double?
        if !goodOutcomes.isEmpty {
            let icrs = goodOutcomes.compactMap { $0.meal.effectiveICR }
            suggestedICR = icrs.isEmpty ? nil : icrs.reduce(0, +) / Double(icrs.count)
        } else {
            // Use all meals' effective ICR as fallback
            let icrs = topMatches.compactMap { $0.meal.effectiveICR }
            suggestedICR = icrs.isEmpty ? nil : icrs.reduce(0, +) / Double(icrs.count)
        }

        let suggestedBolus = suggestedICR.map { carbs / $0 }

        // Compute suggested entry factors from similar meals as a COUPLED system.
        // Fat/protein → FPU carb-equivalents → loop delivers extra insulin via SMBs over hours.
        // So entering more fat/protein means less upfront carb bolus is needed.
        // "Good outcomes" = BG stayed in range (early: no spike, late: no rise or low)
        let goodFullOutcomes = topMatches.filter { match in
            guard let peak = match.meal.peakBG else { return false }
            return match.meal.cleanWindowHours >= 4
                && peak <= 180
                && (match.meal.bgAt2h ?? 0) >= 70
                && !match.meal.hadLateRise
                && !match.meal.hadLateLow
        }

        let sourceMatches = goodFullOutcomes.isEmpty ? topMatches : goodFullOutcomes

        // Learn coupled entry factors from meals with good outcomes
        let suggestedCarbFactor: Double?
        let suggestedFatFactor: Double?
        let suggestedProteinFactor: Double?

        let carbRatios = sourceMatches.compactMap { $0.meal.carbEntryRatio }
        suggestedCarbFactor = carbRatios.isEmpty ? nil :
            max(0.1, min(1.5, carbRatios.reduce(0, +) / Double(carbRatios.count)))

        let fatRatios = sourceMatches.compactMap { $0.meal.fatEntryRatio }
        suggestedFatFactor = fatRatios.isEmpty ? nil :
            max(0.0, min(1.5, fatRatios.reduce(0, +) / Double(fatRatios.count)))

        let proteinRatios = sourceMatches.compactMap { $0.meal.proteinEntryRatio }
        suggestedProteinFactor = proteinRatios.isEmpty ? nil :
            max(0.0, min(1.5, proteinRatios.reduce(0, +) / Double(proteinRatios.count)))

        let suggestedCarbEntry = suggestedCarbFactor.map { carbs * $0 }
        let suggestedFatEntry = suggestedFatFactor.map { fat * $0 }
        let suggestedProteinEntry = suggestedProteinFactor.map { protein * $0 }

        // Estimate FPU carb-equivalents from the suggested fat/protein
        // This helps the user understand how much extra insulin the loop will deliver
        let estFPU: Double?
        if let sugFat = suggestedFatEntry, let sugProt = suggestedProteinEntry {
            let kcal = sugProt * 4 + sugFat * 9
            estFPU = (kcal / 10) * 0.5 // Using default individualAdjustmentFactor
        } else {
            estFPU = nil
        }

        let confidence: MealOutcomePrediction.PredictionConfidence
        let cleanMatches = topMatches.filter { $0.meal.cleanWindowHours >= 4 }
        if cleanMatches.count >= 5 { confidence = .high }
        else if cleanMatches.count >= 3 { confidence = .medium }
        else if !topMatches.isEmpty { confidence = .low }
        else { confidence = .none }

        return MealOutcomePrediction(
            similarMealCount: topMatches.count,
            averageSimilarity: avgSim,
            confidence: confidence,
            predictedBGAt1h: predicted1h,
            predictedBGAt2h: predicted2h,
            predictedBGAt3h: predicted3h,
            predictedBGAt4h: predicted4h,
            predictedBGAt6h: predicted6h,
            predictedPeakBG: predictedPeak,
            predictedBGRise: predictedRise,
            suggestedEffectiveICR: suggestedICR,
            suggestedBolus: suggestedBolus,
            suggestedCarbFactor: suggestedCarbFactor,
            suggestedFatFactor: suggestedFatFactor,
            suggestedProteinFactor: suggestedProteinFactor,
            suggestedCarbEntry: suggestedCarbEntry,
            suggestedFatEntry: suggestedFatEntry,
            suggestedProteinEntry: suggestedProteinEntry,
            estimatedFPUCarbEquivalents: estFPU,
            topSimilarMeals: Array(topMatches.prefix(5))
        )
    }

    /// Invalidate the cache (call when new data is available)
    func invalidateCache() {
        cachedOutcomes = nil
        cacheDate = nil
    }

    // MARK: - Similarity Algorithm

    /// Calculate how similar a historical meal is to the target meal (0-1)
    private func calculateSimilarity(
        targetCarbs: Double, targetFat: Double, targetProtein: Double,
        targetCalories: Double, targetBG: Int, targetIOB: Double,
        targetTimeBucket: MealTimeBucket, historicalMeal: HistoricalMealOutcome
    ) -> Double {
        // 1. Meal size similarity (Euclidean distance on calories, normalized)
        let calDiff = abs(targetCalories - historicalMeal.calories)
        let maxCalRange = 1000.0 // Normalize against a 1000 kcal range
        let sizeSimilarity = max(0, 1.0 - calDiff / maxCalRange)

        // 2. Carb amount similarity (important because carbs drive acute BG response)
        let carbDiff = abs(targetCarbs - historicalMeal.carbs)
        let carbSimilarity = max(0, 1.0 - carbDiff / 100.0)

        // 3. Macro composition similarity (cosine similarity on calorie ratios)
        let targetCarbRatio = targetCalories > 0 ? (targetCarbs * 4) / targetCalories : 0
        let targetFatRatio = targetCalories > 0 ? (targetFat * 9) / targetCalories : 0
        let targetProteinRatio = targetCalories > 0 ? (targetProtein * 4) / targetCalories : 0

        let macroSimilarity = cosineSimilarity(
            a: [targetCarbRatio, targetFatRatio, targetProteinRatio],
            b: [historicalMeal.carbCalorieRatio, historicalMeal.fatCalorieRatio, historicalMeal.proteinCalorieRatio]
        )

        // 4. Time-of-day similarity (same bucket = 1.0, adjacent = 0.7, far = 0.4)
        let timeSimilarity: Double
        if targetTimeBucket == historicalMeal.mealTimeBucket {
            timeSimilarity = 1.0
        } else {
            let allBuckets = MealTimeBucket.allCases
            let targetIdx = allBuckets.firstIndex(of: targetTimeBucket) ?? 0
            let histIdx = allBuckets.firstIndex(of: historicalMeal.mealTimeBucket) ?? 0
            let distance = abs(targetIdx - histIdx)
            timeSimilarity = distance <= 1 ? 0.7 : 0.4
        }

        // 5. Pre-meal BG similarity
        let bgDiff = abs(Double(targetBG - historicalMeal.bgAtMeal))
        let bgSimilarity = max(0, 1.0 - bgDiff / 150.0)

        // 6. Pre-meal IOB similarity
        let iobDiff = abs(targetIOB - historicalMeal.iobAtMeal)
        let iobSimilarity = max(0, 1.0 - iobDiff / 5.0)

        // Weighted combination
        let weights: [(Double, Double)] = [
            (carbSimilarity, 0.30), // Carb amount is most important
            (macroSimilarity, 0.25), // Macro composition drives delayed effects
            (sizeSimilarity, 0.15), // Overall meal size
            (bgSimilarity, 0.15), // Starting BG matters
            (timeSimilarity, 0.10), // Time of day (dawn phenomenon, etc.)
            (iobSimilarity, 0.05), // Pre-meal IOB
        ]

        return weights.reduce(0.0) { $0 + $1.0 * $1.1 }
    }

    private func cosineSimilarity(a: [Double], b: [Double]) -> Double {
        let dotProduct = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        let magnitudeA = sqrt(a.reduce(0.0) { $0 + $1 * $1 })
        let magnitudeB = sqrt(b.reduce(0.0) { $0 + $1 * $1 })
        guard magnitudeA > 0, magnitudeB > 0 else { return 0 }
        return max(0, dotProduct / (magnitudeA * magnitudeB))
    }

    /// Weighted average of BG values from similar meals, adjusted for starting BG difference
    private func weightedAverageBG(
        _ matches: [SimilarMealMatch],
        keyPath: KeyPath<SimilarMealMatch, Int?>,
        baseBG: Int
    ) -> Int? {
        var weightedSum = 0.0
        var totalWeight = 0.0

        for match in matches {
            guard let bg = match[keyPath: keyPath] else { continue }
            // Adjust for starting BG difference: if their meal started at 120 and peaked at 200 (rise of 80),
            // and our starting BG is 100, predict peak at 100+80 = 180
            let rise = bg - match.meal.bgAtMeal
            let adjustedBG = baseBG + rise

            weightedSum += Double(adjustedBG) * match.similarity
            totalWeight += match.similarity
        }

        guard totalWeight > 0 else { return nil }
        return Int(weightedSum / totalWeight)
    }

    private func currentMealTimeBucket() -> MealTimeBucket {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 10 { return .breakfast }
        if hour < 14 { return .lunch }
        if hour < 18 { return .afternoon }
        return .dinner
    }

    // MARK: - Data Fetching (bulk queries for efficiency)

    private struct GlucoseRecord {
        let date: Date
        let value: Int
    }

    private struct BolusRecord {
        let date: Date
        let amount: Double
        let isSMB: Bool
    }

    private struct CarbRecord {
        let date: Date
        let carbs: Double
        let fat: Double
        let protein: Double
    }

    private struct LoopStateRecord {
        let date: Date
        let iob: Double
    }

    private func fetchAllGlucose(
        from startDate: Date, to endDate: Date, context: NSManagedObjectContext
    ) async -> [GlucoseRecord] {
        await context.perform {
            let request = GlucoseStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@", startDate as NSDate, endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            guard let results = try? context.fetch(request) else { return [] }
            return results.compactMap { g in
                guard let date = g.date else { return nil }
                return GlucoseRecord(date: date, value: Int(g.glucose))
            }
        }
    }

    private func fetchAllBoluses(
        from startDate: Date, to endDate: Date, context: NSManagedObjectContext
    ) async -> [BolusRecord] {
        await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "BolusStored")
            // BolusStored's date is via its parent PumpEventStored relationship
            // Query directly with the amount and isSMB fields
            request.predicate = NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                startDate as NSDate, endDate as NSDate
            )
            guard let results = try? context.fetch(request) else { return [] }
            return results.compactMap { obj in
                guard let amount = obj.value(forKey: "amount") as? NSDecimalNumber,
                      let pumpEvent = obj.value(forKey: "pumpEvent") as? NSManagedObject,
                      let timestamp = pumpEvent.value(forKey: "timestamp") as? Date
                else { return nil }
                let isSMB = obj.value(forKey: "isSMB") as? Bool ?? false
                return BolusRecord(date: timestamp, amount: amount.doubleValue, isSMB: isSMB)
            }
        }
    }

    private func fetchAllCarbEntries(
        from startDate: Date, to endDate: Date, context: NSManagedObjectContext
    ) async -> [CarbRecord] {
        await context.perform {
            let request = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@ AND isFPU == NO AND (carbs > 0 OR fat > 0 OR protein > 0)",
                startDate as NSDate, endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            guard let results = try? context.fetch(request) else { return [] }
            return results.compactMap { entry in
                guard let date = entry.date else { return nil }
                return CarbRecord(date: date, carbs: entry.carbs, fat: entry.fat, protein: entry.protein)
            }
        }
    }

    private func fetchAllLoopStates(
        from startDate: Date, to endDate: Date, context: NSManagedObjectContext
    ) async -> [LoopStateRecord] {
        await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "OrefDetermination")
            request.predicate = NSPredicate(
                format: "deliverAt >= %@ AND deliverAt <= %@",
                startDate as NSDate, endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
            guard let results = try? context.fetch(request) else { return [] }
            return results.compactMap { obj in
                guard let date = obj.value(forKey: "deliverAt") as? Date,
                      let iob = obj.value(forKey: "iob") as? NSDecimalNumber
                else { return nil }
                return LoopStateRecord(date: date, iob: iob.doubleValue)
            }
        }
    }

    // MARK: - In-Memory Lookups

    private func findClosestBG(near targetTime: Date, in records: [GlucoseRecord], withinMinutes: Int) -> Int? {
        let maxInterval = TimeInterval(withinMinutes * 60)
        return records
            .filter { abs($0.date.timeIntervalSince(targetTime)) <= maxInterval }
            .min { abs($0.date.timeIntervalSince(targetTime)) < abs($1.date.timeIntervalSince(targetTime)) }?
            .value
    }

    private func findClosestIOB(near targetTime: Date, in records: [LoopStateRecord]) -> Double {
        let maxInterval: TimeInterval = 10 * 60 // 10 minutes
        return records
            .filter { abs($0.date.timeIntervalSince(targetTime)) <= maxInterval }
            .min { abs($0.date.timeIntervalSince(targetTime)) < abs($1.date.timeIntervalSince(targetTime)) }?
            .iob ?? 0
    }

    private func findClosestCarbEntry(
        near targetTime: Date, in records: [CarbRecord], withinMinutes: Int
    ) -> (carbs: Double, fat: Double, protein: Double) {
        let maxInterval = TimeInterval(withinMinutes * 60)
        guard let closest = records
            .filter({ abs($0.date.timeIntervalSince(targetTime)) <= maxInterval })
            .min(by: { abs($0.date.timeIntervalSince(targetTime)) < abs($1.date.timeIntervalSince(targetTime)) })
        else { return (0, 0, 0) }
        return (closest.carbs, closest.fat, closest.protein)
    }

    private func findMealBoluses(near targetTime: Date, in records: [BolusRecord], withinMinutes: Int) -> Double {
        let maxInterval = TimeInterval(withinMinutes * 60)
        return records
            .filter { !$0.isSMB && abs($0.date.timeIntervalSince(targetTime)) <= maxInterval }
            .reduce(0.0) { $0 + $1.amount }
    }

    private func findTotalInsulin(after startTime: Date, in records: [BolusRecord], withinHours: Int) -> Double {
        let endTime = startTime.addingTimeInterval(TimeInterval(withinHours * 3600))
        return records
            .filter { $0.date >= startTime && $0.date <= endTime }
            .reduce(0.0) { $0 + $1.amount }
    }
}
