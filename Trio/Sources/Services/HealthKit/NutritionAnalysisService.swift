import CoreData
import Foundation
import Swinject

protocol NutritionAnalysisService {
    func runAnalysis(days: Int) async throws -> (meals: [MatchedMealAnalysis], summary: NutritionAnalysisSummary)
}

final class BaseNutritionAnalysisService: NutritionAnalysisService, Injectable {
    @Injected() private var nutritionHealthService: NutritionHealthService!
    @Injected() private var settingsManager: SettingsManager!

    private let context: NSManagedObjectContext

    /// Max time gap (seconds) between a Trio carb entry and an Apple Health meal to consider them the same meal
    private let mealMatchWindow: TimeInterval = 30 * 60 // 30 minutes

    /// Window around meal time to look for boluses
    private let bolusMatchWindow: TimeInterval = 15 * 60 // 15 minutes

    /// Tolerance for finding BG readings near a target time
    private let bgTimeTolerance: TimeInterval = 10 * 60 // 10 minutes

    init(resolver: Resolver) {
        context = CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
        debug(.service, "NutritionAnalysisService initialized")
    }

    func runAnalysis(days: Int) async throws -> (meals: [MatchedMealAnalysis], summary: NutritionAnalysisSummary) {
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate)!

        // Fetch all data sources in parallel
        async let healthMeals = nutritionHealthService.fetchMeals(from: startDate, to: endDate)
        async let trioCarbs = fetchTrioCarbEntries(from: startDate, to: endDate)
        async let glucoseReadings = fetchGlucoseReadings(from: startDate, to: endDate)
        async let bolusEvents = fetchBolusEvents(from: startDate, to: endDate)

        let ahMeals = try await healthMeals
        let trioCarbEntries = try await trioCarbs
        let glucose = try await glucoseReadings
        let boluses = try await bolusEvents

        debug(.service, "Analysis data: \(ahMeals.count) AH meals, \(trioCarbEntries.count) Trio entries, \(glucose.count) glucose, \(boluses.count) boluses")

        // Match Trio entries to Apple Health meals
        let (matched, unmatchedTrio, unmatchedAH) = matchMeals(
            trioEntries: trioCarbEntries,
            healthMeals: ahMeals,
            glucose: glucose,
            boluses: boluses
        )

        // Compute summary statistics
        let summary = computeSummary(
            matched: matched,
            unmatchedTrioCount: unmatchedTrio,
            unmatchedAHCount: unmatchedAH,
            days: days
        )

        return (meals: matched, summary: summary)
    }

    // MARK: - CoreData Fetching

    private func fetchTrioCarbEntries(from startDate: Date, to endDate: Date) async throws -> [TrioCarbRecord] {
        try await context.perform { [self] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CarbEntryStored")
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@ AND isFPU == NO AND carbs > 0",
                startDate as NSDate,
                endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            let results = try self.context.fetch(request)

            return results.compactMap { obj -> TrioCarbRecord? in
                guard let date = obj.value(forKey: "date") as? Date else { return nil }
                let carbs = obj.value(forKey: "carbs") as? Double ?? 0
                let fat = obj.value(forKey: "fat") as? Double ?? 0
                let protein = obj.value(forKey: "protein") as? Double ?? 0
                guard carbs > 0 else { return nil }
                return TrioCarbRecord(date: date, carbs: carbs, fat: fat, protein: protein)
            }
        }
    }

    private func fetchGlucoseReadings(from startDate: Date, to endDate: Date) async throws -> [BGReading] {
        try await context.perform { [self] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "GlucoseStored")
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                startDate as NSDate,
                endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

            let results = try self.context.fetch(request)

            return results.compactMap { obj -> BGReading? in
                guard let date = obj.value(forKey: "date") as? Date else { return nil }
                let glucose = obj.value(forKey: "glucose") as? Int16 ?? 0
                guard glucose > 0 else { return nil }
                return BGReading(date: date, value: Int(glucose))
            }
        }
    }

    private func fetchBolusEvents(from startDate: Date, to endDate: Date) async throws -> [BolusRecord] {
        try await context.perform { [self] in
            let request = NSFetchRequest<NSManagedObject>(entityName: "BolusStored")
            request.predicate = NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                startDate as NSDate,
                endDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "pumpEvent.timestamp", ascending: true)]

            let results = try self.context.fetch(request)

            return results.compactMap { obj -> BolusRecord? in
                guard let pumpEvent = obj.value(forKey: "pumpEvent") as? NSManagedObject,
                      let timestamp = pumpEvent.value(forKey: "timestamp") as? Date
                else { return nil }
                let amount = (obj.value(forKey: "amount") as? NSDecimalNumber)?.doubleValue ?? 0
                let isSMB = obj.value(forKey: "isSMB") as? Bool ?? false
                guard amount > 0 else { return nil }
                return BolusRecord(date: timestamp, amount: amount, isSMB: isSMB)
            }
        }
    }

    // MARK: - Meal Matching

    private func matchMeals(
        trioEntries: [TrioCarbRecord],
        healthMeals: [HealthNutritionMeal],
        glucose: [BGReading],
        boluses: [BolusRecord]
    ) -> (matched: [MatchedMealAnalysis], unmatchedTrio: Int, unmatchedAH: Int) {
        var matched: [MatchedMealAnalysis] = []
        var usedTrioIndices = Set<Int>()
        var usedAHIndices = Set<Int>()

        // For each Apple Health meal, find the closest Trio entry within the match window
        for (ahIndex, ahMeal) in healthMeals.enumerated() {
            var bestTrioIndex: Int?
            var bestDistance: TimeInterval = .greatestFiniteMagnitude

            for (trioIndex, trioEntry) in trioEntries.enumerated() {
                guard !usedTrioIndices.contains(trioIndex) else { continue }
                let distance = abs(trioEntry.date.timeIntervalSince(ahMeal.startTime))
                if distance <= mealMatchWindow, distance < bestDistance {
                    bestDistance = distance
                    bestTrioIndex = trioIndex
                }
            }

            guard let trioIndex = bestTrioIndex else { continue }

            usedTrioIndices.insert(trioIndex)
            usedAHIndices.insert(ahIndex)

            let trioEntry = trioEntries[trioIndex]
            let mealTime = trioEntry.date

            // Find boluses near this meal
            let mealBolus = boluses
                .filter { !$0.isSMB && abs($0.date.timeIntervalSince(mealTime)) <= bolusMatchWindow }
                .reduce(0.0) { $0 + $1.amount }

            // Find BG readings at meal time, +1h, +2h, +3h
            let bgAtMeal = findClosestBG(to: mealTime, in: glucose)
            let bgAt1h = findClosestBG(to: mealTime.addingTimeInterval(3600), in: glucose)
            let bgAt2h = findClosestBG(to: mealTime.addingTimeInterval(7200), in: glucose)
            let bgAt3h = findClosestBG(to: mealTime.addingTimeInterval(10800), in: glucose)

            // Find peak BG in the 3 hours after the meal
            let (peakBG, peakTime) = findPeakBG(after: mealTime, within: 10800, in: glucose)

            let analysis = MatchedMealAnalysis(
                date: mealTime,
                trioCarbs: trioEntry.carbs,
                trioFat: trioEntry.fat,
                trioProtein: trioEntry.protein,
                actualCarbs: ahMeal.totalCarbs,
                actualFat: ahMeal.totalFat,
                actualProtein: ahMeal.totalProtein,
                nutritionSource: ahMeal.source,
                bolusInsulin: mealBolus,
                bgAtMeal: bgAtMeal,
                bgAt1h: bgAt1h,
                bgAt2h: bgAt2h,
                bgAt3h: bgAt3h,
                bgPeak: peakBG,
                bgPeakTime: peakTime
            )
            matched.append(analysis)
        }

        let unmatchedTrio = trioEntries.count - usedTrioIndices.count
        let unmatchedAH = healthMeals.count - usedAHIndices.count

        return (matched: matched.sorted { $0.date < $1.date }, unmatchedTrio: unmatchedTrio, unmatchedAH: unmatchedAH)
    }

    // MARK: - BG Helpers

    private func findClosestBG(to targetTime: Date, in readings: [BGReading]) -> Int? {
        var bestReading: BGReading?
        var bestDistance: TimeInterval = .greatestFiniteMagnitude

        for reading in readings {
            let distance = abs(reading.date.timeIntervalSince(targetTime))
            if distance <= bgTimeTolerance, distance < bestDistance {
                bestDistance = distance
                bestReading = reading
            }
        }
        return bestReading?.value
    }

    private func findPeakBG(after mealTime: Date, within seconds: TimeInterval, in readings: [BGReading]) -> (Int?, Date?) {
        var peakValue: Int?
        var peakDate: Date?

        let windowEnd = mealTime.addingTimeInterval(seconds)

        for reading in readings {
            guard reading.date >= mealTime, reading.date <= windowEnd else { continue }
            if peakValue == nil || reading.value > peakValue! {
                peakValue = reading.value
                peakDate = reading.date
            }
        }
        return (peakValue, peakDate)
    }

    // MARK: - Summary Statistics

    private func computeSummary(
        matched: [MatchedMealAnalysis],
        unmatchedTrioCount: Int,
        unmatchedAHCount: Int,
        days: Int
    ) -> NutritionAnalysisSummary {
        guard !matched.isEmpty else {
            return NutritionAnalysisSummary(
                totalMatchedMeals: 0,
                unmatchedTrioEntries: unmatchedTrioCount,
                unmatchedHealthEntries: unmatchedAHCount,
                analysisPeriodDays: days,
                averageEstimationRatio: 0,
                medianEstimationRatio: 0,
                minEstimationRatio: 0,
                maxEstimationRatio: 0,
                averageMissedCarbs: 0,
                totalMissedCarbs: 0,
                averageTrioCarbs: 0,
                averageActualCarbs: 0,
                averageApparentICR: nil,
                averageEffectiveICR: nil,
                suggestedICRAdjustment: nil,
                averageBgRise: nil,
                averageBgChange2h: nil
            )
        }

        let ratios = matched.map(\.estimationRatio)
        let sortedRatios = ratios.sorted()
        let medianRatio = sortedRatios.count % 2 == 0
            ? (sortedRatios[sortedRatios.count / 2 - 1] + sortedRatios[sortedRatios.count / 2]) / 2
            : sortedRatios[sortedRatios.count / 2]

        let missedCarbs = matched.map(\.missedCarbs)
        let apparentICRs = matched.compactMap(\.apparentICR)
        let effectiveICRs = matched.compactMap(\.effectiveICR)
        let bgRises = matched.compactMap(\.bgRise)
        let bgChanges2h = matched.compactMap(\.bgChange2h)

        let avgApparentICR = apparentICRs.isEmpty ? nil : apparentICRs.reduce(0, +) / Double(apparentICRs.count)
        let avgEffectiveICR = effectiveICRs.isEmpty ? nil : effectiveICRs.reduce(0, +) / Double(effectiveICRs.count)

        let suggestedAdj: Double?
        if let apparent = avgApparentICR, let effective = avgEffectiveICR, apparent > 0 {
            suggestedAdj = effective / apparent
        } else {
            suggestedAdj = nil
        }

        return NutritionAnalysisSummary(
            totalMatchedMeals: matched.count,
            unmatchedTrioEntries: unmatchedTrioCount,
            unmatchedHealthEntries: unmatchedAHCount,
            analysisPeriodDays: days,
            averageEstimationRatio: ratios.reduce(0, +) / Double(ratios.count),
            medianEstimationRatio: medianRatio,
            minEstimationRatio: sortedRatios.first ?? 0,
            maxEstimationRatio: sortedRatios.last ?? 0,
            averageMissedCarbs: missedCarbs.reduce(0, +) / Double(missedCarbs.count),
            totalMissedCarbs: missedCarbs.reduce(0, +),
            averageTrioCarbs: matched.map(\.trioCarbs).reduce(0, +) / Double(matched.count),
            averageActualCarbs: matched.map(\.actualCarbs).reduce(0, +) / Double(matched.count),
            averageApparentICR: avgApparentICR,
            averageEffectiveICR: avgEffectiveICR,
            suggestedICRAdjustment: suggestedAdj,
            averageBgRise: bgRises.isEmpty ? nil : bgRises.reduce(0, +) / bgRises.count,
            averageBgChange2h: bgChanges2h.isEmpty ? nil : bgChanges2h.reduce(0, +) / bgChanges2h.count
        )
    }
}

// MARK: - Internal Data Types

private struct TrioCarbRecord {
    let date: Date
    let carbs: Double
    let fat: Double
    let protein: Double
}

private struct BGReading {
    let date: Date
    let value: Int
}

private struct BolusRecord {
    let date: Date
    let amount: Double
    let isSMB: Bool
}
