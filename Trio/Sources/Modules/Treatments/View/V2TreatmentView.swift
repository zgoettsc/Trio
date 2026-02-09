import SwiftUI
import Swinject

/// V2 Treatment flow container. Manages the two-step flow:
/// Step 1: Meal feed — user selects recent meals/nutrition from HealthKit observer
/// Step 2: Dose preview — two-line BG forecast, treatment plan, adjustment sliders, confirm
struct V2TreatmentView: View {
    @Bindable var state: Treatments.StateModel
    let resolver: Resolver
    let onSwitchToV1: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState
    @Environment(\.openURL) private var openURL

    enum V2Step {
        case mealFeed
        case dosePreview
    }

    @State private var currentStep: V2Step = .mealFeed
    @State private var selectedMealIndices: Set<Int> = []
    @State private var manualEntryCarbs: Decimal = 0
    @State private var manualEntryFat: Decimal = 0
    @State private var manualEntryProtein: Decimal = 0
    @State private var manualEntryFiber: Decimal = 0
    @State private var showManualEntry = false
    @State private var showCronometerLog = false

    /// Combined macros from all selected meals
    private var combinedCarbs: Double {
        var total = 0.0
        for index in selectedMealIndices {
            guard index < state.v2DetectedMeals.count else { continue }
            total += state.v2DetectedMeals[index].carbs
        }
        return total
    }

    private var combinedFat: Double {
        var total = 0.0
        for index in selectedMealIndices {
            guard index < state.v2DetectedMeals.count else { continue }
            total += state.v2DetectedMeals[index].fat
        }
        return total
    }

    private var combinedProtein: Double {
        var total = 0.0
        for index in selectedMealIndices {
            guard index < state.v2DetectedMeals.count else { continue }
            total += state.v2DetectedMeals[index].protein
        }
        return total
    }

    private var combinedFiber: Double {
        var total = 0.0
        for index in selectedMealIndices {
            guard index < state.v2DetectedMeals.count else { continue }
            total += state.v2DetectedMeals[index].fiber
        }
        return total
    }

    private var hasSelection: Bool {
        !selectedMealIndices.isEmpty
    }

    var body: some View {
        ZStack(alignment: .center) {
            VStack(spacing: 0) {
                switch currentStep {
                case .mealFeed:
                    mealFeedContent
                case .dosePreview:
                    V2DosePreviewView(
                        state: state,
                        combinedCarbs: combinedCarbs,
                        combinedFat: combinedFat,
                        combinedProtein: combinedProtein,
                        combinedFiber: combinedFiber,
                        selectedMeals: selectedMealsList,
                        onBack: { currentStep = .mealFeed },
                        onSwitchToV1: onSwitchToV1
                    )
                }
            }
            .blur(radius: state.isAwaitingDeterminationResult ? 5 : 0)

            if state.isAwaitingDeterminationResult {
                CustomProgressView(text: ProgressText.updatingTreatments.displayName)
            }
        }
    }

    // MARK: - Meal Feed (Step 1)

    private var mealFeedContent: some View {
        List {
            // Selected meals summary bar
            if hasSelection {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(selectedMealIndices.count) item\(selectedMealIndices.count == 1 ? "" : "s") selected")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 12) {
                                macroLabel("C", value: combinedCarbs, color: .orange)
                                macroLabel("F", value: combinedFat, color: .yellow)
                                macroLabel("P", value: combinedProtein, color: .red)
                                if combinedFiber > 0 {
                                    macroLabel("Fiber", value: combinedFiber, color: .green)
                                }
                            }
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.blue.opacity(0.1))
            }

            // Meal list
            Section(header: Text("Recent Meals & Nutrition")) {
                if state.v2DetectedMeals.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "fork.knife.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No recent meals detected")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Log a meal in Cronometer or enter one manually.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(Array(state.v2DetectedMeals.enumerated()), id: \.offset) { index, meal in
                        V2MealCardView(
                            meal: meal,
                            isSelected: selectedMealIndices.contains(index),
                            isDosed: meal.isDosed,
                            onToggle: {
                                if selectedMealIndices.contains(index) {
                                    selectedMealIndices.remove(index)
                                } else {
                                    selectedMealIndices.insert(index)
                                }
                            }
                        )
                    }
                }
            }
            .listRowBackground(Color.chart)

            // Actions
            Section {
                Button {
                    showManualEntry = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Enter meal manually")
                            .foregroundStyle(.primary)
                    }
                }

                Button {
                    Task {
                        await state.recordCronometerBaseline()
                        if let url = URL(string: "cronometer://") {
                            openURL(url)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.green)
                        Text("Log in Cronometer")
                            .foregroundStyle(.primary)
                    }
                }

                // Correction-only shortcut
                Button {
                    // Go directly to dose preview with zero carbs (correction bolus)
                    selectedMealIndices.removeAll()
                    state.carbs = 0
                    state.fat = 0
                    state.protein = 0
                    currentStep = .dosePreview
                } label: {
                    HStack {
                        Image(systemName: "syringe")
                            .foregroundStyle(.purple)
                        Text("Correction bolus only")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .listRowBackground(Color.chart)

            // Continue button
            Section {
                Button {
                    applySelectionToState()
                    currentStep = .dosePreview
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 35)
                }
                .disabled(!hasSelection)
                .listRowBackground(hasSelection ? Color.blue : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .onAppear {
            Task { await state.loadV2DetectedMeals() }
        }
        .sheet(isPresented: $showManualEntry) {
            V2ManualMealEntryView(
                carbs: $manualEntryCarbs,
                fat: $manualEntryFat,
                protein: $manualEntryProtein,
                fiber: $manualEntryFiber,
                onAdd: { c, f, p, fib in
                    state.addManualV2Meal(carbs: c, fat: f, protein: p, fiber: fib)
                    showManualEntry = false
                },
                onDismiss: { showManualEntry = false }
            )
        }
    }

    private func applySelectionToState() {
        // Use combined macros for the bolus calculator display,
        // but the V2 engine will process each meal independently via selectedMeals.
        state.carbs = Decimal(combinedCarbs)
        state.fat = Decimal(combinedFat)
        state.protein = Decimal(combinedProtein)
        state.fiber = Decimal(combinedFiber)
        // Pass selected meals with timestamps to state for the V2 forecast chart
        state.v2SelectedMealsForChart = selectedMealsList
        Task {
            await state.updateForecasts()
            state.insulinCalculated = await state.calculateInsulin()
        }
    }

    /// The selected meals with their original timestamps preserved for independent entry generation.
    private var selectedMealsList: [V2DetectedMeal] {
        selectedMealIndices.compactMap { idx in
            idx < state.v2DetectedMeals.count ? state.v2DetectedMeals[idx] : nil
        }
    }

    private func macroLabel(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(color)
            Text("\(Int(value))g").font(.caption.weight(.medium))
        }
    }
}
