import CoreData
import SwiftUI

/// Lightweight picker presented from the Add Treatments screen — lets the
/// user pick a saved meal whose macros will pre-fill the treatments form
/// and (on submit) seed the eating-mode window for that meal.
///
/// No CRUD here — full management is in Settings → Saved Meals.
struct SavedMealPickerView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @FetchRequest(
        entity: SavedMeal.entity(),
        sortDescriptors: [
            NSSortDescriptor(key: "cachedInstanceCount", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
    ) private var meals: FetchedResults<SavedMeal>

    /// Called with the picked meal. Caller is responsible for closing the
    /// sheet — we dismiss after invoking the closure.
    let onPick: (SavedMeal) -> Void

    var body: some View {
        NavigationView {
            Form {
                if meals.isEmpty {
                    Section(footer: Text("No saved meals yet. Add some in Settings → AI Analysis → Saved Meals.")) {
                        Text("No meals to pick").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.chart)
                } else {
                    Section(header: Text("Tap a meal to fill the form")) {
                        ForEach(meals, id: \.objectID) { meal in
                            Button {
                                onPick(meal)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(meal.icon ?? "🍽️").font(.title2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(meal.name ?? "(unnamed)")
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 6) {
                                            macroLabel(value: meal.defaultCarbs, suffix: "c")
                                            macroLabel(value: meal.defaultFat, suffix: "f")
                                            macroLabel(value: meal.defaultProtein, suffix: "p")
                                            if let cls = meal.cachedRecommendedClassification ?? meal.defaultClassification {
                                                Text("·").foregroundStyle(.tertiary)
                                                Text(cls.capitalized).foregroundStyle(.secondary)
                                            }
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.chart)

                    Section(
                        footer: Text("Picking a meal fills carbs/fat/protein with its defaults and seeds the eating-mode window with the meal's classification when you submit.")
                    ) {
                        EmptyView()
                    }
                    .listRowBackground(Color.clear)
                }

                // Always show management entry — add / edit / delete
                // happens in SavedMealsListView. Pushes into the same
                // nav stack so the user can manage and come back to
                // pick without re-opening the sheet.
                Section {
                    NavigationLink(destination: SavedMealsListView()) {
                        Label("Manage saved meals", systemImage: "slider.horizontal.3")
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Saved Meals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func macroLabel(value: NSDecimalNumber?, suffix: String) -> some View {
        if let v = value, v.intValue > 0 {
            Text("\(v.intValue)\(suffix)")
                .foregroundStyle(.secondary)
        }
    }
}
