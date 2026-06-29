import CoreData
import Foundation
import SwiftUI
import Swinject

/// Sheet for logging rescue carbs to treat a low. Two modes:
///
/// - **Preset:** tap a curated item (juice box, glucose tabs, granola
///   bar, etc.) → carbs/fat/protein pre-fill → tap Save.
/// - **Custom:** type your own carbs, optional fat/protein.
///
/// Either path writes a `CarbsEntry` with `isRescueCarbs = true` so
/// oref's meal.json builder filters it out — the loop never sees the
/// COB bump and won't dose against the carbs the user just ate to
/// recover from a low.
///
/// Telemetry fires a `rescueCarbsLogged` event with the preset name
/// (when picked) + macros + BG context, so per-preset BG-recovery
/// curves can be analyzed downstream — does a granola bar yield a
/// more durable recovery than jelly beans? The data will tell.
struct RescueCarbsSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private let resolver: Resolver = TrioApp.resolver

    @State private var step: Step = .picker
    @State private var pickedPreset: RescuePreset?
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var proteinText: String = ""
    @State private var isSaving: Bool = false

    enum Step { case picker, confirm }

    var presets: [RescuePreset] {
        resolver.resolve(SettingsManager.self)?.settings.rescuePresets ?? RescuePreset.defaults
    }

    var body: some View {
        NavigationView {
            Group {
                switch step {
                case .picker:
                    pickerForm
                case .confirm:
                    confirmForm
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(step == .picker ? "Rescue" : "Confirm rescue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == .confirm {
                        Button("Back") {
                            step = .picker
                            pickedPreset = nil
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pickerForm: some View {
        Form {
            Section {
                Label("These carbs won't be dosed against by the loop", systemImage: "shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Quick picks")) {
                ForEach(presets) { preset in
                    Button {
                        select(preset: preset)
                    } label: {
                        HStack(spacing: 12) {
                            Text(preset.emoji ?? "🍬").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text("\(format(preset.carbs)) g")
                                    if let f = preset.fat { Text("· \(format(f))f").foregroundStyle(.secondary) }
                                    if let p = preset.protein { Text("· \(format(p))p").foregroundStyle(.secondary) }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let notes = preset.notes {
                                    Text(notes)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Custom")) {
                Button {
                    pickedPreset = nil
                    carbsText = ""
                    fatText = ""
                    proteinText = ""
                    step = .confirm
                } label: {
                    Label("Type rescue carbs manually", systemImage: "pencil")
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    @ViewBuilder
    private var confirmForm: some View {
        Form {
            if let p = pickedPreset {
                Section(header: Text(p.name)) {
                    if let notes = p.notes {
                        Text(notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.chart)
            }

            Section(
                header: Text("Carbs (g)"),
                footer: Text("Required. Fast carbs you're eating to treat the low.")
            ) {
                TextField("0", text: $carbsText)
                    .keyboardType(.decimalPad)
                    .font(.title3)
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Fat (g) — optional"),
                footer: Text("Leave blank if unknown. Fat slows recovery but makes it more durable.")
            ) {
                TextField("", text: $fatText)
                    .keyboardType(.decimalPad)
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Protein (g) — optional"),
                footer: Text("Leave blank if unknown.")
            ) {
                TextField("", text: $proteinText)
                    .keyboardType(.decimalPad)
            }
            .listRowBackground(Color.chart)

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView()
                            Text("Saving…")
                        } else {
                            Label("Log rescue carbs", systemImage: "shield.fill")
                        }
                    }
                }
                .disabled(parsedCarbs <= 0 || isSaving)
            }
            .listRowBackground(Color.chart)
        }
    }

    private func select(preset: RescuePreset) {
        pickedPreset = preset
        carbsText = format(preset.carbs)
        fatText = preset.fat.map(format) ?? ""
        proteinText = preset.protein.map(format) ?? ""
        step = .confirm
    }

    private var parsedCarbs: Decimal {
        Decimal(string: carbsText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
    private var parsedFat: Decimal? {
        fatText.isEmpty ? nil : Decimal(string: fatText.replacingOccurrences(of: ",", with: "."))
    }
    private var parsedProtein: Decimal? {
        proteinText.isEmpty ? nil : Decimal(string: proteinText.replacingOccurrences(of: ",", with: "."))
    }

    private func format(_ d: Decimal) -> String {
        let dn = NSDecimalNumber(decimal: d).doubleValue
        return dn.rounded() == dn ? "\(Int(dn))" : String(format: "%.1f", dn)
    }

    @MainActor
    private func save() async {
        let carbsValue = parsedCarbs
        guard carbsValue > 0 else { return }
        isSaving = true

        let now = Date()
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: now,
            actualDate: now,
            carbs: carbsValue,
            fat: parsedFat,
            protein: parsedProtein,
            note: pickedPreset.map { "Rescue: \($0.name)" } ?? "Rescue (custom)",
            enteredBy: CarbsEntry.rescueCarbs,
            isFPU: false,
            fpuID: nil,
            isRescueCarbs: true,
            rescuePresetName: pickedPreset?.name
        )

        let carbsStorage = resolver.resolve(CarbsStorage.self)
        let apsManager = resolver.resolve(APSManager.self)
        let telemetry = resolver.resolve(AlgorithmTelemetryManager.self)
        let settingsManager = resolver.resolve(SettingsManager.self)

        try? await carbsStorage?.storeCarbs([entry], areFetchedFromRemote: false)

        // Telemetry: log the rescue event with BG context for later
        // per-preset recovery-curve analysis.
        var payload: [String: AlgorithmTelemetryJSONValue] = [
            "carbs": .double(NSDecimalNumber(decimal: carbsValue).doubleValue),
            "presetName": pickedPreset.map { .string($0.name) } ?? .null,
            "custom": .bool(pickedPreset == nil)
        ]
        if let f = parsedFat { payload["fat"] = .double(NSDecimalNumber(decimal: f).doubleValue) }
        if let p = parsedProtein { payload["protein"] = .double(NSDecimalNumber(decimal: p).doubleValue) }
        // BG context — latest GlucoseStored row.
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        ctx.performAndWait {
            let req = GlucoseStored.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            req.fetchLimit = 1
            if let latest = (try? ctx.fetch(req))?.first {
                payload["bgAtLog"] = .double(Double(latest.glucose))
            }
        }
        if let s = settingsManager?.settings, s.mealWindowActivationDate != nil {
            payload["duringMealWindow"] = .bool(true)
        } else {
            payload["duringMealWindow"] = .bool(false)
        }

        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .rescueCarbsLogged,
            timestamp: now,
            windowId: settingsManager?.settings.mealWindowId,
            payload: payload
        ))

        // Re-run determine-basal so the loop's state refreshes without
        // the rescue carbs in COB (filtered upstream).
        try? await apsManager?.determineBasalSync()

        isSaving = false
        dismiss()
    }
}
