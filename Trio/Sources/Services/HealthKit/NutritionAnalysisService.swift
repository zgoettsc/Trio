import CoreData
import Foundation
import Swinject

protocol NutritionAnalysisService {
    func runAnalysis(days: Int) async throws -> (days: [MatchedMealAnalysis], summary: NutritionAnalysisSummary)
}

final class BaseNutritionAnalysisService: NutritionAnalysisService, Injectable {
    @Injected() private var nutritionHealthService: NutritionHealthService!
    @Injected() private var settingsManager: SettingsManager!

    private let context: NSManagedObjectContext
    private let calendar = Calendar.current

    init(resolver: Resolver) {
        context = CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
        debug(.service, "NutritionAnalysisService initialized")
    }

    func runAnalysis(days: Int) async throws -> (days: [MatchedMealAnalysis], summary: NutritionAnalysisSummary) {
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate)!

        // Fetch all data sources in parallel
        async let healthDays = nutritionHealthService.fetchMeals(from: startDate, to: endDate)
        async let trioCarbs = fetchTrioCarbEntries(from: startDate, to: endDate)
        async let glucoseReadings = fetchGlucoseReadings(from: startDate, to: endDate)
        async let bolusEvents = fetchBolusEvents(from: startDate, to: endDate)

        let ahDays = try await healthDays
        let trioCarbEntries = try await trioCarbs
        let glucose = try await glucoseReadings
        let boluses = try await bolusEvents

        debug(
            .service,
            "Analysis data: \(ahDays.count) AH days, \(trioCarbEntries.count) Trio entries, \(glucose.count) glucose, \(boluses.count) boluses"
        )

        // Match by day: compare daily Trio carb totals vs daily Cronometer totals
        let (matched, unmatchedTrioDays, unmatchedAHDays) = matchByDay(
            trioEntries: trioCarbEntries,
            healthDays: ahDays,
            glucose: glucose,
            boluses: boluses
        )

        let summary = computeSummary(
            matched: matched,
            unmatchedTrioCount: unmatchedTrioDays,
            unmatchedAHCount: unmatchedAHDays,
            days: days
        )

        return (days: matched, summary: summary)
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

    // MARK: - Day-Based Matching

    /// Match Trio carb entries and Apple Health nutrition by calendar day.
    /// Since Cronometer writes all entries at midnight, we compare daily totals.
    private func matchByDay(
        trioEntries: [TrioCarbRecord],
        healthDays: [HealthNutritionDay],
        glucose: [BGReading],
        boluses: [BolusRecord]
    ) -> (matched: [MatchedMealAnalysis], unmatchedTrioDays: Int, unmatchedAHDays: Int) {
        // Group Trio entries by calendar day
        var trioDayTotals: [Date: (carbs: Double, fat: Double, protein: Double, entries: [TrioCarbRecord])] = [:]
        for entry in trioEntries {
            let dayStart = calendar.startOfDay(for: entry.date)
            var existing = trioDayTotals[dayStart] ?? (carbs: 0, fat: 0, protein: 0, entries: [])
            existing.carbs += entry.carbs
            existing.fat += entry.fat
            existing.protein += entry.protein
            existing.entries.append(entry)
            trioDayTotals[dayStart] = existing
        }

        // Group boluses by calendar day (non-SMB only for meal boluses)
        var dayBoluses: [Date: Double] = [:]
        for bolus in boluses where !bolus.isSMB {
            let dayStart = calendar.startOfDay(for: bolus.date)
            dayBoluses[dayStart, default: 0] += bolus.amount
        }

        // Build a map of AH days by date
        var ahDayMap: [Date: HealthNutritionDay] = [:]
        for day in healthDays {
            let dayStart = calendar.startOfDay(for: day.date)
            ahDayMap[dayStart] = day
        }

        // Match days that have both Trio and AH data
        var matched: [MatchedMealAnalysis] = []
        var matchedTrioDays = Set<Date>()
        var matchedAHDays = Set<Date>()

        for (dayDate, trioDay) in trioDayTotals {
            guard let ahDay = ahDayMap[dayDate] else { continue }

            matchedTrioDays.insert(dayDate)
            matchedAHDays.insert(dayDate)

            let dayBolus = dayBoluses[dayDate] ?? 0

            // Compute daily average BG and time in range
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayDate)!
            let dayGlucose = glucose.filter { $0.date >= dayDate && $0.date < dayEnd }
            let avgBG = dayGlucose.isEmpty ? nil : dayGlucose.map(\.value).reduce(0, +) / dayGlucose.count
            let maxBG = dayGlucose.map(\.value).max()

            let analysis = MatchedMealAnalysis(
                date: dayDate,
                trioCarbs: trioDay.carbs,
                trioFat: trioDay.fat,
                trioProtein: trioDay.protein,
                actualCarbs: ahDay.totalCarbs,
                actualFat: ahDay.totalFat,
                actualProtein: ahDay.totalProtein,
                nutritionSource: ahDay.source,
                bolusInsulin: dayBolus,
                bgAtMeal: avgBG,
                bgPeak: maxBG
            )
            matched.append(analysis)
        }

        let unmatchedTrioDays = trioDayTotals.keys.count - matchedTrioDays.count
        let unmatchedAHDays = ahDayMap.keys.count - matchedAHDays.count

        return (
            matched: matched.sorted { $0.date > $1.date },
            unmatchedTrioDays: unmatchedTrioDays,
            unmatchedAHDays: unmatchedAHDays
        )
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
                totalMatchedDays: 0,
                unmatchedTrioDays: unmatchedTrioCount,
                unmatchedHealthDays: unmatchedAHCount,
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
                averageDailyBG: nil,
                averageDailyMaxBG: nil
            )
        }

        let ratios = matched.map(\.estimationRatio).filter { $0 > 0 }
        let sortedRatios = ratios.sorted()
        let medianRatio: Double
        if sortedRatios.isEmpty {
            medianRatio = 0
        } else if sortedRatios.count % 2 == 0 {
            medianRatio = (sortedRatios[sortedRatios.count / 2 - 1] + sortedRatios[sortedRatios.count / 2]) / 2
        } else {
            medianRatio = sortedRatios[sortedRatios.count / 2]
        }

        let missedCarbs = matched.map(\.missedCarbs)
        let apparentICRs = matched.compactMap(\.apparentICR)
        let effectiveICRs = matched.compactMap(\.effectiveICR)

        let avgApparentICR = apparentICRs.isEmpty ? nil : apparentICRs.reduce(0, +) / Double(apparentICRs.count)
        let avgEffectiveICR = effectiveICRs.isEmpty ? nil : effectiveICRs.reduce(0, +) / Double(effectiveICRs.count)

        let suggestedAdj: Double?
        if let apparent = avgApparentICR, let effective = avgEffectiveICR, apparent > 0 {
            suggestedAdj = effective / apparent
        } else {
            suggestedAdj = nil
        }

        // Daily BG averages and max values
        let avgBGs = matched.compactMap(\.bgAtMeal)
        let avgDailyBG = avgBGs.isEmpty ? nil : avgBGs.reduce(0, +) / avgBGs.count
        let maxBGs = matched.compactMap(\.bgPeak)
        let avgDailyMaxBG = maxBGs.isEmpty ? nil : maxBGs.reduce(0, +) / maxBGs.count

        return NutritionAnalysisSummary(
            totalMatchedDays: matched.count,
            unmatchedTrioDays: unmatchedTrioCount,
            unmatchedHealthDays: unmatchedAHCount,
            analysisPeriodDays: days,
            averageEstimationRatio: ratios.isEmpty ? 0 : ratios.reduce(0, +) / Double(ratios.count),
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
            averageDailyBG: avgDailyBG,
            averageDailyMaxBG: avgDailyMaxBG
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
