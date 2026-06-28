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
        .sheet(
            isPresented: Binding(
                get: { showStartConfirm != nil },
                set: { if !$0 { showStartConfirm = nil } }
            )
        ) {
            if let meal = showStartConfirm {
                NavigationView {
                    StartSavedMealConfirmSheet(meal: meal) { carbs, fat, protein in
                        showStartConfirm = nil
                        Task { await startMeal(meal, carbs: carbs, fat: fat, protein: protein) }
                    } onCancel: {
                        showStartConfirm = nil
                    }
                }
            }
        }
    }

    @MainActor
    private func startMeal(
        _ meal: SavedMeal,
        carbs: Decimal?,
        fat: Decimal?,
        protein: Decimal?
    ) async {
        guard #available(iOS 16.0, *), let mealId = meal.id else { return }
        let req = AnnounceMealIntentRequest()
        do {
            // Logs a CarbEntry with the (possibly edited) macros AND opens
            // the window. Bolus is still a separate step.
            startResult = try await req.startMealAndLogCarbs(
                savedMealId: mealId,
                carbsOverride: carbs,
                fatOverride: fat,
                proteinOverride: protein
            )
        } catch {
            startResult = "Failed to start: \(error.localizedDescription)"
        }
    }
}

/// Confirmation sheet shown when the user taps the play button on a saved
/// meal. Pre-fills the meal's default macros, lets the user scale by a quick
/// portion shortcut (½, ¾, 1, 1¼, 1½, 2) or hand-edit each field before
/// committing to log the carb entry and open the eating-mode window.
private struct StartSavedMealConfirmSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @ObservedObject var meal: SavedMeal
    let onStart: (Decimal?, Decimal?, Decimal?) -> Void
    let onCancel: () -> Void

    // Defaults captured once on init so portion math is stable even if the
    // user types into a field and then changes their mind via a portion chip.
    private let defaultCarbs: Decimal
    private let defaultFat: Decimal
    private let defaultProtein: Decimal

    @State private var carbsText: String
    @State private var fatText: String
    @State private var proteinText: String

    private enum MacroField: Hashable { case carbs, fat, protein }
    @FocusState private var focusedField: MacroField?

    init(
        meal: SavedMeal,
        onStart: @escaping (Decimal?, Decimal?, Decimal?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.meal = meal
        self.onStart = onStart
        self.onCancel = onCancel
        let dc = (meal.defaultCarbs as Decimal?) ?? 0
        let df = (meal.defaultFat as Decimal?) ?? 0
        let dp = (meal.defaultProtein as Decimal?) ?? 0
        defaultCarbs = dc
        defaultFat = df
        defaultProtein = dp
        _carbsText = State(initialValue: Self.format(dc))
        _fatText = State(initialValue: Self.format(df))
        _proteinText = State(initialValue: Self.format(dp))
    }

    private static func format(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        return n.doubleValue == 0 ? "" : "\(n.intValue)"
    }

    private static func parse(_ s: String) -> Decimal {
        Decimal(string: s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func applyPortion(_ factor: Double) {
        func scale(_ d: Decimal) -> String {
            let v = NSDecimalNumber(decimal: d).doubleValue * factor
            return v <= 0 ? "" : "\(Int(v.rounded()))"
        }
        carbsText = scale(defaultCarbs)
        fatText = scale(defaultFat)
        proteinText = scale(defaultProtein)
    }

    var body: some View {
        Form {
            Section(header: Text(meal.name ?? "(unnamed)")) {
                HStack {
                    Text(meal.icon ?? "🍽️").font(.largeTitle)
                    if let cls = meal.defaultClassification {
                        Spacer()
                        Text(cls.capitalized)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Portion"),
                footer: Text("Tap to scale all macros from the meal's defaults. You can also fine-tune each field below.")
            ) {
                HStack {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { factor in
                        Button(label(for: factor)) { applyPortion(factor) }
                            .font(.caption)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                            .buttonStyle(.plain)
                    }
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Macros to log"),
                footer: Text("Tap a box to type a different amount. These values will be logged as a carb entry when you tap Start.")
            ) {
                macroField("Carbs", text: $carbsText, field: .carbs)
                macroField("Fat", text: $fatText, field: .fat)
                macroField("Protein", text: $proteinText, field: .protein)
            }
            .listRowBackground(Color.chart)

            if meal.defaultPhantomCOBEnabled || meal.defaultExtendedDurationMinutes > 0 {
                Section(header: Text("Window")) {
                    if meal.defaultPhantomCOBEnabled {
                        HStack {
                            Text("Phantom COB")
                            Spacer()
                            Text(meal.defaultPhantomCOBGrams.map { "\($0.intValue) g" } ?? "default")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if meal.defaultExtendedDurationMinutes > 0 {
                        HStack {
                            Text("Extended duration")
                            Spacer()
                            Text(String(format: "%.1f h", Double(meal.defaultExtendedDurationMinutes) / 60.0))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Start meal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    let c = Self.parse(carbsText)
                    let f = Self.parse(fatText)
                    let p = Self.parse(proteinText)
                    onStart(c, f, p)
                }
            }
            // decimalPad has no return key — give the user a way out.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    @ViewBuilder
    private func macroField(_ label: String, text: Binding<String>, field: MacroField) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: field)
                .frame(width: 70, height: 32)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(focusedField == field ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { focusedField = field }
            Text("g").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    private func label(for factor: Double) -> String {
        switch factor {
        case 0.5: return "½"
        case 0.75: return "¾"
        case 1.0: return "1×"
        case 1.25: return "1¼"
        case 1.5: return "1½"
        case 2.0: return "2×"
        default: return String(format: "%.2f×", factor)
        }
    }
}

private struct SavedMealRow: View {
    @ObservedObject var meal: SavedMeal
    let onTap: () -> Void

    /// cachedInstanceCount only counts CLOSED instances (matches the
    /// SavedMealStorage update logic). If a window is currently active for
    /// this meal, surface it so the row reads "1 · in progress" instead of
    /// "0 ·" while the user is still eating.
    private var activeInstanceCount: Int {
        let arr = (meal.instances?.allObjects as? [SavedMealInstance]) ?? []
        return arr.filter { $0.closedAt == nil }.count
    }

    private var displayCount: Int {
        Int(meal.cachedInstanceCount) + activeInstanceCount
    }

    var body: some View {
        HStack {
            NavigationLink(destination: SavedMealDetailView(meal: meal)) {
                HStack {
                    Text(meal.icon ?? "🍽️")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.name ?? "(unnamed)").font(.headline)
                        HStack(spacing: 6) {
                            Text("\(displayCount) ×")
                            if activeInstanceCount > 0 {
                                Text("·").foregroundStyle(.tertiary)
                                Text("in progress").foregroundStyle(.green)
                            }
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
