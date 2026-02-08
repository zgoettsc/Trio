import SwiftUI

/// Displays V2 meal outcome accuracy analysis — predicted vs actual BG outcomes.
struct V2OutcomeAnalysisView: View {
    @State private var outcomes: [V2MealOutcome] = []
    @State private var selectedOutcome: V2MealOutcome?

    var body: some View {
        List {
            // MARK: - Summary Stats
            Section(header: Text("Overall Accuracy")) {
                let completed = outcomes.filter { hasAnyCheckpoint($0) }
                HStack {
                    Text("Total Recorded Meals")
                    Spacer()
                    Text("\(outcomes.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("With BG Checkpoints")
                    Spacer()
                    Text("\(completed.count)")
                        .foregroundStyle(.secondary)
                }
                if !completed.isEmpty {
                    let inRange = completed.filter { isInRange($0) }
                    HStack {
                        Text("In Range at 2h")
                        Spacer()
                        Text("\(inRange.count)/\(completed.count) (\(percentage(inRange.count, completed.count))%)")
                            .foregroundStyle(inRange.count > completed.count / 2 ? .green : .orange)
                    }

                    if let avgError = averageError(at: 2, from: completed) {
                        HStack {
                            Text("Avg BG Error at 2h")
                            Spacer()
                            Text(errorText(avgError))
                                .foregroundStyle(abs(avgError) < 30 ? .green : .orange)
                        }
                    }

                    if let avgError = averageError(at: 4, from: completed) {
                        HStack {
                            Text("Avg BG Error at 4h")
                            Spacer()
                            Text(errorText(avgError))
                                .foregroundStyle(abs(avgError) < 30 ? .green : .orange)
                        }
                    }
                }

                if outcomes.contains(where: { $0.garminSnapshot != nil }) {
                    let garminMeals = outcomes.filter { $0.garminSnapshot != nil }
                    HStack {
                        Text("Garmin-Adjusted Meals")
                        Spacer()
                        Text("\(garminMeals.count)")
                            .foregroundStyle(.secondary)
                    }
                    if let avgDemand = garminMeals.map(\.insulinDemandFactor).reduce(nil, { sum, val in
                        (sum ?? 0) + val
                    }).map({ $0 / Double(garminMeals.count) }) {
                        HStack {
                            Text("Avg Demand Factor")
                            Spacer()
                            Text(String(format: "%.2f", avgDemand))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // MARK: - Curve Phase Analysis
            if outcomes.contains(where: { hasAnyCheckpoint($0) }) {
                Section(header: Text("Curve Phase Accuracy")) {
                    let completed = outcomes.filter { hasAnyCheckpoint($0) }
                    phaseRow("Carb Phase (0-2h)", phase: .carb, outcomes: completed)
                    phaseRow("Protein Phase (2-5h)", phase: .protein, outcomes: completed)
                    phaseRow("Fat Phase (4-8h)", phase: .fat, outcomes: completed)
                }
            }

            // MARK: - Recent Meals
            Section(header: Text("Recent Meals (\(outcomes.suffix(20).count))")) {
                if outcomes.isEmpty {
                    Text("No meal outcomes recorded yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(outcomes.suffix(20).reversed()) { outcome in
                        mealRow(outcome)
                    }
                }
            }
        }
        .navigationTitle("Outcome Accuracy")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            // Backfill BG checkpoints first, then reload
            Task {
                await V2OutcomeLearningStore.shared.backfillOutcomes(
                    context: CoreDataStack.shared.newTaskContext()
                )
                await MainActor.run {
                    outcomes = V2OutcomeLearningStore.shared.loadAll()
                }
            }
        }
    }

    // MARK: - Meal Row

    private func mealRow(_ outcome: V2MealOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(outcome.date, style: .date)
                    .font(.caption)
                Text(outcome.date, style: .time)
                    .font(.caption)
                Spacer()
                if outcome.garminSnapshot != nil {
                    Image(systemName: "applewatch")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if outcome.hasConfoundingMeal {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Text("C: \(Int(outcome.carbs))g")
                Text("F: \(Int(outcome.fat))g")
                Text("P: \(Int(outcome.protein))g")
                Spacer()
                Text("BG: \(outcome.bgAtMeal)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 8) {
                Text("Demand: \(String(format: "%.2f", outcome.insulinDemandFactor))")
                Text("Upfront: \(Int(outcome.upfrontPercent * 100))%")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Checkpoint results
            HStack(spacing: 12) {
                ForEach(outcome.checkpoints, id: \.hoursAfterMeal) { cp in
                    VStack(spacing: 2) {
                        Text("\(cp.hoursAfterMeal)h")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        if let bg = cp.bgValue {
                            Text("\(bg)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(bgColor(bg))
                        } else {
                            Text("--")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !cp.isClean {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func hasAnyCheckpoint(_ outcome: V2MealOutcome) -> Bool {
        outcome.checkpoints.contains { $0.bgValue != nil }
    }

    private func isInRange(_ outcome: V2MealOutcome) -> Bool {
        guard let cp2h = outcome.checkpoints.first(where: { $0.hoursAfterMeal == 2 }),
              let bg = cp2h.bgValue else { return false }
        return bg >= 70 && bg <= 180
    }

    private func averageError(at hours: Int, from outcomes: [V2MealOutcome]) -> Double? {
        let values = outcomes.compactMap { outcome -> Double? in
            guard let cp = outcome.checkpoints.first(where: { $0.hoursAfterMeal == hours }),
                  let bg = cp.bgValue, cp.isClean else { return nil }
            // Error = deviation from target (110 mg/dL)
            return Double(bg - 110)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func errorText(_ error: Double) -> String {
        let sign = error >= 0 ? "+" : ""
        return "\(sign)\(Int(error)) mg/dL"
    }

    private func percentage(_ n: Int, _ total: Int) -> Int {
        guard total > 0 else { return 0 }
        return (n * 100) / total
    }

    private func bgColor(_ bg: Int) -> Color {
        if bg < 70 { return .red }
        if bg > 180 { return .orange }
        return .green
    }

    private func phaseRow(_ label: String, phase: V2BGCheckpoint.CurvePhase, outcomes: [V2MealOutcome]) -> some View {
        let checkpoints = outcomes.flatMap { $0.checkpoints }
            .filter { $0.curvePhase == phase && $0.bgValue != nil && $0.isClean }
        let bgValues = checkpoints.compactMap(\.bgValue)
        let avgBG = bgValues.isEmpty ? nil : bgValues.reduce(0, +) / bgValues.count
        let inRange = bgValues.filter { $0 >= 70 && $0 <= 180 }.count

        return HStack {
            Text(label)
            Spacer()
            if let avg = avgBG {
                Text("Avg: \(avg)")
                    .font(.caption)
                    .foregroundStyle(bgColor(avg))
                Text("IR: \(percentage(inRange, bgValues.count))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
