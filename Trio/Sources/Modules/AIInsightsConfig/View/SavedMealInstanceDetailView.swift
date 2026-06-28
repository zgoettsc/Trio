import Charts
import CoreData
import Foundation
import Swinject
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

    enum ChartMode: String, CaseIterable, Identifiable {
        case absolute, delta
        var id: String { rawValue }
        var label: String {
            switch self {
            case .absolute: return "Absolute"
            case .delta: return "Δ from baseline"
            }
        }
    }

    @State private var chartMode: ChartMode = .absolute

    private let resolver: Resolver = TrioApp.resolver

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
        let estimate = CarbsEstimator.estimate(
            from: instance,
            fallback: fallbackInputs()
        )
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
            let baseline = resolvedBaseline(curve: curve)
            // Δ mode is only meaningful when we have a baseline reference.
            let canShowDelta = baseline != nil
            Section(header: Text("BG curve")) {
                if canShowDelta {
                    Picker("View", selection: $chartMode) {
                        ForEach(ChartMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Chart {
                    ForEach(curve, id: \.t) { point in
                        let y = yValue(for: point.bg, baseline: baseline)
                        LineMark(
                            x: .value("Minutes", point.t),
                            y: .value("BG", y)
                        )
                        .interpolationMethod(.monotone)
                    }
                    if chartMode == .absolute, let baseline {
                        RuleMark(y: .value("Baseline", baseline))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if chartMode == .delta {
                        RuleMark(y: .value("Zero", 0))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    } else {
                        RuleMark(y: .value("180", 180))
                            .foregroundStyle(.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }
                    if let smbs = decodeSMBs() {
                        ForEach(smbs.indices, id: \.self) { idx in
                            let s = smbs[idx]
                            let bgAtT = interpolatedBG(at: s.t, curve: curve)
                            PointMark(
                                x: .value("Minutes", s.t),
                                y: .value("BG", yValue(for: bgAtT, baseline: baseline))
                            )
                            .symbol(.diamond)
                            .symbolSize(15 + s.units * 30)
                            .foregroundStyle(.blue.opacity(0.6))
                        }
                    }
                }
                .frame(height: 220)
                .chartXAxisLabel("Minutes since activation")
                .chartYAxisLabel(chartMode == .delta ? "Δ from baseline (mg/dL)" : "BG (mg/dL)")
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.chart)
        }
    }

    private func yValue(for bg: Double, baseline: Double?) -> Double {
        if chartMode == .delta, let b = baseline { return bg - b }
        return bg
    }

    /// Baseline = stored `bgAtActivation` if present, else the first
    /// point in `bgCurveJSON`. Returns nil when neither is available.
    private func resolvedBaseline(curve: [BGPoint]) -> Double? {
        if let b = instance.bgAtActivation?.doubleValue, b > 0 { return b }
        return curve.first?.bg
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

    /// Resolved estimator inputs — uses stored context fields when present,
    /// falls back to bgCurveJSON (first/max BG) and current profile schedules
    /// for ISF / CR on pre-v10 or backfilled instances. The estimator gets
    /// a `usedFallback` flag so it can downgrade confidence and label clearly.
    private func fallbackInputs() -> CarbsEstimator.FallbackInputs {
        let curve = decodeBGCurve() ?? []
        // BG baseline fallback: first point on the curve.
        let bgFallback: Double? = curve.first?.bg
        // Peak fallback: max of the curve.
        let peakFallback: Double? = curve.map { $0.bg }.max()
        // ISF / CR fallback: pick the schedule entry active at the meal's
        // start time-of-day from the user's current profile JSONs.
        let when = instance.startedAt ?? Date()
        let isfFallback = scheduledValueAt(
            file: OpenAPS.Settings.insulinSensitivities,
            arrayKey: "sensitivities",
            valueKey: "sensitivity",
            at: when
        )
        let crFallback = scheduledValueAt(
            file: OpenAPS.Settings.carbRatios,
            arrayKey: "schedule",
            valueKey: "ratio",
            at: when
        )
        return CarbsEstimator.FallbackInputs(
            bgAtActivation: bgFallback,
            peakBG: peakFallback,
            effectiveISF: isfFallback,
            carbRatio: crFallback
        )
    }

    /// Pulls a profile JSON via FileStorage and finds the active entry for
    /// the given Date's time-of-day. Returns nil if the file is missing or
    /// no entry covers that time. Format both files share: an array of
    /// objects each with `offset` (minutes-from-midnight) + a value field.
    private func scheduledValueAt(
        file: String,
        arrayKey: String,
        valueKey: String,
        at date: Date
    ) -> Double? {
        guard let fileStorage = resolver.resolve(FileStorage.self) else { return nil }
        guard let raw: RawJSON = fileStorage.retrieveRaw(file) else { return nil }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json[arrayKey] as? [[String: Any]],
              !arr.isEmpty
        else { return nil }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minutesIntoDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        // Pick the entry with largest offset <= minutesIntoDay.
        let sorted = arr.compactMap { entry -> (offset: Int, value: Double)? in
            guard let off = entry["offset"] as? Int,
                  let v = entry[valueKey] as? Double else { return nil }
            return (off, v)
        }.sorted { $0.offset < $1.offset }
        let active = sorted.last { $0.offset <= minutesIntoDay } ?? sorted.first
        return active?.value
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

    /// Inputs the view can provide when the instance's own context fields
    /// are missing. Each is optional — fallbacks fill in for pre-v10 /
    /// backfilled rows. When any fallback is used, confidence is downgraded
    /// and the footnote calls out which values came from where.
    struct FallbackInputs {
        let bgAtActivation: Double?
        let peakBG: Double?
        let effectiveISF: Double?
        let carbRatio: Double?

        static let empty = FallbackInputs(
            bgAtActivation: nil, peakBG: nil,
            effectiveISF: nil, carbRatio: nil
        )
    }

    static func estimate(
        from inst: SavedMealInstance,
        fallback: FallbackInputs = .empty
    ) -> Result {
        let entered = inst.carbsAtActivation?.doubleValue ?? 0

        // Resolve each input: stored value first, fallback second. Track
        // which ones used the fallback so we can downgrade confidence.
        var fallbacksUsed: [String] = []

        let bgStart: Double? = {
            if let v = inst.bgAtActivation?.doubleValue, v > 0 { return v }
            if let v = fallback.bgAtActivation, v > 0 {
                fallbacksUsed.append("activation BG from BG curve")
                return v
            }
            return nil
        }()

        let peak: Double? = {
            if inst.peakBG > 0 { return inst.peakBG }
            if let v = fallback.peakBG, v > 0 {
                fallbacksUsed.append("peak BG from BG curve")
                return v
            }
            return nil
        }()

        let isf: Double? = {
            if let v = inst.effectiveISFAtActivation?.doubleValue, v > 0 { return v }
            if let v = fallback.effectiveISF, v > 0 {
                fallbacksUsed.append("ISF from current profile")
                return v
            }
            return nil
        }()

        let cr: Double? = {
            if let v = inst.carbRatioAtActivation?.doubleValue, v > 0 { return v }
            if let v = fallback.carbRatio, v > 0 {
                fallbacksUsed.append("CR from current profile")
                return v
            }
            return nil
        }()

        guard let bgStart, let peak, let isf, let cr else {
            return Result(
                entered: entered,
                estimatedGrams: nil, rangeLabel: nil, deltaGrams: nil, deltaColor: .secondary,
                confidence: .none,
                footnote: "Estimator needs activation BG, peak BG, ISF, and CR. At least one is missing (no BG curve on this instance, no profile on disk, or pre-v10)."
            )
        }

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
        if !fallbacksUsed.isEmpty {
            // Fallbacks always cap at low — the stored context is the truth;
            // using today's profile / curve-derived values is best-effort.
            confidence = min(confidence, .low)
            caveats.append("using fallback values for: " + fallbacksUsed.joined(separator: ", "))
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
