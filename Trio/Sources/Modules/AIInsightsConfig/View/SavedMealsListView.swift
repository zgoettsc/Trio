import CoreData
import SwiftUI
import Swinject

/// Settings → AI Analysis → Saved Meals.
/// Lists all saved meals, allows add/edit/delete/duplicate, and lets the user
/// start a window from a saved meal directly (in-app picker).
struct SavedMealsListView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @FetchRequest(
        entity: SavedMeal.entity(),
        sortDescriptors: [
            NSSortDescriptor(key: "cachedInstanceCount", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
    ) private var meals: FetchedResults<SavedMeal>

    @State private var showAdd = false
    @State private var startResult: String?
    @State private var showStartConfirm: SavedMeal?

    private let resolver: Resolver = TrioApp.resolver
    private var storage: SavedMealStorage? { resolver.resolve(SavedMealStorage.self) }

    var body: some View {
        Form {
            if meals.isEmpty {
                Section(footer: Text("Save common meals (Indian, pizza, sushi…) with default macros and classification. When you tap one, the app starts an eating-mode window seeded for that meal. Per-meal history accumulates over time for analytics.")) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Create your first meal", systemImage: "plus.circle")
                    }
                }
                .listRowBackground(Color.chart)
            } else {
                Section(
                    header: Text("Saved Meals"),
                    footer: Text("Tap a meal to start a window seeded for it. Long-press the row or tap the chevron for stats and edit.")
                ) {
                    ForEach(meals, id: \.objectID) { meal in
                        SavedMealRow(meal: meal) {
                            showStartConfirm = meal
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            storage?.deleteMeal(meals[index])
                        }
                    }

                    Button {
                        showAdd = true
                    } label: {
                        Label("Add new meal", systemImage: "plus.circle")
                    }
                }
                .listRowBackground(Color.chart)
            }

            if let result = startResult {
                Section { Text(result).foregroundColor(.secondary) }
                    .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Saved Meals")
        .sheet(isPresented: $showAdd) {
            NavigationView {
                SavedMealEditView(meal: nil)
            }
        }
        .confirmationDialog(
            "Start \(showStartConfirm?.name ?? "this meal")?",
            isPresented: Binding(
                get: { showStartConfirm != nil },
                set: { if !$0 { showStartConfirm = nil } }
            ),
            presenting: showStartConfirm
        ) { meal in
            Button("Start eating mode") {
                Task { await startMeal(meal) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { meal in
            Text(startConfirmationText(for: meal))
        }
    }

    private func startConfirmationText(for meal: SavedMeal) -> String {
        var lines: [String] = []

        // Lead with the macros that will be logged as a carb entry — this is
        // the thing the user most needs to confirm before tapping Start.
        var macroParts: [String] = []
        if let c = meal.defaultCarbs, c.doubleValue > 0 {
            macroParts.append("\(c.intValue)g carbs")
        }
        if let f = meal.defaultFat, f.doubleValue > 0 {
            macroParts.append("\(f.intValue)g fat")
        }
        if let p = meal.defaultProtein, p.doubleValue > 0 {
            macroParts.append("\(p.intValue)g protein")
        }
        if macroParts.isEmpty {
            lines.append("No carbs will be logged (meal has no defaults).")
        } else {
            lines.append("Will log: " + macroParts.joined(separator: ", ") + ".")
        }

        if let cls = meal.defaultClassification {
            lines.append("Classification: \(cls.capitalized).")
        }
        if meal.defaultPhantomCOBEnabled {
            let g = meal.defaultPhantomCOBGrams.map { "\($0.intValue)g" } ?? "(default dose)"
            lines.append("Phantom COB: \(g).")
        }
        if meal.defaultExtendedDurationMinutes > 0 {
            let h = Double(meal.defaultExtendedDurationMinutes) / 60.0
            lines.append("Extended duration: \(String(format: "%.1f", h)) h.")
        }
        return lines.joined(separator: " ")
    }

    @MainActor
    private func startMeal(_ meal: SavedMeal) async {
        guard #available(iOS 16.0, *), let mealId = meal.id else { return }
        let req = AnnounceMealIntentRequest()
        do {
            // Logs a CarbEntry with the meal's defaults AND opens the window —
            // matches user expectation that "Start with this meal" means
            // "log this meal." Bolus is still a separate step.
            startResult = try await req.startMealAndLogCarbs(savedMealId: mealId)
        } catch {
            startResult = "Failed to start: \(error.localizedDescription)"
        }
    }
}

private struct SavedMealRow: View {
    @ObservedObject var meal: SavedMeal
    let onTap: () -> Void

    var body: some View {
        HStack {
            NavigationLink(destination: SavedMealDetailView(meal: meal)) {
                HStack {
                    Text(meal.icon ?? "🍽️")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.name ?? "(unnamed)").font(.headline)
                        HStack(spacing: 6) {
                            Text("\(meal.cachedInstanceCount) ×")
                            if let cls = meal.cachedRecommendedClassification ?? meal.defaultClassification {
                                Text("·").foregroundStyle(.tertiary)
                                Text(cls.capitalized)
                                    .foregroundStyle(colorForClassification(cls))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Button(action: onTap) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func colorForClassification(_ raw: String) -> Color {
        switch raw {
        case "complex": return .red
        case "medium": return .orange
        case "simple": return .green
        default: return .secondary
        }
    }
}
