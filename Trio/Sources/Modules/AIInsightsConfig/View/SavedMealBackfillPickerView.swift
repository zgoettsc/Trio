import CoreData
import SwiftUI
import Swinject

/// Phase E UI — retroactively attach a past eating event to a SavedMeal.
/// Surfaces both logged carb entries from the last 48h AND a custom-time
/// option for unlogged meals (the "I forgot to log but ate at 7pm" case).
struct SavedMealBackfillPickerView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let savedMeal: SavedMeal
    let onAttached: (UUID) -> Void  // instance UUID

    @State private var lookbackHours: Int = 48
    @State private var carbEntries: [CarbEntryStored] = []
    @State private var pickedAnchor: SavedMealBackfillService.AnchorType?
    @State private var preview: SavedMealBackfillService.Preview?
    @State private var showPreviewSheet = false

    @State private var showCustomTimeSheet = false
    @State private var customTime: Date = Date().addingTimeInterval(-3600)
    @State private var includeManualMacros = false
    @State private var manualCarbs: Double = 0
    @State private var manualFat: Double = 0
    @State private var manualProtein: Double = 0

    private let resolver: Resolver = TrioApp.resolver
    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }

    private var backfillService: SavedMealBackfillService? {
        guard let sm = settingsManager else { return nil }
        return SavedMealBackfillService(
            resolver: resolver,
            viewContext: CoreDataStack.shared.persistentContainer.viewContext,
            settingsManager: sm
        )
    }

    var body: some View {
        NavigationView {
            Form {
                lookbackSection
                customTimeSection
                carbEntriesSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Backfill: \(savedMeal.name ?? "Meal")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: loadEntries)
            .sheet(isPresented: $showCustomTimeSheet) {
                customTimePickerSheet
            }
            .sheet(isPresented: $showPreviewSheet) {
                previewSheet
            }
        }
    }

    // MARK: - Sections

    private var lookbackSection: some View {
        Section {
            Picker("Look back", selection: $lookbackHours) {
                Text("48 hours").tag(48)
                Text("7 days").tag(168)
            }
            .onChange(of: lookbackHours) { _, _ in loadEntries() }
        }
        .listRowBackground(Color.chart)
    }

    private var customTimeSection: some View {
        Section(
            header: Text("From a custom time"),
            footer: Text("Use when you ate but didn't log the carbs. Pick when, optionally enter macros.")
        ) {
            Button {
                customTime = Date().addingTimeInterval(-3600)
                includeManualMacros = false
                manualCarbs = 0; manualFat = 0; manualProtein = 0
                showCustomTimeSheet = true
            } label: {
                Label("Pick when I ate", systemImage: "clock")
            }
        }
        .listRowBackground(Color.chart)
    }

    private var carbEntriesSection: some View {
        Section(
            header: Text("From a logged carb entry"),
            footer: Text(carbEntries.isEmpty
                ? "No carb entries in this window."
                : "Tap to preview and attach.")
        ) {
            if carbEntries.isEmpty {
                Text("No entries").foregroundStyle(.secondary)
            } else {
                ForEach(carbEntries, id: \.objectID) { entry in
                    Button {
                        if let eid = entry.id {
                            pickedAnchor = .carbEntry(eid)
                            preview = backfillService?.preview(anchor: .carbEntry(eid))
                            showPreviewSheet = true
                        }
                    } label: {
                        entryRow(entry)
                    }
                }
            }
        }
        .listRowBackground(Color.chart)
    }

    private func entryRow(_ entry: CarbEntryStored) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let d = entry.date {
                    Text(d, style: .date).font(.caption2).foregroundStyle(.secondary)
                    Text(d, style: .time).font(.subheadline)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if entry.carbs > 0 { Text("\(Int(entry.carbs))c").font(.caption) }
                if entry.fat > 0 { Text("\(Int(entry.fat))f").font(.caption) }
                if entry.protein > 0 { Text("\(Int(entry.protein))p").font(.caption) }
                if let note = entry.note, !note.isEmpty {
                    Text("· \(note)").font(.caption).italic()
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Custom time sheet

    private var customTimePickerSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("When did you eat?")) {
                    DatePicker(
                        "Time",
                        selection: $customTime,
                        in: Date().addingTimeInterval(-Double(lookbackHours) * 3600) ... Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Optional: enter macros"),
                    footer: Text("Leave off if you don't know — the BG curve still tells the story.")
                ) {
                    Toggle("Include macros", isOn: $includeManualMacros)
                    if includeManualMacros {
                        macroSlider(label: "Carbs", value: $manualCarbs, range: 0...200, suffix: "g")
                        macroSlider(label: "Fat", value: $manualFat, range: 0...100, suffix: "g")
                        macroSlider(label: "Protein", value: $manualProtein, range: 0...100, suffix: "g")
                    }
                }
                .listRowBackground(Color.chart)

                Section {
                    Button("Preview") {
                        let m: SavedMealBackfillService.Preview.Macros? = includeManualMacros
                            ? .init(
                                carbs: manualCarbs > 0 ? Decimal(manualCarbs) : nil,
                                fat: manualFat > 0 ? Decimal(manualFat) : nil,
                                protein: manualProtein > 0 ? Decimal(manualProtein) : nil
                            )
                            : nil
                        let anchor = SavedMealBackfillService.AnchorType.customTime(customTime, manualMacros: m)
                        pickedAnchor = anchor
                        preview = backfillService?.preview(anchor: anchor)
                        showCustomTimeSheet = false
                        showPreviewSheet = true
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Custom time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCustomTimeSheet = false }
                }
            }
        }
    }

    private func macroSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: 5)
        }
    }

    // MARK: - Preview sheet

    private var previewSheet: some View {
        NavigationView {
            Form {
                if let p = preview {
                    previewContent(p)
                } else {
                    Section { Text("Preview unavailable").foregroundStyle(.secondary) }
                        .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPreviewSheet = false }
                }
                if preview != nil, pickedAnchor != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Attach", action: attach).bold()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func previewContent(_ p: SavedMealBackfillService.Preview) -> some View {
        Section(header: Text("Window")) {
            row("Started", value: p.anchorTimestamp.formatted(date: .abbreviated, time: .shortened))
            row("Ends", value: p.windowEnd.formatted(date: .abbreviated, time: .shortened))
            row("Reason", value: p.windowEndReason == .maxDuration
                ? "12-hour max"
                : "Next carb entry")
            row("BG samples", value: "\(p.bgSampleCount)")
            if p.sensorGapMinutes > 0 {
                row("Sensor gap", value: "\(p.sensorGapMinutes) min")
            }
        }.listRowBackground(Color.chart)

        Section(header: Text("Macros")) {
            row("Carbs", value: p.macros?.carbs.map { "\($0)" } ?? "—")
            row("Fat", value: p.macros?.fat.map { "\($0)" } ?? "—")
            row("Protein", value: p.macros?.protein.map { "\($0)" } ?? "—")
            if let suggested = p.suggestedMacrosFromNearbyEntry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found a carb entry \(suggested.entryDate.formatted(date: .omitted, time: .shortened)) within 30 min.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use those macros") {
                        // Re-preview with carb-entry anchor so window-end + macros come from the entry
                        let anchor: SavedMealBackfillService.AnchorType = .carbEntry(suggested.entryId)
                        pickedAnchor = anchor
                        preview = backfillService?.preview(anchor: anchor)
                    }
                    .font(.caption)
                }
            }
        }.listRowBackground(Color.chart)

        Section(header: Text("Outcome")) {
            row("Peak BG", value: "\(Int(p.outcomeMetrics.peakBG.rounded()))")
            row("Time in range", value: "\(p.outcomeMetrics.timeInRangeMinutes) min")
            row("Time above range", value: "\(p.outcomeMetrics.timeAboveRangeMinutes) min")
            row("Time below range", value: "\(p.outcomeMetrics.timeBelowRangeMinutes) min")
            row("Lows", value: "\(p.outcomeMetrics.lowsCount)")
            row("Insulin above baseline", value: String(format: "%.2f U", p.outcomeMetrics.totalInsulinDeliveredU))
            row("SMBs delivered", value: "\(p.outcomeMetrics.smbCount)")
            row("Outcome score", value: "\(p.outcomeScore)/100")
        }.listRowBackground(Color.chart)

        Section(
            header: Text("Historical data limitations"),
            footer: Text("Backfilled instances are reconstructed from pump history. One metric isn't reliable from historical data:\n\n• Floor activations — oref only logs them as reason-string text at run time, not as structured events. We can't tell after-the-fact how many of the SMBs above were floor-triggered. Displayed as “—” in this meal's stats.\n\nInsulin above baseline IS reliable from history — it's reconstructed from pump SMB events + temp basal records vs your scheduled basal.")
        ) {
            EmptyView()
        }.listRowBackground(Color.clear)

        Section(header: Text("Classification")) {
            row("Initial", value: p.classificationPath.initial.displayName)
            row("Final", value: p.classificationPath.final.displayName)
            if !p.classificationPath.upgrades.isEmpty,
               let first = p.classificationPath.upgrades.first
            {
                row(
                    "Upgrade",
                    value: "\(first.from) → \(first.to) at +\(Int(first.t)) min"
                )
            }
        }.listRowBackground(Color.chart)

        if p.overrideContext.hadOverride || p.overrideContext.hadTempTarget {
            Section(
                header: Text("⚠ Unusual conditions"),
                footer: Text("This instance will be tagged. Composite stats default to filtering it out unless you ask for it.")
            ) {
                if p.overrideContext.hadOverride {
                    row("Override", value: p.overrideContext.overrideName ?? "(unnamed)")
                    row("Override duration", value: "\(p.overrideContext.overrideMinutes) min")
                    row("SMBs suppressed", value: p.overrideContext.suppressedSMB ? "Yes" : "No")
                }
                if p.overrideContext.hadTempTarget {
                    row("Temp target", value: p.overrideContext.tempTargetName ?? "(unnamed)")
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func loadEntries() {
        carbEntries = backfillService?.fetchAttachableCarbEntries(within: lookbackHours) ?? []
    }

    private func attach() {
        guard let mealId = savedMeal.id, let anchor = pickedAnchor else { return }
        if let instId = backfillService?.backfill(savedMealId: mealId, anchor: anchor) {
            onAttached(instId)
        }
        showPreviewSheet = false
        dismiss()
    }
}
