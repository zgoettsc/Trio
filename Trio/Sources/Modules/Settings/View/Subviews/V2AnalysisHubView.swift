import SwiftUI
import Swinject

/// Analysis tab within the V2 Hub. Consolidates all analysis and outcome tracking links.
struct V2AnalysisHubView: View {
    let resolver: Resolver

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(header: Text("Meal Outcomes")) {
                NavigationLink(value: Screen.v2OutcomeAnalysis) {
                    Text("Meal Outcome Accuracy")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracks how well V2 dosing predictions match actual BG outcomes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Review per-meal results, parameter trends, and learning history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Nutrition Analysis")) {
                NavigationLink(value: Screen.nutritionAnalysis) {
                    Text("Nutrition Analysis")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare your carb estimates vs. actual Cronometer data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("See BG impact analysis, low episode patterns, and setting recommendations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Outcome Learning")) {
                let store = V2OutcomeLearningStore.shared
                let outcomes = store.loadAll()
                let completedCount = outcomes.filter({ !$0.bgCheckpoints.isEmpty }).count

                HStack {
                    Text("Meals recorded")
                    Spacer()
                    Text("\(outcomes.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("With BG data")
                    Spacer()
                    Text("\(completedCount)")
                        .foregroundStyle(.secondary)
                }

                if completedCount > 0 {
                    let inRange = outcomes.filter { outcome in
                        guard let peak = outcome.bgCheckpoints.max(by: { $0.bg < $1.bg })?.bg else { return false }
                        return peak <= 180
                    }.count
                    let pct = Double(inRange) / Double(completedCount) * 100

                    HStack {
                        Text("Peak in range")
                        Spacer()
                        Text(String(format: "%.0f%%", pct))
                            .foregroundStyle(pct >= 70 ? .green : pct >= 50 ? .orange : .red)
                    }
                }
            }

            Section(header: Text("Export")) {
                Button {
                    exportMealData()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.blue)
                        Text("Export Meal Outcome Data")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }

    private func exportMealData() {
        let outcomes = V2OutcomeLearningStore.shared.loadAll()
        guard !outcomes.isEmpty else { return }

        var csv = "mealID,mealDate,carbs,fat,protein,fiber,bgAtMeal,demandFactor\n"
        for o in outcomes {
            csv += "\(o.mealID),\(o.mealDate),\(o.carbsLogged),\(o.fatLogged),\(o.proteinLogged),\(o.fiberLogged),\(o.bgAtMeal),\(o.insulinDemandFactor)\n"
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2_meal_outcomes.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)

        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController
        {
            rootVC.present(activityVC, animated: true)
        }
    }
}
