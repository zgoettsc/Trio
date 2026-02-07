import SwiftUI

/// Presented when no recent meal delta is found — shows today's grouped meals
/// so the user can select one to dose for (late dosing).
struct CronometerMealPickerView: View {
    let meals: [InferredMealEvent]
    let alreadyDosedMealDates: Set<Date> // Dates of meals that already have a recommendation logged
    let onSelect: (InferredMealEvent) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if meals.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            Text("No new food detected since your last snapshot. Select a meal from today to dose for.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }

                        Section("Today's Meals") {
                            ForEach(meals.reversed()) { meal in
                                mealRow(meal)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Meal Row

    private func mealRow(_ meal: InferredMealEvent) -> some View {
        let warning = CarbDecayModel.warningLevel(minutesSinceMeal: meal.minutesAgo)
        let carbFraction = CarbDecayModel.carbsRemainingFraction(minutesSinceMeal: meal.minutesAgo)
        let remainingCarbs = Int(meal.carbsDelta * carbFraction)
        let isAlreadyDosed = isMealAlreadyDosed(meal)
        let isTooOld = warning == .severe

        return Button(action: {
            onSelect(meal)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Time and status
                HStack {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(meal.detectedAt.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline.bold())
                    Text("(\(meal.timeAgoString))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isAlreadyDosed {
                        Label("Dosed", systemImage: "checkmark.circle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    }

                    warningBadge(warning)
                }

                // Macros
                HStack(spacing: 12) {
                    macroLabel("C", value: Int(meal.carbsDelta), color: .blue)
                    macroLabel("F", value: Int(meal.fatDelta), color: .yellow)
                    macroLabel("P", value: Int(meal.proteinDelta), color: .red)
                    Text("\(Int(meal.totalCalories)) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Remaining carbs estimate
                if meal.minutesAgo > 15 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right")
                            .font(.caption2)
                        Text("Est. \(remainingCarbs)g carbs remaining (\(Int(carbFraction * 100))%)")
                            .font(.caption)
                    }
                    .foregroundStyle(warningColor(warning))
                }

                // Warning message for old meals
                if isTooOld {
                    Text(warning.message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
            .opacity(isTooOld ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Meals Today")
                .font(.headline)
            Text("No Cronometer meals detected today. Log food in Cronometer and it will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func macroLabel(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(value)g")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func warningBadge(_ warning: CarbDecayModel.LateDoseWarning) -> some View {
        Group {
            switch warning {
            case .none:
                EmptyView()
            case .mild:
                Image(systemName: "clock.badge")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            case .moderate:
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .severe:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func warningColor(_ warning: CarbDecayModel.LateDoseWarning) -> Color {
        switch warning {
        case .none: return .green
        case .mild: return .yellow
        case .moderate: return .orange
        case .severe: return .red
        }
    }

    /// Check if a meal was already dosed by comparing timestamps within 30 minutes
    private func isMealAlreadyDosed(_ meal: InferredMealEvent) -> Bool {
        alreadyDosedMealDates.contains { dosedDate in
            abs(dosedDate.timeIntervalSince(meal.detectedAt)) < 30 * 60
        }
    }
}
