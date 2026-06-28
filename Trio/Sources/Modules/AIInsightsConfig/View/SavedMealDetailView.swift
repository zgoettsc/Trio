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
        case all, normalOnly, overrideAffected, liveOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .normalOnly: return "Normal"
            case .overrideAffected: return "⚠ Override"
            case .liveOnly: return "Live only"
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
        case .liveOnly:
            // Live-tracked instances only — excludes backfilled rows from
            // the composite curve + all medians. Useful when the user wants
            // a "pure" view of how the meal has performed under live tracking.
            let live = bucketed.filter { !$0.backfilled }
            return live.isEmpty ? bucketed : live
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

                sensitivityScatterSection
                calibrationAggregateSection
                carbCountFeedbackSection

                Section(
                    header: Text("History (\(filteredInstances.count))"),
                    footer: Text("Swipe a row to delete a single instance.")
                ) {
                    ForEach(filteredInstances, id: \.objectID) { instance in
                        NavigationLink(destination: SavedMealInstanceDetailView(instance: instance)) {
                            InstanceRow(instance: instance)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            if let id = filteredInstances[index].id {
                                storage?.deleteInstance(id: id)
                            }
                        }
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
            startResult = try await req.startMealAndLogCarbs(savedMealId: mealId)
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
        let hasBackfilled = filteredInstances.contains { $0.backfilled }
        Section(
            header: Text("Insulin burden (median per instance)"),
            footer: hasBackfilled
                ? Text("Insulin above baseline = SMBs + (high temps - low temps) vs your scheduled basal. Floor activations are from live-tracked instances only — backfilled rows can't reconstruct floor events from history.")
                : Text("Insulin above baseline = SMBs + (high temps - low temps) vs your scheduled basal.")
        ) {
            statRow("Insulin above baseline", value: String(format: "%.1f U", burden.medianTotalU))
            statRow("SMBs fired", value: "\(burden.medianSMBCount)")
            statRow("Floor activations", value: burden.medianFloorCount < 0 ? "— (no live data)" : "\(burden.medianFloorCount)")
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

    // MARK: - Sensitivity scatter (v2 spec Feature 3)

    /// Each instance is a dot: x = autosens ratio at activation, y = peak Δ
    /// above baseline. Tells you whether the loop's sensitivity reading
    /// actually predicts how big this meal's excursion will be.
    @ViewBuilder
    private var sensitivityScatterSection: some View {
        let points = filteredInstances.compactMap { inst -> (x: Double, y: Double, label: Date?)? in
            guard let ratio = inst.autosensRatioAtActivation?.doubleValue, ratio > 0,
                  let bgStart = inst.bgAtActivation?.doubleValue, bgStart > 0,
                  inst.peakBG > 0
            else { return nil }
            let peakDelta = inst.peakBG - bgStart
            return (ratio, peakDelta, inst.startedAt)
        }
        if points.count >= 3 {
            Section(
                header: Text("Sensitivity vs excursion"),
                footer: Text("Each dot is one instance. X = Autosens at activation, Y = peak Δ above starting BG. Negative slope means the loop already compensates for sensitivity (good). Flat slope means Autosens is noise for this meal. Positive slope means the sensor flags resistance and dosing isn't catching up.")
            ) {
                Chart {
                    ForEach(points.indices, id: \.self) { idx in
                        let p = points[idx]
                        PointMark(
                            x: .value("Autosens", p.x),
                            y: .value("Peak Δ", p.y)
                        )
                        .foregroundStyle(.purple.opacity(0.7))
                        .symbolSize(50)
                    }
                    RuleMark(x: .value("Neutral", 1.0))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .frame(height: 200)
                .chartXAxisLabel("Autosens ratio")
                .chartYAxisLabel("Peak Δ (mg/dL)")
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.chart)
        }
    }

    // MARK: - Calibration aggregate (inverse CR/ISF)

    /// Aggregates back-calc CR + ISF across verified instances. Tighter
    /// signal than the forward estimator because verified carbs are
    /// ground truth — the math says "given your meal really was N g,
    /// what CR/ISF would explain the BG response?" Cross-check against
    /// the user's current profile to flag drift.
    @ViewBuilder
    private var calibrationAggregateSection: some View {
        let verified = filteredInstances.filter {
            ($0.userVerifiedCarbsAmount?.doubleValue ?? 0) > 0
        }
        if !verified.isEmpty {
            let agg = InverseCalibrator.aggregate(instances: verified)
            Section(
                header: Text("Calibration (verified meals)"),
                footer: Text(agg.footnote)
            ) {
                statRow("Verified instances", value: "\(agg.instanceCount)")
                if let cr = agg.medianBackCalcCR, let current = agg.currentCR {
                    aggCalibRow(
                        label: "Median back-calc CR",
                        value: String(format: "%.1f g/U", cr),
                        current: String(format: "%.1f", current),
                        deltaPercent: agg.deltaCRPercent
                    )
                }
                if let isf = agg.medianBackCalcISF, let current = agg.currentISF {
                    aggCalibRow(
                        label: "Median back-calc ISF",
                        value: "\(Int(isf.rounded())) mg/dL/U",
                        current: "\(Int(current.rounded()))",
                        deltaPercent: agg.deltaISFPercent
                    )
                } else if agg.usedISFIndeterminateCount == agg.instanceCount, agg.instanceCount > 0 {
                    HStack {
                        Text("Median back-calc ISF")
                        Spacer()
                        Text("indeterminate").foregroundStyle(.secondary).font(.caption)
                    }
                }
                if agg.instanceCount < 3 {
                    Label("Need ≥3 verified meals before changing your profile based on this.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    private func aggCalibRow(label: String, value: String, current: String, deltaPercent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value).fontWeight(.semibold).monospacedDigit()
            }
            HStack {
                Text("vs current \(current)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let pct = deltaPercent {
                    let color: Color = {
                        let a = Swift.abs(pct)
                        if a < 10 { return .green }
                        if a < 25 { return .orange }
                        return .red
                    }()
                    Text("\(pct >= 0 ? "+" : "")\(String(format: "%.1f", pct))%")
                        .font(.caption)
                        .foregroundStyle(color)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Carb-count feedback (v2 spec Feature 4)

    /// Aggregates the per-instance estimator across all qualifying instances
    /// and surfaces the median Δ vs entered. When the meal is consistently
    /// under-counted by ≥20g across ≥3 instances, suggests bumping the
    /// SavedMeal's default carbs.
    @ViewBuilder
    private var carbCountFeedbackSection: some View {
        // Reliable subset only: skip override-affected and not-returned-to-baseline.
        let reliable = filteredInstances.filter {
            !$0.windowHadOverride && !$0.windowHadTempTarget
        }
        let estimates = reliable.compactMap { inst -> (entered: Double, estimated: Double)? in
            guard let bgStart = inst.bgAtActivation?.doubleValue, bgStart > 0,
                  inst.peakBG > 0,
                  let isf = inst.effectiveISFAtActivation?.doubleValue, isf > 0,
                  let cr = inst.carbRatioAtActivation?.doubleValue, cr > 0
            else { return nil }
            let entered = inst.carbsAtActivation?.doubleValue ?? 0
            let rise = max(0, inst.peakBG - bgStart)
            let insulin = max(0, inst.totalInsulinDeliveredU)
            let est = rise * cr / isf + insulin * cr
            return (entered, est)
        }
        if estimates.count >= 3 {
            let medianEntered = estimates.map(\.entered).sorted()[estimates.count / 2]
            let medianEstimated = estimates.map(\.estimated).sorted()[estimates.count / 2]
            let medianDelta = medianEstimated - medianEntered
            let deltaColor: Color = {
                if abs(medianDelta) < 20 { return .green }
                if abs(medianDelta) < 50 { return .orange }
                return .red
            }()
            let suggestion = max(medianEntered, medianEntered + medianDelta)
            Section(
                header: Text("Carb-count feedback"),
                footer: Text("Estimated from BG response across \(estimates.count) reliable instances (override-affected and didn't-return-to-baseline excluded). When the meal consistently behaves bigger than the entered count, raise the saved meal's default to match.")
            ) {
                HStack {
                    Text("Instances analyzed").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(estimates.count)").monospacedDigit()
                }
                HStack {
                    Text("Median entered").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(medianEntered.rounded())) g").monospacedDigit()
                }
                HStack {
                    Text("Median estimated").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(medianEstimated.rounded())) g").monospacedDigit()
                }
                HStack {
                    Text("Median Δ vs entered")
                    Spacer()
                    Text("\(medianDelta >= 0 ? "+" : "")\(Int(medianDelta.rounded())) g")
                        .foregroundStyle(deltaColor)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                if abs(medianDelta) >= 20 {
                    Button {
                        showEdit = true
                    } label: {
                        Label("Bump default to \(Int(suggestion.rounded())) g", systemImage: "wrench.adjustable")
                    }
                }
            }
            .listRowBackground(Color.chart)
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
