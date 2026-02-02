import Combine
import Foundation
import HealthKit
import Swinject

protocol NutritionHealthService {
    /// Check if HealthKit is available on this device
    var isAvailable: Bool { get }

    /// Request read permissions for nutrition data (carbs, fat, protein)
    func requestPermissions() async -> Bool

    /// Fetch nutrition entries from Apple Health for a date range, excluding Trio-originated entries
    func fetchNutritionEntries(from startDate: Date, to endDate: Date) async throws -> [HealthNutritionEntry]

    /// Fetch nutrition entries grouped into meals by time proximity
    func fetchMeals(from startDate: Date, to endDate: Date) async throws -> [HealthNutritionMeal]

    /// Fetch meals from the last N hours (convenience method)
    func fetchRecentMeals(hours: Int) async throws -> [HealthNutritionMeal]
}

final class BaseNutritionHealthService: NutritionHealthService, Injectable {
    @Injected() private var healthKitStore: HKHealthStore!
    @Injected() private var settingsManager: SettingsManager!

    /// Time window (in seconds) for grouping nutrition entries into a single meal
    private let mealGroupingWindow: TimeInterval = 15 * 60 // 15 minutes

    /// Bundle identifier prefix for Trio to filter out its own entries
    private let trioBundlePrefix = "org.nightscout"

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        debug(.service, "NutritionHealthService initialized")
    }

    func requestPermissions() async -> Bool {
        guard isAvailable else { return false }

        do {
            try await healthKitStore.requestAuthorization(
                toShare: [],
                read: AppleHealthConfig.nutritionReadPermissions
            )
            debug(.service, "Nutrition read permissions granted")
            return true
        } catch {
            warning(.service, "Failed to request nutrition read permissions: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Fetch Nutrition Entries

    func fetchNutritionEntries(from startDate: Date, to endDate: Date) async throws -> [HealthNutritionEntry] {
        async let carbSamples = fetchSamples(type: .dietaryCarbohydrates, from: startDate, to: endDate)
        async let fatSamples = fetchSamples(type: .dietaryFatTotal, from: startDate, to: endDate)
        async let proteinSamples = fetchSamples(type: .dietaryProtein, from: startDate, to: endDate)

        let carbs = try await carbSamples
        let fats = try await fatSamples
        let proteins = try await proteinSamples

        // Merge samples by timestamp and source into unified nutrition entries
        return mergeNutritionSamples(carbs: carbs, fats: fats, proteins: proteins)
    }

    // MARK: - Fetch Meals

    func fetchMeals(from startDate: Date, to endDate: Date) async throws -> [HealthNutritionMeal] {
        let entries = try await fetchNutritionEntries(from: startDate, to: endDate)
        return groupEntriesIntoMeals(entries)
    }

    func fetchRecentMeals(hours: Int) async throws -> [HealthNutritionMeal] {
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-TimeInterval(hours * 3600))
        return try await fetchMeals(from: startDate, to: endDate)
    }

    // MARK: - Private Helpers

    private func fetchSamples(
        type identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKQuantitySample] {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw HealthMetricsError.typeNotAvailable
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let quantitySamples = (samples as? [HKQuantitySample]) ?? []

                // Filter out Trio-originated entries using bundle identifier
                let externalSamples = quantitySamples.filter { sample in
                    let bundleId = sample.sourceRevision.source.bundleIdentifier
                    // Exclude entries from Trio itself
                    return !bundleId.hasPrefix(self.trioBundlePrefix)
                }

                continuation.resume(returning: externalSamples)
            }

            self.healthKitStore.execute(query)
        }
    }

    /// Merge carb, fat, and protein samples into unified nutrition entries.
    /// Samples from the same source with timestamps within 2 seconds are considered the same food item.
    private func mergeNutritionSamples(
        carbs: [HKQuantitySample],
        fats: [HKQuantitySample],
        proteins: [HKQuantitySample]
    ) -> [HealthNutritionEntry] {
        // Build a dictionary keyed by (rounded timestamp, source) for merging
        struct SampleKey: Hashable {
            let timestamp: Int // seconds since reference date, rounded to nearest 2s
            let source: String
        }

        var merged: [SampleKey: (carbs: Double, fat: Double, protein: Double, date: Date, source: String)] = [:]

        func key(for sample: HKQuantitySample) -> SampleKey {
            let ts = Int(sample.startDate.timeIntervalSinceReferenceDate / 2) * 2
            return SampleKey(timestamp: ts, source: sample.sourceRevision.source.name)
        }

        for sample in carbs {
            let k = key(for: sample)
            var entry = merged[k] ?? (carbs: 0, fat: 0, protein: 0, date: sample.startDate, source: sample.sourceRevision.source.name)
            entry.carbs += sample.quantity.doubleValue(for: .gram())
            merged[k] = entry
        }

        for sample in fats {
            let k = key(for: sample)
            var entry = merged[k] ?? (carbs: 0, fat: 0, protein: 0, date: sample.startDate, source: sample.sourceRevision.source.name)
            entry.fat += sample.quantity.doubleValue(for: .gram())
            merged[k] = entry
        }

        for sample in proteins {
            let k = key(for: sample)
            var entry = merged[k] ?? (carbs: 0, fat: 0, protein: 0, date: sample.startDate, source: sample.sourceRevision.source.name)
            entry.protein += sample.quantity.doubleValue(for: .gram())
            merged[k] = entry
        }

        return merged.values
            .map { HealthNutritionEntry(date: $0.date, carbs: $0.carbs, fat: $0.fat, protein: $0.protein, source: $0.source) }
            .sorted { $0.date < $1.date }
    }

    /// Group nutrition entries into meals based on time proximity.
    /// Entries within `mealGroupingWindow` of each other are grouped as one meal.
    private func groupEntriesIntoMeals(_ entries: [HealthNutritionEntry]) -> [HealthNutritionMeal] {
        guard !entries.isEmpty else { return [] }

        let sorted = entries.sorted { $0.date < $1.date }
        var meals: [HealthNutritionMeal] = []
        var currentGroup: [HealthNutritionEntry] = [sorted[0]]

        for i in 1 ..< sorted.count {
            let entry = sorted[i]
            let lastInGroup = currentGroup.last!

            if entry.date.timeIntervalSince(lastInGroup.date) <= mealGroupingWindow {
                currentGroup.append(entry)
            } else {
                // Finalize current group as a meal
                meals.append(mealFromEntries(currentGroup))
                currentGroup = [entry]
            }
        }

        // Finalize last group
        if !currentGroup.isEmpty {
            meals.append(mealFromEntries(currentGroup))
        }

        return meals
    }

    private func mealFromEntries(_ entries: [HealthNutritionEntry]) -> HealthNutritionMeal {
        let startTime = entries.map(\.date).min() ?? Date()
        let endTime = entries.map(\.date).max() ?? Date()
        let primarySource = entries.first?.source ?? ""

        return HealthNutritionMeal(
            startTime: startTime,
            endTime: endTime,
            entries: entries,
            source: primarySource
        )
    }
}
