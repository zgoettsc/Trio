import SwiftUI
import Swinject

struct NutritionAnalysisView: View {
    let resolver: Resolver

    @State private var matchedDays: [MatchedMealAnalysis] = []
    @State private var summary: NutritionAnalysisSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var analysisDays = 14
    @State private var showShareSheet = false

    // Apply flow state
    @State private var selectedRecommendations: Set<UUID> = []
    @State private var showApplyConfirmation = false
    @State private var isApplying = false
    @State private var applyResult: String?
    @State private var applyError: String?

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Analyzing \(analysisDays) days of nutrition data...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        Spacer()
                    }
                }
            } else if let error = errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Analysis Error", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if let summary = summary {
                summarySection(summary)

                lowTreatmentSection(summary)

                lowCauseBreakdownSection(summary)

                recommendationsSection(summary)

                icrAnalysisSection(summary)

                bgOutcomesSection(summary)

                matchedDaysSection
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This analysis compares your daily Trio carb entries with actual nutrition data from Apple Health (Cronometer) to understand your carb estimation patterns.")
                            .font(.callout)
                        Text("It also detects low BG episodes and estimates treatment carbs to separate low treatments from meal carb counting accuracy.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button {
                        runAnalysis()
                    } label: {
                        HStack {
                            Image(systemName: "chart.bar.doc.horizontal")
                            Text("Run Analysis (\(analysisDays) days)")
                        }
                    }
                }
            }
        }
        .listSectionSpacing(sectionSpacing)
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Nutrition Analysis")
        .navigationBarTitleDisplayMode(.automatic)
        .toolbar {
            if summary != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button {
                            runAnalysis()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let summary = summary {
                let report = generateReport(summary: summary, days: matchedDays)
                NutritionShareSheet(activityItems: [report])
            }
        }
    }

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(_ summary: NutritionAnalysisSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(.blue)
                    Text("Estimation Accuracy")
                        .font(.headline)
                }

                // Key finding
                Text(summary.estimationDescription)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)

                // Adjusted ratio (if low treatments detected)
                if let adjDesc = summary.adjustedEstimationDescription {
                    Text(adjDesc)
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }

                // Stats grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    statCard("Matched Days", value: "\(summary.totalMatchedDays)")
                    statCard("Avg Ratio", value: "\(Int(summary.averageEstimationRatio * 100))%")
                    statCard("Avg Entered", value: "\(Int(summary.averageTrioCarbs))g/day")
                    statCard("Avg Actual", value: "\(Int(summary.averageActualCarbs))g/day")
                    statCard("Avg Missed", value: "\(Int(summary.averageMissedCarbs))g/day")
                    if let adjRatio = summary.adjustedAverageEstimationRatio {
                        statCard("Adj. Ratio", value: "\(Int(adjRatio * 100))%")
                    } else {
                        statCard("Median Ratio", value: "\(Int(summary.medianEstimationRatio * 100))%")
                    }
                }

                // Range
                Text("Estimation range: \(Int(summary.minEstimationRatio * 100))% – \(Int(summary.maxEstimationRatio * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Summary — \(summary.analysisPeriodDays) days")
        } footer: {
            if summary.unmatchedTrioDays > 0 || summary.unmatchedHealthDays > 0 {
                Text("\(summary.unmatchedTrioDays) Trio-only days and \(summary.unmatchedHealthDays) Cronometer-only days could not be matched.")
            }
        }
    }

    // MARK: - Low Treatment Section

    @ViewBuilder
    private func lowTreatmentSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
            if let lows = summary.lowTreatmentSummary {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "arrow.down.heart")
                                .foregroundColor(.red)
                            Text("Low Treatment Patterns")
                                .font(.headline)
                        }

                        // Key pattern finding
                        Text(lows.correctionPattern)
                            .font(.subheadline)
                            .foregroundColor(lows.overCorrectionRate > 0.5 ? .red : lows.overCorrectionRate > 0.25 ? .orange : .green)

                        // Stats
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            statCard("Episodes", value: "\(lows.totalEpisodes)")
                            statCard("Per Day", value: String(format: "%.1f", lows.episodesPerDay))
                            statCard("Avg Nadir", value: "\(lows.averageNadir)")
                        }

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            statCard("Avg Duration", value: "\(lows.averageDurationMinutes)m")
                            if let rise = lows.averageRecoveryRise {
                                statCard("Avg Rise", value: "+\(rise)")
                            }
                            if let peak = lows.averagePeakAfterLow {
                                statCard("Avg Peak", value: "\(peak)")
                            }
                        }

                        // Treatment carb estimate
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("Est. ~\(Int(lows.estimatedDailyTreatmentCarbs))g/day in low treatment carbs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Over-correction detail
                        if lows.overCorrectionCount > 0 {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("\(lows.overCorrectionCount) of \(lows.totalEpisodes) lows spiked above 180 after treatment")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Low BG Treatment Analysis")
                } footer: {
                    Text("Low episodes are detected from CGM data (BG below your low threshold or trending rapidly toward it). Treatment carbs are estimated from BG recovery magnitude and subtracted from Cronometer totals to get your true meal-carb estimation accuracy.")
                }
            }
        }
    }

    // MARK: - Low Cause Breakdown Section

    @ViewBuilder
    private func lowCauseBreakdownSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
            if let lows = summary.lowTreatmentSummary, lows.totalEpisodes >= 2 {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "chart.pie")
                                .foregroundColor(.purple)
                            Text("What's Causing Your Lows?")
                                .font(.headline)
                        }

                        // Cause breakdown bars
                        VStack(spacing: 6) {
                            if lows.exerciseCount > 0 {
                                causeBar(
                                    label: "Exercise",
                                    count: lows.exerciseCount,
                                    total: lows.totalEpisodes,
                                    color: .green
                                )
                            }
                            if lows.postBolusCount > 0 {
                                causeBar(
                                    label: "Post-Bolus",
                                    count: lows.postBolusCount,
                                    total: lows.totalEpisodes,
                                    color: .blue
                                )
                            }
                            if lows.fastingCount > 0 {
                                causeBar(
                                    label: "Fasting/Basal",
                                    count: lows.fastingCount,
                                    total: lows.totalEpisodes,
                                    color: .orange
                                )
                            }
                            if lows.mixedCount > 0 {
                                causeBar(
                                    label: "Mixed",
                                    count: lows.mixedCount,
                                    total: lows.totalEpisodes,
                                    color: .yellow
                                )
                            }
                            if lows.unknownCount > 0 {
                                causeBar(
                                    label: "Unknown",
                                    count: lows.unknownCount,
                                    total: lows.totalEpisodes,
                                    color: .gray
                                )
                            }
                        }

                        // Dominant cause callout
                        let dominant = lows.dominantCause
                        if dominant != .unknown {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.yellow)
                                Text("Primary driver: \(dominant.displayName) (\(lows.causeBreakdown))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Low Episode Causes")
                } footer: {
                    Text("Exercise: workout within 4h. Post-bolus: meal bolus within 1-4h. Fasting/basal: no recent bolus or exercise.")
                }
            }
        }
    }

    @ViewBuilder
    private func causeBar(label: String, count: Int, total: Int, color: Color) -> some View {
        let pct = Double(count) / Double(max(1, total))
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.7))
                    .frame(width: geo.size.width * pct)
            }
            .frame(height: 18)
            Text("\(count) (\(Int(pct * 100))%)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: - Recommendations Section

    @ViewBuilder
    private func recommendationsSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
            if let lows = summary.lowTreatmentSummary, !lows.recommendations.isEmpty {
                // Actionable recommendations (can be applied)
                let actionable = lows.recommendations.filter(\.setting.isActionable)
                let advisory = lows.recommendations.filter { !$0.setting.isActionable }

                if !actionable.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                    .foregroundColor(.teal)
                                Text("Apply Changes")
                                    .font(.headline)
                                Spacer()
                                if !selectedRecommendations.isEmpty {
                                    Text("\(selectedRecommendations.count) selected")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }

                            ForEach(actionable) { rec in
                                actionableRecommendationRow(rec)
                                if rec.id != actionable.last?.id {
                                    Divider()
                                }
                            }

                            // Apply section (when items selected)
                            if !selectedRecommendations.isEmpty {
                                applyCard
                            }

                            // Result/Error messages
                            if let result = applyResult {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text(result)
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            if let error = applyError {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Setting Recommendations")
                    } footer: {
                        Text("Select changes to apply. A backup is created automatically so you can undo. All adjustments capped at 20%. Discuss with your endocrinologist.")
                    }
                }

                // Advisory-only recommendations
                if !advisory.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.yellow)
                                Text("Additional Guidance")
                                    .font(.headline)
                            }
                            ForEach(advisory) { rec in
                                advisoryRecommendationRow(rec)
                                if rec.id != advisory.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Advisory")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionableRecommendationRow(_ rec: SettingRecommendation) -> some View {
        let isSelected = selectedRecommendations.contains(rec.id)

        Button {
            if isSelected {
                selectedRecommendations.remove(rec.id)
            } else {
                selectedRecommendations.insert(rec.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .font(.title3)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    // Type badge + confidence
                    HStack {
                        Text(rec.setting.displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(colorForSeverity(rec.severity))
                            .cornerRadius(4)

                        Text(rec.confidence.displayName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    // What will change
                    Text(rec.setting.description)
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    // Preview of current -> proposed
                    previewForRecommendation(rec)

                    // Rationale
                    Text(rec.rationale)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func previewForRecommendation(_ rec: SettingRecommendation) -> some View {
        switch rec.setting {
        case let .reduceBasal(_, pct):
            if let profile = resolver.resolve(FileStorage.self)?
                .retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            {
                let avgRate = profile.map { Double(truncating: $0.rate as NSDecimalNumber) }.reduce(0, +) / Double(max(1, profile.count))
                let factor = 1.0 - pct / 100.0
                let proposedAvg = avgRate * factor
                HStack(spacing: 8) {
                    Text("Affected rates:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2f", avgRate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Text(String(format: "%.2f U/hr", proposedAvg))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                }
            }
        case let .weakenICR(pct):
            if let carbRatios = resolver.resolve(FileStorage.self)?
                .retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
            {
                let currentCR = carbRatios.schedule.map { Double(truncating: $0.ratio as NSDecimalNumber) }
                let avgCR = currentCR.reduce(0, +) / Double(max(1, currentCR.count))
                let factor = 1.0 + pct / 100.0
                let proposedCR = avgCR * factor
                HStack(spacing: 8) {
                    Text("Avg ICR:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("1:\(String(format: "%.1f", avgCR))g")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Text("1:\(String(format: "%.1f", proposedCR))g")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func advisoryRecommendationRow(_ rec: SettingRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rec.setting.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.gray)
                    .cornerRadius(4)
                Text(rec.confidence.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(rec.setting.description)
                .font(.subheadline)
            Text(rec.rationale)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var applyCard: some View {
        VStack(spacing: 10) {
            // Warning
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("A backup will be created automatically so you can undo if needed. Have you discussed these changes with your healthcare provider?")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)

            // Apply button
            Button {
                showApplyConfirmation = true
            } label: {
                HStack {
                    if isApplying {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text("Apply \(selectedRecommendations.count) Selected Change\(selectedRecommendations.count == 1 ? "" : "s")")
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isApplying)
            .confirmationDialog(
                "Apply Changes",
                isPresented: $showApplyConfirmation,
                titleVisibility: .visible
            ) {
                Button("Apply \(selectedRecommendations.count) Change\(selectedRecommendations.count == 1 ? "" : "s")", role: .destructive) {
                    Task { await applySelectedChanges() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will modify your profile settings. A backup will be created so you can undo from the Claude-o-Tune Profile History screen.")
            }
        }
    }

    private func colorForSeverity(_ severity: RecommendationSeverity) -> Color {
        switch severity {
        case .informational: return .gray
        case .suggested: return .blue
        case .recommended: return .orange
        }
    }

    // MARK: - Apply Logic

    private func applySelectedChanges() async {
        guard let lows = summary?.lowTreatmentSummary else { return }

        isApplying = true
        applyResult = nil
        applyError = nil

        // Create backup first (reusing Claude-o-Tune's backup system)
        let profileService = ClaudeOTuneProfileService()
        profileService.injectServices(resolver)
        guard profileService.createBackup(reason: "Before nutrition analysis changes") != nil else {
            applyError = "Failed to create profile backup"
            isApplying = false
            return
        }

        guard let storage = resolver.resolve(FileStorage.self) else {
            applyError = "Could not access settings storage"
            isApplying = false
            return
        }

        var appliedChanges: [String] = []
        var failedChanges: [String] = []

        for recId in selectedRecommendations {
            guard let rec = lows.recommendations.first(where: { $0.id == recId }) else { continue }

            switch rec.setting {
            case let .reduceBasal(timeWindow, pctReduction):
                if applyBasalReduction(storage: storage, timeWindow: timeWindow, pctReduction: pctReduction) {
                    appliedChanges.append("Basal rate reduced \(timeWindow) by \(Int(pctReduction))%")
                } else {
                    failedChanges.append("Basal rate change failed")
                }

            case let .weakenICR(pctChange):
                if applyICRWeakening(storage: storage, pctChange: pctChange) {
                    appliedChanges.append("ICR weakened by \(Int(pctChange))%")
                } else {
                    failedChanges.append("ICR change failed")
                }

            default:
                break
            }
        }

        if !appliedChanges.isEmpty {
            applyResult = "Applied: " + appliedChanges.joined(separator: "; ") + ". Undo available in Profile History."
            selectedRecommendations.removeAll()
        }
        if !failedChanges.isEmpty {
            applyError = "Failed: " + failedChanges.joined(separator: "; ")
        }

        isApplying = false
    }

    /// Parse "H:00" to minutes from midnight
    private func parseTimeToMinutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let min = Int(parts[1]) else { return nil }
        return hour * 60 + min
    }

    /// Reduce basal rates within a time window by a percentage
    private func applyBasalReduction(storage: FileStorage, timeWindow: String, pctReduction: Double) -> Bool {
        guard var profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) else {
            return false
        }

        let windowParts = timeWindow.split(separator: "-")
        guard windowParts.count == 2,
              let startMin = parseTimeToMinutes(String(windowParts[0])),
              let endMin = parseTimeToMinutes(String(windowParts[1]))
        else { return false }

        let factor = Decimal(1.0 - pctReduction / 100.0)
        var changed = false

        for i in 0 ..< profile.count {
            let entryMin = profile[i].minutes
            // Handle wrapping (e.g., 22:00-1:00)
            let inWindow: Bool
            if startMin <= endMin {
                inWindow = entryMin >= startMin && entryMin < endMin
            } else {
                inWindow = entryMin >= startMin || entryMin < endMin
            }

            if inWindow {
                let newRate = profile[i].rate * factor
                profile[i] = BasalProfileEntry(start: profile[i].start, minutes: profile[i].minutes, rate: newRate)
                changed = true
            }
        }

        if changed {
            storage.save(profile, as: OpenAPS.Settings.basalProfile)
        }
        return changed
    }

    /// Weaken ICR by increasing ratio values (more carbs per unit of insulin)
    private func applyICRWeakening(storage: FileStorage, pctChange: Double) -> Bool {
        guard var carbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) else {
            return false
        }

        let factor = Decimal(1.0 + pctChange / 100.0)
        var newSchedule: [CarbRatioEntry] = []

        for entry in carbRatios.schedule {
            let newRatio = entry.ratio * factor
            newSchedule.append(CarbRatioEntry(start: entry.start, offset: entry.offset, ratio: newRatio))
        }

        carbRatios = CarbRatios(units: carbRatios.units, schedule: newSchedule)
        storage.save(carbRatios, as: OpenAPS.Settings.carbRatios)
        return true
    }

    // MARK: - ICR Analysis Section

    @ViewBuilder
    private func icrAnalysisSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
            if let apparent = summary.averageApparentICR, let effective = summary.averageEffectiveICR {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "function")
                                .foregroundColor(.purple)
                            Text("ICR Analysis")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Current ICR (tuned to estimates):")
                                Spacer()
                                Text("1:\(String(format: "%.1f", apparent))g")
                                    .fontWeight(.medium)
                            }
                            HStack {
                                Text("True ICR (against actual carbs):")
                                Spacer()
                                Text("1:\(String(format: "%.1f", effective))g")
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }
                        }
                        .font(.subheadline)

                        if let adj = summary.suggestedICRAdjustment {
                            Text("If switching to actual carbs for dosing, ICR would need to increase by ~\(String(format: "%.1f", adj))x")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Insulin to Carb Ratio")
                } footer: {
                    Text("Your current ICR works because it compensates for systematic under-counting. The 'true' ICR is what you'd need if using Cronometer carbs directly.")
                }
            }
        }
    }

    // MARK: - BG Outcomes Section

    @ViewBuilder
    private func bgOutcomesSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
            if let avgBG = summary.averageDailyBG {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundColor(.red)
                            Text("Daily BG Summary")
                                .font(.headline)
                        }

                        HStack(spacing: 24) {
                            VStack {
                                Text("Avg Daily BG")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(avgBG)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(avgBG > 180 ? .red : avgBG > 140 ? .orange : .green)
                                Text("mg/dL")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let avgMax = summary.averageDailyMaxBG {
                                VStack {
                                    Text("Avg Daily Max")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(avgMax)")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(avgMax > 250 ? .red : avgMax > 180 ? .orange : .green)
                                    Text("mg/dL")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Glucose Outcomes")
                } footer: {
                    Text("Average BG and daily peak across matched days.")
                }
            }
        }
    }

    // MARK: - Matched Days List

    @ViewBuilder
    private var matchedDaysSection: some View {
        Section {
            ForEach(matchedDays) { day in
                dayAnalysisRow(day)
            }
        } header: {
            Text("Daily Comparison")
        }
    }

    @ViewBuilder
    private func dayAnalysisRow(_ day: MatchedMealAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Day header
            HStack {
                Text(day.dayDescription)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if !day.lowEpisodes.isEmpty {
                    lowCauseBadges(day.lowEpisodes)
                }
                Text("\(Int(day.estimationRatio * 100))%")
                    .font(.headline)
                    .foregroundColor(day.estimationRatio < 0.5 ? .red : day.estimationRatio < 0.8 ? .orange : .green)
            }

            // Carb comparison
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Entered")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(day.trioCarbs))g")
                        .font(.subheadline)
                }
                VStack(alignment: .leading) {
                    Text("Actual")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(day.actualCarbs))g")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                if day.estimatedTreatmentCarbs > 0 {
                    VStack(alignment: .leading) {
                        Text("Low Tx")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("~\(Int(day.estimatedTreatmentCarbs))g")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
                VStack(alignment: .leading) {
                    Text(day.estimatedTreatmentCarbs > 0 ? "Adj. Missed" : "Missed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(day.estimatedTreatmentCarbs > 0 ? day.adjustedMissedCarbs : day.missedCarbs))g")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                Spacer()
                if day.bolusInsulin > 0 {
                    VStack(alignment: .trailing) {
                        Text("Bolus")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", day.bolusInsulin))U")
                            .font(.subheadline)
                    }
                }
            }

            // Macros from Cronometer + daily BG
            HStack(spacing: 12) {
                Text("C:\(Int(day.actualCarbPercent))%")
                    .foregroundColor(.orange)
                Text("F:\(Int(day.actualFatPercent))%")
                    .foregroundColor(.yellow)
                Text("P:\(Int(day.actualProteinPercent))%")
                    .foregroundColor(.red)
                Spacer()
                if let avg = day.averageBG {
                    Text("Avg \(avg)")
                        .foregroundColor(avg > 180 ? .red : avg > 140 ? .orange : .green)
                }
                if let peak = day.maxBG {
                    Text("Max \(peak)")
                        .foregroundColor(peak > 250 ? .red : peak > 180 ? .orange : .green)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func lowCauseBadges(_ episodes: [LowEpisode]) -> some View {
        HStack(spacing: 2) {
            let causeCounts = Dictionary(grouping: episodes, by: \.cause).mapValues(\.count)
            ForEach(causeCounts.sorted(by: { $0.value > $1.value }), id: \.key.rawValue) { cause, count in
                Text("\(count)\(causeAbbrev(cause))")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(causeColor(cause))
                    .cornerRadius(3)
            }
        }
    }

    private func causeAbbrev(_ cause: LowEpisodeCause) -> String {
        switch cause {
        case .exercise: return "E"
        case .postBolus: return "B"
        case .fasting: return "F"
        case .mixed: return "M"
        case .unknown: return "?"
        }
    }

    private func causeColor(_ cause: LowEpisodeCause) -> Color {
        switch cause {
        case .exercise: return .green
        case .postBolus: return .blue
        case .fasting: return .orange
        case .mixed: return .yellow
        case .unknown: return .gray
        }
    }

    @ViewBuilder
    private func statCard(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func generateReport(summary: NutritionAnalysisSummary, days: [MatchedMealAnalysis]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"
        let now = dateFormatter.string(from: Date())

        var lines: [String] = [
            "Trio Nutrition Analysis Report",
            "Generated: \(now)",
            "Period: \(summary.analysisPeriodDays) days | \(summary.totalMatchedDays) matched days",
            "",
            "=== ESTIMATION ACCURACY ===",
            summary.estimationDescription,
            "Average ratio: \(Int(summary.averageEstimationRatio * 100))%",
            "Median ratio: \(Int(summary.medianEstimationRatio * 100))%",
            "Range: \(Int(summary.minEstimationRatio * 100))% - \(Int(summary.maxEstimationRatio * 100))%",
            "Avg entered (Trio): \(Int(summary.averageTrioCarbs))g/day",
            "Avg actual (Cronometer): \(Int(summary.averageActualCarbs))g/day",
            "Avg missed carbs: \(Int(summary.averageMissedCarbs))g/day",
            "Total missed carbs: \(Int(summary.totalMissedCarbs))g",
        ]

        if let adjRatio = summary.adjustedAverageEstimationRatio {
            lines += [
                "",
                "=== ADJUSTED (EXCLUDING LOW TREATMENTS) ===",
                "Adjusted ratio (meal carbs only): \(Int(adjRatio * 100))%",
            ]
            if let adjActual = summary.adjustedAverageActualCarbs {
                lines.append("Avg meal carbs (Cronometer minus low tx): \(Int(adjActual))g/day")
            }
        }

        if let lows = summary.lowTreatmentSummary {
            lines += [
                "",
                "=== LOW TREATMENT PATTERNS ===",
                "Total low episodes: \(lows.totalEpisodes)",
                "Episodes per day: \(String(format: "%.1f", lows.episodesPerDay))",
                "Average nadir: \(lows.averageNadir) mg/dL",
                "Average duration: \(lows.averageDurationMinutes) min",
                "Estimated daily treatment carbs: ~\(Int(lows.estimatedDailyTreatmentCarbs))g",
            ]
            if let rise = lows.averageRecoveryRise {
                lines.append("Average BG rise after treatment: +\(rise) mg/dL")
            }
            if let peak = lows.averagePeakAfterLow {
                lines.append("Average peak after low: \(peak) mg/dL")
            }
            lines.append("Over-corrections (spike >180): \(lows.overCorrectionCount)/\(lows.totalEpisodes) (\(Int(lows.overCorrectionRate * 100))%)")
            lines.append(lows.correctionPattern)

            // Cause breakdown
            lines += [
                "",
                "=== LOW EPISODE CAUSES ===",
                "Exercise-related: \(lows.exerciseCount) (\(Int(lows.exerciseRate * 100))%)",
                "Post-bolus (over-dosed): \(lows.postBolusCount) (\(Int(lows.postBolusRate * 100))%)",
                "Fasting/basal (too high): \(lows.fastingCount) (\(Int(lows.fastingRate * 100))%)",
                "Mixed (exercise + bolus): \(lows.mixedCount) (\(Int(lows.mixedRate * 100))%)",
            ]
            if lows.unknownCount > 0 {
                lines.append("Unclassified: \(lows.unknownCount)")
            }
            lines.append("Primary driver: \(lows.dominantCause.displayName)")

            // Recommendations
            if !lows.recommendations.isEmpty {
                lines += ["", "=== SETTING RECOMMENDATIONS ==="]
                lines.append("(All suggestions capped at 20% max adjustment. Discuss with your endocrinologist.)")
                lines.append("")
                for (i, rec) in lows.recommendations.enumerated() {
                    lines.append("\(i + 1). [\(rec.setting.displayName)] \(rec.setting.description)")
                    lines.append("   Rationale: \(rec.rationale)")
                    lines.append("   Confidence: \(rec.confidence.displayName) | Priority: \(rec.severity.displayName)")
                    lines.append("")
                }
            }
        }

        if let apparent = summary.averageApparentICR, let effective = summary.averageEffectiveICR {
            lines += [
                "",
                "=== ICR ANALYSIS ===",
                "Current ICR (tuned to estimates): 1:\(String(format: "%.1f", apparent))g",
                "True ICR (against actual carbs): 1:\(String(format: "%.1f", effective))g",
            ]
            if let adj = summary.suggestedICRAdjustment {
                lines.append("Adjustment factor if switching to actual carbs: \(String(format: "%.2f", adj))x")
            }
        }

        if let avgBG = summary.averageDailyBG {
            lines += ["", "=== GLUCOSE OUTCOMES ==="]
            lines.append("Avg daily BG: \(avgBG) mg/dL")
            if let avgMax = summary.averageDailyMaxBG {
                lines.append("Avg daily max BG: \(avgMax) mg/dL")
            }
        }

        if summary.unmatchedTrioDays > 0 || summary.unmatchedHealthDays > 0 {
            lines += [
                "",
                "=== DATA COVERAGE ===",
                "Matched days: \(summary.totalMatchedDays)",
                "Trio-only days (no Cronometer): \(summary.unmatchedTrioDays)",
                "Cronometer-only days (no Trio): \(summary.unmatchedHealthDays)",
            ]
        }

        lines += ["", "=== DAILY BREAKDOWN ==="]
        lines.append("Date | Entered | Actual | Low Tx | Adj.Missed | Ratio | Lows (E/B/F/M) | Bolus | Avg BG | Max BG")
        lines.append(String(repeating: "-", count: 105))

        for day in days {
            let dayStr = dateFormatter.string(from: day.date)
            let bolusStr = day.bolusInsulin > 0 ? String(format: "%.1fU", day.bolusInsulin) : "-"
            let avgBGStr = day.averageBG.map { "\($0)" } ?? "-"
            let maxBGStr = day.maxBG.map { "\($0)" } ?? "-"
            let lowTxStr = day.estimatedTreatmentCarbs > 0 ? "~\(Int(day.estimatedTreatmentCarbs))g" : "-"
            let adjMissed = day.estimatedTreatmentCarbs > 0 ? "\(Int(day.adjustedMissedCarbs))g" : "\(Int(day.missedCarbs))g"
            // Low cause breakdown per day
            let lowStr: String
            if day.lowEpisodes.isEmpty {
                lowStr = "-"
            } else {
                let e = day.lowEpisodes.filter { $0.cause == .exercise }.count
                let b = day.lowEpisodes.filter { $0.cause == .postBolus }.count
                let f = day.lowEpisodes.filter { $0.cause == .fasting }.count
                let m = day.lowEpisodes.filter { $0.cause == .mixed || $0.cause == .unknown }.count
                lowStr = "\(day.lowEpisodes.count) (\(e)/\(b)/\(f)/\(m))"
            }
            lines.append("\(dayStr) | \(Int(day.trioCarbs))g | \(Int(day.actualCarbs))g | \(lowTxStr) | \(adjMissed) | \(Int(day.estimationRatio * 100))% | \(lowStr) | \(bolusStr) | \(avgBGStr) | \(maxBGStr)")
        }

        return lines.joined(separator: "\n")
    }

    private func runAnalysis() {
        let service = resolver.resolve(NutritionAnalysisService.self)!
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let result = try await service.runAnalysis(days: analysisDays)
                await MainActor.run {
                    matchedDays = result.days
                    summary = result.summary
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Share Sheet

private struct NutritionShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
