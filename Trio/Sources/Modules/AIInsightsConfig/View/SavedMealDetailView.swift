import Charts
import CoreData
import SwiftUI
import Swinject

/// Per-meal detail view. Phase B ships with basic stats + edit/duplicate/delete
/// + a list of instances. Phase C adds composite curves, checkpoint tables,
/// and size-stratified analytics.
struct SavedMealDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @ObservedObject var meal: SavedMeal

    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var startResult: String?
    @State private var bucketFilter: BucketFilter = .all

    enum BucketFilter: String, CaseIterable, Identifiable {
        case all, small, medium, large
        var id: String { rawValue }
        var bucket: SavedMealInstance.CarbBucket? {
            switch self {
            case .all: return nil
            case .small: return .small
            case .medium: return .medium
            case .large: return .large
            }
        }
        var label: String {
            switch self {
            case .all: return "All"
            case .small: return "<40g"
            case .medium: return "40-80g"
            case .large: return "80g+"
            }
        }
    }

    private let resolver: Resolver = TrioApp.resolver
    private var storage: SavedMealStorage? { resolver.resolve(SavedMealStorage.self) }

    private var instancesArray: [SavedMealInstance] {
        let all = (meal.instances?.allObjects as? [SavedMealInstance]) ?? []
        return all
            .filter { $0.closedAt != nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    private var filteredInstances: [SavedMealInstance] {
        SavedMealAnalytics.stratify(instances: instancesArray, bucket: bucketFilter.bucket)
    }

    private var hasAnyData: Bool { !filteredInstances.isEmpty }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(meal.icon ?? "🍽️").font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(meal.name ?? "(unnamed)").font(.title2.bold())
                        Text("\(meal.cachedInstanceCount) instance\(meal.cachedInstanceCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await startMeal() }
                } label: {
                    Label("Start eating mode with this meal", systemImage: "play.circle.fill")
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Seeded behavior")) {
                statRow("Carbs default", value: meal.defaultCarbs.map { "\($0.intValue)g" } ?? "—")
                statRow("Fat default", value: meal.defaultFat.map { "\($0.intValue)g" } ?? "—")
                statRow("Protein default", value: meal.defaultProtein.map { "\($0.intValue)g" } ?? "—")
                statRow("Classification", value: (meal.defaultClassification ?? "auto").capitalized)
                if meal.defaultExtendedDurationMinutes > 0 {
                    statRow(
                        "Extended duration",
                        value: String(format: "%.1f h", Double(meal.defaultExtendedDurationMinutes) / 60)
                    )
                }
                if meal.defaultPhantomCOBEnabled {
                    statRow("Phantom COB", value: meal.defaultPhantomCOBGrams.map { "\($0.intValue)g" } ?? "default")
                }
            }
            .listRowBackground(Color.chart)

            if !instancesArray.isEmpty {
                // Stratification picker
                Section(header: Text("Filter by carb size")) {
                    Picker("Carb bucket", selection: $bucketFilter) {
                        ForEach(BucketFilter.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.chart)

                // Composite BG curve
                if hasAnyData {
                    analyticsSection
                }

                Section(header: Text("History (\(filteredInstances.count))")) {
                    ForEach(filteredInstances, id: \.objectID) { instance in
                        InstanceRow(instance: instance)
                    }
                }
                .listRowBackground(Color.chart)
            } else {
                Section(
                    footer: Text("No closed instances yet. Start this meal a few times to build up the BG-response history for analytics.")
                ) {
                    Text("No history yet").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)
            }

            if let result = startResult {
                Section { Text(result).foregroundColor(.secondary) }
                    .listRowBackground(Color.chart)
            }

            Section {
                Button("Duplicate") {
                    storage?.duplicateMeal(meal)
                    dismiss()
                }
                Button("Delete", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(meal.name ?? "Meal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationView { SavedMealEditView(meal: meal) }
        }
        .confirmationDialog(
            "Delete \(meal.name ?? "this meal") and all its history?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                storage?.deleteMeal(meal)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @MainActor
    private func startMeal() async {
        guard #available(iOS 16.0, *), let mealId = meal.id else { return }
        let req = AnnounceMealIntentRequest()
        do {
            let carbs = meal.defaultCarbs.map { $0 as Decimal }
            startResult = try await req.announce(estimatedCarbs: carbs, savedMealId: mealId)
        } catch {
            startResult = "Failed to start: \(error.localizedDescription)"
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    // MARK: - Analytics

    @ViewBuilder
    private var analyticsSection: some View {
        let agg = SavedMealAnalytics.aggregate(instances: filteredInstances)
        let timings = SavedMealAnalytics.keyTimings(from: agg, baselineBG: nil)
        let checks = SavedMealAnalytics.checkpoints(instances: filteredInstances)
        let burden = SavedMealAnalytics.insulinBurden(instances: filteredInstances)
        let outcome = SavedMealAnalytics.outcome(instances: filteredInstances)
        let classStats = SavedMealAnalytics.classificationStats(instances: filteredInstances)

        // Composite curve
        Section(header: Text("Composite BG curve")) {
            if agg.timeBuckets.isEmpty {
                Text("No BG data captured yet").foregroundStyle(.secondary).font(.caption)
            } else {
                Chart {
                    // Per-instance light overlays
                    ForEach(Array(agg.perInstance.enumerated()), id: \.offset) { _, series in
                        ForEach(series) { p in
                            LineMark(
                                x: .value("Hours", p.t / 60),
                                y: .value("BG", p.bg),
                                series: .value("Series", p.seriesId)
                            )
                            .foregroundStyle(.gray.opacity(0.25))
                        }
                    }
                    // 25-75 percentile band
                    ForEach(Array(agg.timeBuckets.enumerated()), id: \.offset) { i, t in
                        AreaMark(
                            x: .value("Hours", t / 60),
                            yStart: .value("p25", agg.p25[i]),
                            yEnd: .value("p75", agg.p75[i])
                        )
                        .foregroundStyle(.blue.opacity(0.18))
                    }
                    // Median line bold
                    ForEach(Array(agg.timeBuckets.enumerated()), id: \.offset) { i, t in
                        LineMark(
                            x: .value("Hours", t / 60),
                            y: .value("Median", agg.median[i])
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                }
                .frame(height: 200)
                .chartXAxisLabel("Hours since meal", alignment: .center)
                .chartYAxisLabel("BG mg/dL", position: .leading)
            }
        }
        .listRowBackground(Color.chart)

        // Key timings
        Section(header: Text("Key timings (median)")) {
            if let p = timings.initialPeak {
                timingRow("Initial peak", time: p.t, bg: p.bg)
            }
            if let t = timings.trough {
                timingRow("Trough after peak", time: t.t, bg: t.bg)
            }
            if let p = timings.latePeak {
                timingRow("Late peak (fat)", time: p.t, bg: p.bg)
            }
            if let r = timings.returnToBaseline {
                HStack {
                    Text("Return to baseline")
                    Spacer()
                    Text("+\(Int(r)) min").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .listRowBackground(Color.chart)

        // Checkpoints
        if !checks.isEmpty {
            Section(header: Text("BG at checkpoints")) {
                ForEach(checks, id: \.label) { c in
                    HStack {
                        Text(c.label)
                        Spacer()
                        Text("\(Int(c.median.rounded())) (\(Int(c.range.0))–\(Int(c.range.1)))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        // Insulin burden
        Section(header: Text("Insulin burden (median per instance)")) {
            statRow("Total delivered", value: String(format: "%.1f U", burden.medianTotalU))
            statRow("SMBs fired", value: "\(burden.medianSMBCount)")
            statRow("Floor activations", value: "\(burden.medianFloorCount)")
        }
        .listRowBackground(Color.chart)

        // Classification
        Section(header: Text("Classification")) {
            statRow(
                "Upgraded mid-window",
                value: "\(classStats.upgradedMidWindow)/\(classStats.total)"
            )
            if let avg = classStats.medianUpgradeMinutes {
                statRow("Avg upgrade time", value: "+\(Int(avg)) min")
            }
            if let rec = classStats.recommendedClassification {
                statRow("Recommended default", value: rec.capitalized)
            }
        }
        .listRowBackground(Color.chart)

        // Outcome
        Section(header: Text("Outcome (median)")) {
            statRow("Score", value: "\(outcome.medianScore)/100")
            statRow("Time in range", value: "\(outcome.medianTIRPercent)%")
            statRow("Peak BG", value: "\(Int(outcome.medianPeak.rounded()))")
            statRow("Lows during window", value: "\(outcome.medianLowsCount)")
            statRow(
                "Window duration",
                value: String(format: "%dh %dm",
                    outcome.medianWindowDurationMinutes / 60,
                    outcome.medianWindowDurationMinutes % 60)
            )
        }
        .listRowBackground(Color.chart)
    }

    private func timingRow(_ label: String, time: Double, bg: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("+\(Int(time)) min @ \(Int(bg.rounded()))")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct InstanceRow: View {
    @ObservedObject var instance: SavedMealInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let started = instance.startedAt {
                    Text(started, style: .date).font(.subheadline)
                }
                Spacer()
                if let cls = instance.finalClassification {
                    Text(cls.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if let c = instance.carbsAtActivation {
                    Text("\(c.intValue)c").font(.caption)
                }
                if let f = instance.fatAtActivation {
                    Text("\(f.intValue)f").font(.caption)
                }
                if let p = instance.proteinAtActivation {
                    Text("\(p.intValue)p").font(.caption)
                }
                if instance.peakBG > 0 {
                    Text("peak \(Int(instance.peakBG))").font(.caption)
                }
                if instance.outcomeScore > 0 {
                    Text("score \(instance.outcomeScore)/100").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
