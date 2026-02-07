import SwiftUI

// MARK: - Phase E: Meal Detected Banner

/// Banner shown on the home screen when Cronometer logs a new meal.
/// Displays macro breakdown, sensitivity context, split dosing info, and action buttons.
struct MealDetectedBannerView: View {
    let meal: ActiveMeal
    let absorptionResult: MacroAbsorptionResult?
    let sensitivityContributions: [GarminSensitivityModel.SensitivityResult.Contribution]
    let onDose: () -> Void
    let onAdjust: () -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = true

    var body: some View {
        if isVisible {
            bannerContent
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4), value: isVisible)
        }
    }

    @ViewBuilder
    private var bannerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            headerRow

            // Macro display
            macroRow

            // Sensitivity info (if Garmin data available)
            if !sensitivityContributions.isEmpty,
               let result = absorptionResult,
               abs(result.insulinDemandFactor - 1.0) > 0.01
            {
                sensitivityRow(demandFactor: result.insulinDemandFactor)
            }

            // Split dosing breakdown
            if let result = absorptionResult {
                splitDosingRow(result: result)
            }

            // Warning
            Text("Carbs logged automatically. Do NOT also enter carbs manually.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
                .italic()

            // Action buttons
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.85), Color.indigo.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .padding(.horizontal, 12)
    }

    private var headerRow: some View {
        HStack {
            Image(systemName: "fork.knife.circle.fill")
                .font(.title2)
                .foregroundColor(.white)
            Text("New meal detected from Cronometer")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Spacer()
            Button(action: {
                withAnimation { isVisible = false }
                onDismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private var macroRow: some View {
        HStack(spacing: 16) {
            macroLabel("Carbs", value: meal.originalCarbs, unit: "g", color: .green)
            macroLabel("Fat", value: meal.originalFat, unit: "g", color: .orange)
            macroLabel("Protein", value: meal.originalProtein, unit: "g", color: .red)
        }
    }

    private func macroLabel(_ name: String, value: Double, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            Text("\(Int(value))\(unit)")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func sensitivityRow(demandFactor: Double) -> some View {
        let percentChange = Int((demandFactor - 1.0) * 100)
        let direction = percentChange > 0 ? "more" : "less"
        let topContribution = sensitivityContributions.first { $0.impact != 0 }

        return VStack(alignment: .leading, spacing: 2) {
            Text("Sensitivity-adjusted: need \(abs(percentChange))% \(direction) insulin today")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.yellow)
            if let contrib = topContribution {
                Text(contrib.description)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private func splitDosingRow(result: MacroAbsorptionResult) -> some View {
        let upfrontUnits = result.upfrontCarbs // This is demand-adjusted grams; caller divides by CR
        let remainingGrams = result.futureEntries.reduce(0.0) {
            $0 + Double(truncating: $1.carbs as NSDecimalNumber)
        }
        let percentDisplay = Int(result.upfrontPercent * 100)

        return VStack(alignment: .leading, spacing: 3) {
            Text("Upfront: \(String(format: "%.0f", upfrontUnits))g (\(percentDisplay)% of carbs)")
                .font(.caption)
                .foregroundColor(.white)
            Text("Remaining: \(String(format: "%.0f", remainingGrams))g effective COB via SMBs")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onDose) {
                Text("Dose")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }

            Button(action: onAdjust) {
                Text("Adjust")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }

            Button(action: onSkip) {
                Text("Skip")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.2))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
    }
}

// MARK: - Post-Dosing Banner

/// Compact banner shown after the user has dosed for a detected meal.
struct MealDosingActiveBannerView: View {
    let meal: ActiveMeal
    let mealModeActive: Bool
    let mealSMBMultiplier: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dosed — \(mealTimeSummary)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                if let units = meal.dosingState.dosedUnits {
                    Text("\(String(format: "%.1f", units))U delivered")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                if mealModeActive {
                    Text("Meal-mode SMBs: active (\(String(format: "%.1f", mealSMBMultiplier))x)")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.2))
        )
        .padding(.horizontal, 12)
    }

    private var mealTimeSummary: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: meal.detectedAt)
    }
}
