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

    /// Start observing Apple Health for nutrition changes and record snapshots
    func startObservingNutritionChanges()

    /// Stop observing nutrition changes
    func stopObservingNutritionChanges()

    /// Get inferred meal events for a specific date from snapshot deltas
    func inferredMealEvents(for date: Date) -> [InferredMealEvent]

    /// Query current cumulative nutrition totals from Apple Health and return
    /// the delta since the last snapshot (i.e. the most recently logged food).
    func fetchLatestMealDelta() async -> InferredMealEvent?
}

final class BaseNutritionHealthService: NutritionHealthService, Injectable {
    @Injected() private var healthKitStore: HKHealthStore!
    @Injected() private var settingsManager: SettingsManager!

    /// Calendar for day-based grouping
    private let calendar = Calendar.current

    /// Bundle identifier prefix for Trio to filter out its own entries
    private let trioBundlePrefix = "org.nightscout"

    /// Active observer query for nutrition changes
    private var observerQuery: HKObserverQuery?

    /// Snapshot store for tracking changes
    private let snapshotStore = NutritionSnapshotStore.shared

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

        debug(.service, "Nutrition fetch: \(carbs.count) carb samples, \(fats.count) fat samples, \(proteins.count) protein samples")
        for sample in carbs.prefix(3) {
            debug(
                .service,
                "  Carb sample: \(sample.quantity.doubleValue(for: .gram()))g start=\(sample.startDate) end=\(sample.endDate) metadata=\(sample.metadata ?? [:]) from \(sample.sourceRevision.source.name)"
            )
        }

        // Merge samples by timestamp and source into unified nutrition entries
        return mergeNutritionSamples(carbs: carbs, fats: fats, proteins: proteins)
    }

    // MARK: - Fetch Meals

    func fetchMeals(from startDate: Date, to endDate: Date) async throws -> [HealthNutritionMeal] {
        let entries = try await fetchNutritionEntries(from: startDate, to: endDate)
        return groupEntriesByDay(entries)
    }

    func fetchRecentMeals(hours: Int) async throws -> [HealthNutritionMeal] {
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-TimeInterval(hours * 3600))
        return try await fetchMeals(from: startDate, to: endDate)
    }

    // MARK: - Observer Query (Real-time Change Detection)

    func startObservingNutritionChanges() {
        guard isAvailable else { return }
        guard observerQuery == nil else { return } // Already observing

        guard let carbType = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates) else { return }

        // Set up observer query — HK will call our handler when new carb samples appear
        let query = HKObserverQuery(sampleType: carbType, predicate: nil) { [weak self] _, completionHandler, error in
            guard let self = self else {
                completionHandler()
                return
            }

            if let error = error {
                debug(.service, "Nutrition observer error: \(error.localizedDescription)")
                completionHandler()
                return
            }

            debug(.service, "Nutrition observer: change detected in Apple Health")

            // Record a snapshot of today's current totals
            Task {
                await self.recordNutritionSnapshot()
                completionHandler()
            }
        }

        healthKitStore.execute(query)
        observerQuery = query

        // Enable background delivery so we get notified even when app is backgrounded
        healthKitStore.enableBackgroundDelivery(for: carbType, frequency: .immediate) { success, error in
            if success {
                debug(.service, "Nutrition background delivery enabled")
            } else if let error = error {
                debug(.service, "Failed to enable nutrition background delivery: \(error.localizedDescription)")
            }
        }

        debug(.service, "Started observing Apple Health nutrition changes")

        // Record an initial snapshot
        Task {
            await recordNutritionSnapshot()
        }
    }

    func stopObservingNutritionChanges() {
        if let query = observerQuery {
            healthKitStore.stop(query)
            observerQuery = nil
            debug(.service, "Stopped observing Apple Health nutrition changes")
        }
    }

    func inferredMealEvents(for date: Date) -> [InferredMealEvent] {
        snapshotStore.inferredMealEvents(for: date)
    }

    /// Query current cumulative totals from Apple Health, save a snapshot,
    /// and return the delta from the previous snapshot (= latest food logged).
    func fetchLatestMealDelta() async -> InferredMealEvent? {
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        do {
            let entries = try await fetchNutritionEntries(from: today, to: tomorrow)
            let totalCarbs = entries.reduce(0) { $0 + $1.carbs }
            let totalFat = entries.reduce(0) { $0 + $1.fat }
            let totalProtein = entries.reduce(0) { $0 + $1.protein }

            debug(
                .service,
                "Crono button: HealthKit current totals C=\(Int(totalCarbs))g F=\(Int(totalFat))g P=\(Int(totalProtein))g"
            )

            return snapshotStore.recordAndComputeLatestMeal(
                currentCarbs: totalCarbs,
                currentFat: totalFat,
                currentProtein: totalProtein
            )
        } catch {
            debug(.service, "Crono button: Failed to query HealthKit: \(error.localizedDescription)")
            return nil
        }
    }

    /// Query today's cumulative nutrition totals and save a snapshot
    private func recordNutritionSnapshot() async {
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        do {
            let entries = try await fetchNutritionEntries(from: today, to: tomorrow)
            let totalCarbs = entries.reduce(0) { $0 + $1.carbs }
            let totalFat = entries.reduce(0) { $0 + $1.fat }
            let totalProtein = entries.reduce(0) { $0 + $1.protein }

            let snapshot = NutritionSnapshot(
                cumulativeCarbs: totalCarbs,
                cumulativeFat: totalFat,
                cumulativeProtein: totalProtein,
                forDate: today
            )
            snapshotStore.saveSnapshot(snapshot)

            debug(
                .service,
                "Nutrition snapshot recorded: C=\(Int(totalCarbs))g F=\(Int(totalFat))g P=\(Int(totalProtein))g"
            )
        } catch {
            debug(.service, "Failed to record nutrition snapshot: \(error.localizedDescription)")
        }
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

    /// Group nutrition entries by calendar day.
    /// Cronometer writes all entries at midnight, so day-based grouping is the correct approach.
    private func groupEntriesByDay(_ entries: [HealthNutritionEntry]) -> [HealthNutritionDay] {
        guard !entries.isEmpty else { return [] }

        var dayGroups: [Date: [HealthNutritionEntry]] = [:]

        for entry in entries {
            let dayStart = calendar.startOfDay(for: entry.date)
            dayGroups[dayStart, default: []].append(entry)
        }

        return dayGroups.map { dayDate, dayEntries in
            HealthNutritionDay(
                date: dayDate,
                entries: dayEntries,
                source: dayEntries.first?.source ?? ""
            )
        }
        .sorted { $0.date > $1.date } // Most recent first
    }
}
