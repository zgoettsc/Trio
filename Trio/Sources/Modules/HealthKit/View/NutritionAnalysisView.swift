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
                    Text("\(day.lowEpisodes.count) low\(day.lowEpisodes.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(4)
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
        lines.append("Date | Entered | Actual | Low Tx | Adj.Missed | Ratio | Lows | Bolus | Avg BG | Max BG")
        lines.append(String(repeating: "-", count: 95))

        for day in days {
            let dayStr = dateFormatter.string(from: day.date)
            let bolusStr = day.bolusInsulin > 0 ? String(format: "%.1fU", day.bolusInsulin) : "-"
            let avgBGStr = day.averageBG.map { "\($0)" } ?? "-"
            let maxBGStr = day.maxBG.map { "\($0)" } ?? "-"
            let lowTxStr = day.estimatedTreatmentCarbs > 0 ? "~\(Int(day.estimatedTreatmentCarbs))g" : "-"
            let adjMissed = day.estimatedTreatmentCarbs > 0 ? "\(Int(day.adjustedMissedCarbs))g" : "\(Int(day.missedCarbs))g"
            let lowCount = day.lowEpisodes.isEmpty ? "-" : "\(day.lowEpisodes.count)"
            lines.append("\(dayStr) | \(Int(day.trioCarbs))g | \(Int(day.actualCarbs))g | \(lowTxStr) | \(adjMissed) | \(Int(day.estimationRatio * 100))% | \(lowCount) | \(bolusStr) | \(avgBGStr) | \(maxBGStr)")
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
