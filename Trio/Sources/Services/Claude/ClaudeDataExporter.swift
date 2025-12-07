import CoreData
import Foundation
import Swinject

/// Exports diabetes data from Core Data for Claude analysis
final class ClaudeDataExporter: Injectable {
    @Injected() private var settingsManager: SettingsManager!

    private let viewContext: NSManagedObjectContext

    init(resolver: Resolver) {
        viewContext = CoreDataStack.shared.persistentContainer.viewContext
        injectServices(resolver)
    }

    // MARK: - Data Export Models

    struct ExportedData: Codable {
        let exportDate: String
        let daysIncluded: Int
        let units: String

        let glucoseReadings: [GlucoseReading]
        let carbEntries: [CarbEntry]
        let bolusEntries: [BolusEntry]
        let determinations: [DeterminationEntry]
        let currentSettings: CurrentSettings
    }

    struct GlucoseReading: Codable {
        let timestamp: String
        let value: Int
        let direction: String?
    }

    struct CarbEntry: Codable {
        let timestamp: String
        let carbs: Double
        let fat: Double
        let protein: Double
        let note: String?
    }

    struct BolusEntry: Codable {
        let timestamp: String
        let amount: Double
        let isSMB: Bool
        let isExternal: Bool
    }

    struct DeterminationEntry: Codable {
        let timestamp: String
        let iob: Double?
        let cob: Int?
        let eventualBG: Int?
        let insulinReq: Double?
        let rate: Double?
        let reason: String?
    }

    struct CurrentSettings: Codable {
        let basalProfile: [BasalEntry]
        let isfProfile: [ISFEntry]
        let crProfile: [CREntry]
        let targetGlucose: Int
        let maxIOB: Double
        let maxBolus: Double
        let dia: Double
    }

    struct BasalEntry: Codable {
        let start: String
        let rate: Double
    }

    struct ISFEntry: Codable {
        let start: String
        let sensitivity: Int
    }

    struct CREntry: Codable {
        let start: String
        let ratio: Double
    }

    // MARK: - Export Functions

    /// Export 7 days of data as a JSON string for Claude
    func exportDataAsJSON(days: Int = 7) async throws -> String {
        let data = try await exportData(days: days)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(data)
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    /// Export data as structured object
    func exportData(days: Int = 7) async throws -> ExportedData {
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        async let glucose = fetchGlucose(since: startDate, formatter: dateFormatter)
        async let carbs = fetchCarbs(since: startDate, formatter: dateFormatter)
        async let boluses = fetchBoluses(since: startDate, formatter: dateFormatter)
        async let determinations = fetchDeterminations(since: startDate, formatter: dateFormatter)
        let settings = await fetchCurrentSettings()

        return ExportedData(
            exportDate: dateFormatter.string(from: Date()),
            daysIncluded: days,
            units: settingsManager.settings.units.rawValue,
            glucoseReadings: try await glucose,
            carbEntries: try await carbs,
            bolusEntries: try await boluses,
            determinations: try await determinations,
            currentSettings: settings
        )
    }

    // MARK: - Fetch Functions

    private func fetchGlucose(since startDate: Date, formatter: ISO8601DateFormatter) async throws -> [GlucoseReading] {
        try await viewContext.perform {
            let request = GlucoseStored.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@", startDate as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: true)]

            let results = try self.viewContext.fetch(request)

            return results.compactMap { glucose -> GlucoseReading? in
                guard let date = glucose.date else { return nil }
                return GlucoseReading(
                    timestamp: formatter.string(from: date),
                    value: Int(glucose.glucose),
                    direction: glucose.direction
                )
            }
        }
    }

    private func fetchCarbs(since startDate: Date, formatter: ISO8601DateFormatter) async throws -> [CarbEntry] {
        try await viewContext.perform {
            let request = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@ AND carbs > 0", startDate as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CarbEntryStored.date, ascending: true)]

            let results = try self.viewContext.fetch(request)

            return results.compactMap { carb -> CarbEntry? in
                guard let date = carb.date else { return nil }
                return CarbEntry(
                    timestamp: formatter.string(from: date),
                    carbs: carb.carbs,
                    fat: carb.fat,
                    protein: carb.protein,
                    note: carb.note
                )
            }
        }
    }

    private func fetchBoluses(since startDate: Date, formatter: ISO8601DateFormatter) async throws -> [BolusEntry] {
        try await viewContext.perform {
            let request = PumpEventStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "timestamp >= %@ AND bolus != nil",
                startDate as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PumpEventStored.timestamp, ascending: true)]

            let results = try self.viewContext.fetch(request)

            return results.compactMap { event -> BolusEntry? in
                guard let date = event.timestamp,
                      let bolus = event.bolus,
                      let amount = bolus.amount?.doubleValue
                else { return nil }

                return BolusEntry(
                    timestamp: formatter.string(from: date),
                    amount: amount,
                    isSMB: bolus.isSMB,
                    isExternal: bolus.isExternal
                )
            }
        }
    }

    private func fetchDeterminations(since startDate: Date, formatter: ISO8601DateFormatter) async throws -> [DeterminationEntry] {
        try await viewContext.perform {
            let request = OrefDetermination.fetchRequest()
            request.predicate = NSPredicate(format: "deliverAt >= %@", startDate as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \OrefDetermination.deliverAt, ascending: true)]

            let results = try self.viewContext.fetch(request)

            // Sample every 15 minutes to reduce data size
            let sampledResults = results.enumerated().compactMap { index, item -> OrefDetermination? in
                index % 3 == 0 ? item : nil
            }

            return sampledResults.compactMap { det -> DeterminationEntry? in
                guard let date = det.deliverAt else { return nil }
                return DeterminationEntry(
                    timestamp: formatter.string(from: date),
                    iob: det.iob?.doubleValue,
                    cob: Int(det.cob),
                    eventualBG: det.eventualBG?.intValue,
                    insulinReq: det.insulinReq?.doubleValue,
                    rate: det.rate?.doubleValue,
                    reason: det.reason
                )
            }
        }
    }

    private func fetchCurrentSettings() async -> CurrentSettings {
        // Get settings from SettingsManager
        let settings = settingsManager.settings
        let preferences = settingsManager.preferences
        let pumpSettings = settingsManager.pumpSettings

        // These would typically come from the profile, using defaults for now
        return CurrentSettings(
            basalProfile: [], // TODO: Fetch from profile storage
            isfProfile: [],   // TODO: Fetch from profile storage
            crProfile: [],    // TODO: Fetch from profile storage
            targetGlucose: Int(truncating: (settings.low + settings.high) / 2 as NSNumber),
            maxIOB: Double(truncating: preferences.maxIOB as NSNumber),
            maxBolus: Double(truncating: pumpSettings.maxBolus as NSNumber),
            dia: Double(truncating: pumpSettings.insulinActionCurve as NSNumber)
        )
    }

    // MARK: - Summary Export (Compact format)

    /// Export a compact summary suitable for smaller context windows
    func exportSummary(days: Int = 7) async throws -> String {
        let data = try await exportData(days: days)

        var summary = """
        DIABETES DATA EXPORT - Last \(days) days
        Export Date: \(data.exportDate)
        Units: \(data.units)

        === GLUCOSE READINGS (\(data.glucoseReadings.count) total) ===
        """

        // Calculate stats
        let glucoseValues = data.glucoseReadings.map(\.value)
        if !glucoseValues.isEmpty {
            let avg = glucoseValues.reduce(0, +) / glucoseValues.count
            let min = glucoseValues.min() ?? 0
            let max = glucoseValues.max() ?? 0

            let inRange = glucoseValues.filter { $0 >= 70 && $0 <= 180 }.count
            let low = glucoseValues.filter { $0 < 70 }.count
            let high = glucoseValues.filter { $0 > 180 }.count
            let total = glucoseValues.count

            summary += """

            Average: \(avg) \(data.units)
            Min: \(min), Max: \(max)
            Time in Range (70-180): \(100 * inRange / total)%
            Time Low (<70): \(100 * low / total)%
            Time High (>180): \(100 * high / total)%

            Recent readings (last 24):
            """

            for reading in data.glucoseReadings.suffix(24) {
                summary += "\n  \(reading.timestamp): \(reading.value) \(reading.direction ?? "")"
            }
        }

        summary += "\n\n=== CARB ENTRIES (\(data.carbEntries.count) total) ===\n"
        for carb in data.carbEntries {
            summary += "\(carb.timestamp): \(Int(carb.carbs))g carbs"
            if carb.fat > 0 { summary += ", \(Int(carb.fat))g fat" }
            if carb.protein > 0 { summary += ", \(Int(carb.protein))g protein" }
            if let note = carb.note, !note.isEmpty { summary += " (\(note))" }
            summary += "\n"
        }

        summary += "\n=== BOLUS ENTRIES (\(data.bolusEntries.count) total) ===\n"
        let manualBoluses = data.bolusEntries.filter { !$0.isSMB }
        let smbBoluses = data.bolusEntries.filter { $0.isSMB }
        summary += "Manual boluses: \(manualBoluses.count)\n"
        summary += "SMB (auto) boluses: \(smbBoluses.count)\n"
        summary += "Total insulin: \(String(format: "%.1f", data.bolusEntries.map(\.amount).reduce(0, +)))U\n"

        summary += "\nRecent boluses:\n"
        for bolus in data.bolusEntries.suffix(20) {
            summary += "  \(bolus.timestamp): \(String(format: "%.2f", bolus.amount))U"
            if bolus.isSMB { summary += " (SMB)" }
            if bolus.isExternal { summary += " (external)" }
            summary += "\n"
        }

        summary += "\n=== LOOP DETERMINATIONS (sampled, \(data.determinations.count) entries) ===\n"
        for det in data.determinations.suffix(20) {
            summary += "\(det.timestamp): "
            if let iob = det.iob { summary += "IOB=\(String(format: "%.2f", iob))U " }
            if let cob = det.cob { summary += "COB=\(cob)g " }
            if let eventual = det.eventualBG { summary += "eventual=\(eventual) " }
            summary += "\n"
        }

        summary += """

        === CURRENT SETTINGS ===
        Target Glucose: \(data.currentSettings.targetGlucose) \(data.units)
        Max IOB: \(data.currentSettings.maxIOB)U
        Max Bolus: \(data.currentSettings.maxBolus)U
        DIA: \(data.currentSettings.dia) hours
        """

        return summary
    }
}
