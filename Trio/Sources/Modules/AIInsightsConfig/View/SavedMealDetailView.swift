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
    @State private var showBackfill = false
    @State private var startResult: String?
    @State private var bucketFilter: BucketFilter = .all
    @State private var conditionFilter: ConditionFilter = .normalOnly

    enum ConditionFilter: String, CaseIterable, Identifiable {
        case all, normalOnly, overrideAffected
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .normalOnly: return "Normal only"
            case .overrideAffected: return "⚠ Override"
            }
        }
    }

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
        let bucketed = SavedMealAnalytics.stratify(instances: instancesArray, bucket: bucketFilter.bucket)
        switch conditionFilter {
        case .all:
            return bucketed
        case .normalOnly:
            let normal = bucketed.filter { !$0.windowHadOverride && !$0.windowHadTempTarget }
            // Fallback: if filtering would empty the list, show all + an annotation
            // (rendered in the section header by hasOnlyOverrideAffected).
            return normal.isEmpty ? bucketed : normal
        case .overrideAffected:
            return bucketed.filter { $0.windowHadOverride || $0.windowHadTempTarget }
        }
    }

    /// True when every available instance is override-affected — surfaces a
    /// note in the section header so "Normal only" isn't silently empty.
    private var hasOnlyOverrideAffected: Bool {
        guard !instancesArray.isEmpty else { return false }
        return instancesArray.allSatisfy { $0.windowHadOverride || $0.windowHadTempTarget }
    }

    private var hasAnyData: Bool { !filteredInstances.isEmpty }

    /// The in-flight instance (window open) for this meal, if any.
    /// Phase F live-progress section renders only when this is non-nil.
    private var currentInstance: SavedMealInstance? {
        let all = (meal.instances?.allObjects as? [SavedMealInstance]) ?? []
        return all
            .filter { $0.closedAt == nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .first
    }

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

            if let current = currentInstance {
                currentlyActiveSection(current)
            }

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
                Section(
                    header: Text("Filter"),
                    footer: Group {
                        if hasOnlyOverrideAffected && conditionFilter == .normalOnly {
                            Text("All instances of this meal were override-affected — showing all instead.")
                                .foregroundStyle(.orange)
                        } else {
                            EmptyView()
                        }
                    }
                ) {
                    Picker("Carb bucket", selection: $bucketFilter) {
                        ForEach(BucketFilter.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Condition", selection: $conditionFilter) {
                        ForEach(ConditionFilter.allCases) { f in
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
                Button {
                    showBackfill = true
                } label: {
                    Label("Backfill from history", systemImage: "clock.arrow.circlepath")
                }
                Button("Duplicate") {
                    _ = storage?.duplicateMeal(meal)
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
        .sheet(isPresented: $showBackfill) {
            SavedMealBackfillPickerView(savedMeal: meal) { _ in
                // No further action needed — @FetchRequest will refresh the
                // history list when the new SavedMealInstance lands.
            }
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

    // MARK: - Currently active (Phase F)

    @ViewBuilder
    private func currentlyActiveSection(_ instance: SavedMealInstance) -> some View {
        Section(
            header: HStack {
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
                Text("Currently active")
            },
            footer: Text("Live snapshot — outcome metrics will appear once the window closes.")
        ) {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                liveContent(instance)
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private func liveContent(_ instance: SavedMealInstance) -> some View {
        let now = Date()
        let started = instance.startedAt ?? now
        let elapsed = now.timeIntervalSince(started)
        let elapsedH = Int(elapsed) / 3600
        let elapsedM = (Int(elapsed) % 3600) / 60

        let bgs = liveBGSamples(from: started, to: now)
        let latestBG = bgs.last.map { Int($0.bg) }
        let peakSoFar = bgs.map { $0.bg }.max().map { Int($0) }
        let cls = instance.finalClassification ?? instance.initialClassification ?? "simple"
        let smbs = liveSMBCount(from: started, to: now)
        let floors = Int(instance.floorActivationCount)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Elapsed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%dh %02dm", elapsedH, elapsedM))
                    .monospacedDigit().fontWeight(.medium)
            }

            HStack {
                Text("Now").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let bg = latestBG {
                    Text("\(bg) mg/dL").monospacedDigit().fontWeight(.medium)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Peak so far").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(peakSoFar.map { "\($0)" } ?? "—")
                    .monospacedDigit().fontWeight(.medium)
            }

            HStack {
                Text("Classification").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(cls.capitalized)
                    .foregroundStyle(colorForClassification(cls))
                    .fontWeight(.medium)
            }

            HStack(spacing: 16) {
                Label("\(smbs) SMBs", systemImage: "syringe")
                    .font(.caption).foregroundStyle(.secondary)
                Label("\(floors) floor", systemImage: "shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if !bgs.isEmpty {
                Chart {
                    ForEach(bgs.indices, id: \.self) { i in
                        LineMark(
                            x: .value("min", bgs[i].t),
                            y: .value("bg", bgs[i].bg)
                        )
                        .foregroundStyle(.green)
                    }
                }
                .frame(height: 120)
                .chartXAxisLabel("Min since start", alignment: .center)
                .chartYScale(domain: 40...300)
            }
        }
        .padding(.vertical, 6)
    }

    private func colorForClassification(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "complex": return .red
        case "medium": return .orange
        default: return .green
        }
    }

    /// Reads BG samples between two dates from CoreData. Returns time-from-start
    /// in minutes + BG mg/dL. Done lazily per refresh, no caching.
    private func liveBGSamples(from start: Date, to end: Date) -> [(t: Double, bg: Double)] {
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        var results: [(Double, Double)] = []
        ctx.performAndWait {
            let req = GlucoseStored.fetchRequest()
            req.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let samples = (try? ctx.fetch(req)) ?? []
            results = samples.compactMap { s in
                guard let d = s.date else { return nil }
                return (d.timeIntervalSince(start) / 60, Double(s.glucose))
            }
        }
        return results
    }

    /// Counts SMB events from PumpEventStored in the window.
    private func liveSMBCount(from start: Date, to end: Date) -> Int {
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        var count = 0
        ctx.performAndWait {
            let req = PumpEventStored.fetchRequest()
            req.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@ AND bolus != nil AND bolus.isSMB == YES",
                start as NSDate, end as NSDate
            )
            count = (try? ctx.count(for: req)) ?? 0
        }
        return count
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
                    ForEach(agg.perInstance.indices, id: \.self) { idx in
                        let series = agg.perInstance[idx]
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
                    ForEach(agg.timeBuckets.indices, id: \.self) { i in
                        AreaMark(
                            x: .value("Hours", agg.timeBuckets[i] / 60),
                            yStart: .value("p25", agg.p25[i]),
                            yEnd: .value("p75", agg.p75[i])
                        )
                        .foregroundStyle(.blue.opacity(0.18))
                    }
                    // Median line bold
                    ForEach(agg.timeBuckets.indices, id: \.self) { i in
                        LineMark(
                            x: .value("Hours", agg.timeBuckets[i] / 60),
                            y: .value("Median", agg.median[i]),
                            series: .value("MedianSeries", "median")
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
            HStack(spacing: 6) {
                if let started = instance.startedAt {
                    Text(started, style: .date).font(.subheadline)
                }
                if instance.backfilled {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if instance.windowHadOverride || instance.windowHadTempTarget {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
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
