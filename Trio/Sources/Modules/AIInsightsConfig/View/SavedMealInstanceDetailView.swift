import Charts
import CoreData
import Foundation
import SwiftUI

/// Per-instance detail page. Navigated to from a SavedMealDetailView history
/// row. Shows what the meal *actually did* to BG, what we logged vs what we
/// can back-calculate it "looked like" given delivered insulin, plus the
/// sensitivity context that was in play when the window opened.
///
/// Helps answer "did I miscount?" — the most common cause of an unexpectedly
/// hot meal is severely-undercounted carbs. The estimator surfaces that.
struct SavedMealInstanceDetailView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @ObservedObject var instance: SavedMealInstance

    var body: some View {
        Form {
            headerSection
            carbsEstimateSection
            chartSection
            metricsSection
            contextSection
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(instance.savedMeal?.name ?? "Instance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack {
                Text(instance.savedMeal?.icon ?? "🍽️").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    if let started = instance.startedAt {
                        Text(started, style: .date).font(.subheadline)
                        Text(started, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    if let cls = instance.finalClassification {
                        Text(cls.capitalized)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Spacer()
                if instance.outcomeScore > 0 {
                    VStack {
                        Text("\(instance.outcomeScore)").font(.title2.bold())
                        Text("score").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if instance.backfilled || instance.windowHadOverride || instance.windowHadTempTarget {
                HStack(spacing: 12) {
                    if instance.backfilled {
                        Label("Backfilled", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    if instance.windowHadOverride {
                        Label("Override active", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if instance.windowHadTempTarget {
                        Label("Temp target", systemImage: "target")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private var carbsEstimateSection: some View {
        let estimate = CarbsEstimator.estimate(from: instance)
        Section(
            header: Text("Carbs"),
            footer: Text(estimate.footnote)
        ) {
            HStack {
                Text("Entered")
                Spacer()
                Text(formatGrams(estimate.entered))
                    .foregroundStyle(.secondary)
            }
            if let est = estimate.estimatedGrams {
                HStack {
                    Text("Estimated from BG")
                    Spacer()
                    Text(estimate.rangeLabel ?? formatGrams(est))
                        .foregroundStyle(estimate.deltaColor)
                }
                if let delta = estimate.deltaGrams, abs(delta) >= 5 {
                    HStack {
                        Text("Δ vs entered")
                        Spacer()
                        Text(formatDelta(delta))
                            .foregroundStyle(estimate.deltaColor)
                    }
                }
            } else {
                Text("Not enough data to estimate — needs activation BG, peak BG, ISF, and CR.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Confidence")
                Spacer()
                Text(estimate.confidence.label).foregroundStyle(estimate.confidence.color)
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private var chartSection: some View {
        if let curve = decodeBGCurve(), !curve.isEmpty {
            Section(header: Text("BG curve")) {
                Chart {
                    ForEach(curve, id: \.t) { point in
                        LineMark(
                            x: .value("Minutes", point.t),
                            y: .value("BG", point.bg)
                        )
                        .interpolationMethod(.monotone)
                    }
                    if let baseline = instance.bgAtActivation?.doubleValue {
                        RuleMark(y: .value("Baseline", baseline))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    RuleMark(y: .value("180", 180))
                        .foregroundStyle(.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    if let smbs = decodeSMBs() {
                        ForEach(smbs.indices, id: \.self) { idx in
                            let s = smbs[idx]
                            PointMark(
                                x: .value("Minutes", s.t),
                                y: .value("BG", interpolatedBG(at: s.t, curve: curve))
                            )
                            .symbol(.diamond)
                            .symbolSize(15 + s.units * 30)
                            .foregroundStyle(.blue.opacity(0.6))
                        }
                    }
                }
                .frame(height: 220)
                .chartXAxisLabel("Minutes since activation")
                .chartYAxisLabel("BG (mg/dL)")
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.chart)
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        Section(header: Text("Metrics")) {
            metricRow("Peak BG", value: instance.peakBG > 0 ? "\(Int(instance.peakBG)) mg/dL" : "—")
            metricRow("Time in range", value: minutes(instance.timeInRangeMinutes))
            metricRow("Time above 180", value: minutes(instance.timeAboveRangeMinutes))
            metricRow("Time below 70", value: minutes(instance.timeBelowRangeMinutes))
            metricRow("Time to baseline", value: instance.timeToBaselineMinutes > 0 ? minutes(instance.timeToBaselineMinutes) : "didn't return")
            metricRow("Total insulin", value: String(format: "%.2f U", instance.totalInsulinDeliveredU))
            metricRow("SMBs", value: "\(instance.smbCount)")
            metricRow("Floor activations", value: "\(instance.floorActivationCount)")
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private var contextSection: some View {
        Section(
            header: Text("Activation context"),
            footer: Text("Captured at window open. Use these to compare runs of the same meal under different sensitivity conditions.")
        ) {
            if let bg = instance.bgAtActivation {
                metricRow("BG at activation", value: "\(bg.intValue) mg/dL")
            }
            if let trend = instance.bgTrendAtActivation {
                let v = trend.doubleValue
                metricRow("Trend (prior 30 min)",
                          value: "\(v >= 0 ? "+" : "")\(Int(v.rounded())) mg/dL")
            }
            if let r = instance.autosensRatioAtActivation {
                metricRow("Autosens", value: String(format: "%.2f×", r.doubleValue))
            }
            if let r = instance.smartSenseRatioAtActivation {
                metricRow("Smart Sense", value: String(format: "%.2f×", r.doubleValue))
            }
            if let isf = instance.effectiveISFAtActivation {
                metricRow("Effective ISF", value: "\(isf.intValue) mg/dL/U")
            }
            if let cr = instance.carbRatioAtActivation {
                metricRow("CR", value: String(format: "%.1f g/U", cr.doubleValue))
            }
            if instance.bgAtActivation == nil,
               instance.autosensRatioAtActivation == nil,
               instance.effectiveISFAtActivation == nil
            {
                Text("No context captured — instance pre-dates schema v10, or was backfilled without live data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.chart)
    }

    // MARK: - Helpers

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func minutes(_ m: Int32) -> String {
        let mins = Int(m)
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let r = mins % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) m"
    }

    private func formatGrams(_ g: Double) -> String {
        "\(Int(g.rounded())) g"
    }

    private func formatDelta(_ g: Double) -> String {
        let sign = g >= 0 ? "+" : ""
        return "\(sign)\(Int(g.rounded())) g"
    }

    private struct BGPoint: Decodable {
        let t: Double
        let bg: Double
    }

    private struct SMBPoint: Decodable {
        let t: Double
        let units: Double
    }

    private func decodeBGCurve() -> [BGPoint]? {
        guard let json = instance.bgCurveJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([BGPoint].self, from: data)
    }

    private func decodeSMBs() -> [SMBPoint]? {
        guard let json = instance.smbsJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SMBPoint].self, from: data)
    }

    /// Best-effort BG at a given minute via linear interpolation; falls back
    /// to nearest point. Used to anchor SMB diamonds on the line.
    private func interpolatedBG(at t: Double, curve: [BGPoint]) -> Double {
        guard !curve.isEmpty else { return 0 }
        if t <= curve.first!.t { return curve.first!.bg }
        if t >= curve.last!.t { return curve.last!.bg }
        for i in 1..<curve.count {
            let a = curve[i - 1], b = curve[i]
            if b.t >= t {
                let span = b.t - a.t
                if span <= 0 { return a.bg }
                let frac = (t - a.t) / span
                return a.bg + (b.bg - a.bg) * frac
            }
        }
        return curve.last!.bg
    }
}

// MARK: - Estimator

/// Back-calculates how many grams of carbs the BG response "looks like,"
/// using observed peak BG above activation baseline + the actual insulin
/// delivered, against the user's ISF and CR at activation.
///
/// Identity used:  1 g carbs raises BG by ISF / CR mg/dL
/// Solve for carbs:
///   carbs_eq_of_BG_rise = (peakBG - bgAtActivation) / (ISF / CR)
///                       = (peakBG - bgAtActivation) × CR / ISF
///   carbs_offset_by_insulin = totalInsulinDeliveredU × CR
///   estimated_total = carbs_eq_of_BG_rise + carbs_offset_by_insulin
///
/// Range is ±15% to reflect ISF/CR uncertainty (the dominant noise source).
/// Confidence label is bumped down when override was active, the window
/// didn't return to baseline, or context fields were missing.
enum CarbsEstimator {
    enum Confidence {
        case high, medium, low, none
        var label: String {
            switch self {
            case .high: return "high"
            case .medium: return "medium"
            case .low: return "low"
            case .none: return "—"
            }
        }
        var color: Color {
            switch self {
            case .high: return .green
            case .medium: return .orange
            case .low: return .red
            case .none: return .secondary
            }
        }
    }

    struct Result {
        let entered: Double
        let estimatedGrams: Double?
        let rangeLabel: String?
        let deltaGrams: Double?
        let deltaColor: Color
        let confidence: Confidence
        let footnote: String
    }

    static func estimate(from inst: SavedMealInstance) -> Result {
        let entered = inst.carbsAtActivation?.doubleValue ?? 0

        guard
            let bgStartN = inst.bgAtActivation, bgStartN.doubleValue > 0,
            inst.peakBG > 0,
            let isfN = inst.effectiveISFAtActivation, isfN.doubleValue > 0,
            let crN = inst.carbRatioAtActivation, crN.doubleValue > 0
        else {
            return Result(
                entered: entered,
                estimatedGrams: nil, rangeLabel: nil, deltaGrams: nil, deltaColor: .secondary,
                confidence: .none,
                footnote: "Estimator needs activation BG, peak BG, effective ISF, and CR — at least one is missing for this instance (likely pre-v10 or backfilled)."
            )
        }

        let bgStart = bgStartN.doubleValue
        let peak = inst.peakBG
        let isf = isfN.doubleValue
        let cr = crN.doubleValue
        let insulin = max(0, inst.totalInsulinDeliveredU)

        let rise = max(0, peak - bgStart)
        let carbsForRise = rise * cr / isf
        let carbsOffsetByInsulin = insulin * cr
        let total = carbsForRise + carbsOffsetByInsulin

        // ±15% ISF/CR uncertainty → ±15% on estimate
        let low = total * 0.85
        let high = total * 1.15
        let range = "\(Int(low.rounded()))–\(Int(high.rounded())) g"

        let delta = entered > 0 ? total - entered : nil
        let color: Color = {
            guard let d = delta else { return .secondary }
            let pct = abs(d) / max(entered, 1)
            if pct < 0.2 { return .green }
            if pct < 0.5 { return .orange }
            return .red
        }()

        var confidence: Confidence = .high
        var caveats: [String] = []
        if inst.windowHadOverride {
            confidence = .low
            caveats.append("override was active (altered dosing, makes back-calc unreliable)")
        }
        if inst.windowHadTempTarget {
            confidence = min(confidence, .medium)
            caveats.append("temp target was active")
        }
        if inst.timeToBaselineMinutes == 0 {
            confidence = min(confidence, .medium)
            caveats.append("BG didn't return to baseline within the window — estimate is a lower bound on what actually arrived")
        }
        if inst.backfilled {
            confidence = min(confidence, .medium)
            caveats.append("instance was backfilled, not live-tracked")
        }
        let footnote: String = {
            var parts = [
                "Back-calculated from peak BG rise (\(Int(rise.rounded())) mg/dL) + insulin delivered (\(String(format: "%.2f", insulin)) U), against ISF \(Int(isf)) mg/dL/U and CR \(String(format: "%.1f", cr)) g/U. Range reflects ±15% ISF/CR uncertainty."
            ]
            if !caveats.isEmpty {
                parts.append("Caveats: " + caveats.joined(separator: "; ") + ".")
            }
            return parts.joined(separator: " ")
        }()

        return Result(
            entered: entered,
            estimatedGrams: total,
            rangeLabel: range,
            deltaGrams: delta,
            deltaColor: color,
            confidence: confidence,
            footnote: footnote
        )
    }
}

private func min(_ a: CarbsEstimator.Confidence, _ b: CarbsEstimator.Confidence) -> CarbsEstimator.Confidence {
    func rank(_ c: CarbsEstimator.Confidence) -> Int {
        switch c { case .high: return 3; case .medium: return 2; case .low: return 1; case .none: return 0 }
    }
    return rank(a) <= rank(b) ? a : b
}
