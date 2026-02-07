import SwiftUI

// MARK: - Phase E: Bolus Adjustment Slider

/// View for adjusting upfront bolus percentage and meal-mode SMB multiplier.
/// Shows real-time preview of how the split changes affect dosing.
struct BolusAdjustSliderView: View {
    let absorptionResult: MacroAbsorptionResult
    let carbRatio: Double
    let onApply: (_ upfrontPercent: Double, _ smbMultiplier: Double) -> Void
    let onCancel: () -> Void

    @State private var upfrontPercent: Double
    @State private var smbMultiplier: Double = 2.0
    @State private var showHighFatWarning = false

    private let highFatThresholdGrams: Double = 15

    init(
        absorptionResult: MacroAbsorptionResult,
        carbRatio: Double,
        defaultSMBMultiplier: Double = 2.0,
        onApply: @escaping (Double, Double) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.absorptionResult = absorptionResult
        self.carbRatio = carbRatio
        self.onApply = onApply
        self.onCancel = onCancel
        _upfrontPercent = State(initialValue: absorptionResult.curveSuggestedPercent)
        _smbMultiplier = State(initialValue: defaultSMBMultiplier)
    }

    var body: some View {
        NavigationView {
            Form {
                upfrontBolusSection
                smbMultiplierSection
                previewSection
            }
            .navigationTitle("Adjust Dosing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(upfrontPercent, smbMultiplier)
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("High-Fat Meal Warning", isPresented: $showHighFatWarning) {
                Button("Keep \(Int(upfrontPercent * 100))%", role: .destructive) {}
                Button("Use Suggested \(Int(absorptionResult.curveSuggestedPercent * 100))%") {
                    upfrontPercent = absorptionResult.curveSuggestedPercent
                }
            } message: {
                Text(
                    "Curve suggests \(Int(absorptionResult.curveSuggestedPercent * 100))% for this meal "
                        + "(\(Int(absorptionResult.originalFat))g fat). "
                        + "\(Int(upfrontPercent * 100))% upfront may cause a low as fat delays carb absorption."
                )
            }
        }
    }

    // MARK: - Upfront Bolus Section

    private var upfrontBolusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Upfront bolus")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(upfrontPercent * 100))%")
                        .font(.headline)
                        .monospacedDigit()
                }

                Slider(value: $upfrontPercent, in: 0 ... 1, step: 0.05)
                    .onChange(of: upfrontPercent) { _, newValue in
                        checkHighFatWarning(newValue)
                    }

                HStack {
                    Text("0%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Curve: \(Int(absorptionResult.curveSuggestedPercent * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("100%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                let upfrontGrams = absorptionResult.originalCarbs * upfrontPercent
                let upfrontUnits = upfrontGrams * absorptionResult.insulinDemandFactor / carbRatio
                Text("Upfront: \(String(format: "%.0f", upfrontGrams))g = \(String(format: "%.1f", upfrontUnits))U")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let remainingGrams = absorptionResult.originalCarbs * (1 - upfrontPercent)
                Text("Remaining via SMBs: \(String(format: "%.0f", remainingGrams))g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reset to Curve Default") {
                upfrontPercent = absorptionResult.curveSuggestedPercent
            }
            .font(.caption)
        } header: {
            Text("Upfront Bolus Percentage")
        } footer: {
            Text("The curve calculates how much carb absorption occurs within the insulin's safe window. Higher percentages deliver more insulin upfront.")
        }
    }

    // MARK: - SMB Multiplier Section

    private var smbMultiplierSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Meal SMB Multiplier")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1fx", smbMultiplier))
                        .font(.headline)
                        .monospacedDigit()
                }

                Slider(value: $smbMultiplier, in: 1.0 ... 3.0, step: 0.1)

                HStack {
                    Text("1.0x")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("2.0x")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("3.0x")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Meal-Mode SMB Enhancement")
        } footer: {
            Text("Temporarily multiplies maxSMB during active meal absorption. Disables automatically if BG drops below floor, BG is falling, or CGM data is stale.")
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        Section {
            let totalEffective = absorptionResult.originalCarbs * absorptionResult.insulinDemandFactor
            let upfrontGrams = absorptionResult.originalCarbs * upfrontPercent * absorptionResult.insulinDemandFactor

            LabeledContent("Original carbs", value: "\(Int(absorptionResult.originalCarbs))g")
            LabeledContent("Demand factor", value: String(format: "%.2fx", absorptionResult.insulinDemandFactor))
            LabeledContent("Total effective", value: "\(Int(totalEffective))g")
            LabeledContent("Upfront bolus", value: String(format: "%.0fg (%.1fU)", upfrontGrams, upfrontGrams / carbRatio))
            LabeledContent("Fat resistance", value: "\(Int(absorptionResult.fatTotalEquiv))g equiv")
            LabeledContent("Protein effect", value: String(format: "%.0f%%", absorptionResult.proteinFactor * 100))
            LabeledContent("Safe window", value: "\(absorptionResult.safeWindowMinutes) min")
        } header: {
            Text("Dosing Preview")
        }
    }

    // MARK: - High-Fat Warning

    private func checkHighFatWarning(_ newPercent: Double) {
        let curveSuggested = absorptionResult.curveSuggestedPercent
        let hasFat = absorptionResult.originalFat > highFatThresholdGrams
        let exceedsSuggestion = newPercent > curveSuggested * 1.5

        if hasFat, exceedsSuggestion {
            showHighFatWarning = true
        }
    }
}
