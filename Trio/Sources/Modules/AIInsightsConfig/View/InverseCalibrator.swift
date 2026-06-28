import CoreData
import Foundation
import SwiftUI

/// Flip of `CarbsEstimator`. Given a user-verified true carb count for an
/// instance, back-calculates the CR or ISF that the BG response actually
/// implies. The forward estimator's accuracy is bounded by CR/ISF accuracy;
/// flipping lets a confident carb count *validate* those foundational
/// settings instead.
///
/// Identity:  carbs = peak_rise × CR/ISF + insulin × CR
///
/// Solve for CR (assuming ISF is right):
///   CR = carbs / (peak_rise/ISF + insulin)
///
/// Solve for ISF (assuming CR is right):
///   ISF = peak_rise × CR / (carbs − insulin × CR)
///
/// Single observations are noisy. Pair with the aggregator on
/// SavedMealDetailView for n≥2 medians, and trust the value the user
/// trusts more (usually ISF from a physio test).
enum InverseCalibrator {
    struct Result {
        let verifiedCarbs: Double
        let assumedISF: Double
        let assumedCR: Double
        let backCalcCR: Double?
        let backCalcISF: Double?
        let deltaCRPercent: Double?
        let deltaISFPercent: Double?
        let confidence: CarbsEstimator.Confidence
        let footnote: String
        /// True when the rise/insulin combination is degenerate — e.g. all
        /// of the verified carbs got covered by the delivered insulin and
        /// there is no rise left to attribute to ISF. Lets the aggregator
        /// throw those rows out cleanly.
        let isfIndeterminate: Bool
    }

    static func calibrate(
        from inst: SavedMealInstance,
        fallback: CarbsEstimator.FallbackInputs = .empty
    ) -> Result? {
        guard let verifiedDec = inst.userVerifiedCarbsAmount,
              verifiedDec.doubleValue > 0
        else { return nil }
        let verified = verifiedDec.doubleValue

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
                verifiedCarbs: verified,
                assumedISF: 0, assumedCR: 0,
                backCalcCR: nil, backCalcISF: nil,
                deltaCRPercent: nil, deltaISFPercent: nil,
                confidence: .none,
                footnote: "Calibrator needs activation BG, peak BG, ISF, and CR. At least one is missing for this instance.",
                isfIndeterminate: true
            )
        }

        // Same legacy-row handling as CarbsEstimator: if stored insulin is
        // implausibly negative (pre-fix overlap bug), fall back to SMB sum.
        let smbSum = smbSumFromJSON(inst)
        let insulin: Double = {
            let stored = inst.totalInsulinDeliveredU
            if stored < 0, abs(stored) > smbSum {
                return smbSum
            }
            return stored
        }()

        let rise = max(0, peak - bgStart)

        // CR back-calc (assume ISF correct): denominator is rise/ISF + insulin.
        // Both terms are non-negative for any plausible meal; if the
        // denominator is zero (no rise, no insulin) the calc is meaningless.
        let crDenom = rise / isf + insulin
        let backCR: Double? = crDenom > 0.01 ? verified / crDenom : nil

        // ISF back-calc (assume CR correct): denominator is carbs - insulin×CR.
        // If the loop delivered enough insulin to cover all the verified
        // carbs at the current CR (denominator <= 0), there's no rise
        // budget left for ISF to explain — mark indeterminate.
        let isfDenom = verified - insulin * cr
        let isfIndeterminate = isfDenom <= 0.5 || rise < 5
        let backISF: Double? = isfIndeterminate ? nil : rise * cr / isfDenom

        let deltaCRPct: Double? = backCR.map { ($0 - cr) / cr * 100 }
        let deltaISFPct: Double? = backISF.map { ($0 - isf) / isf * 100 }

        var confidence: CarbsEstimator.Confidence = .high
        var caveats: [String] = []
        if inst.windowHadOverride {
            confidence = .low
            caveats.append("override was active (altered dosing, makes back-calc unreliable)")
        }
        if inst.windowHadTempTarget {
            confidence = confidence.downgraded(to: .medium)
            caveats.append("temp target was active")
        }
        if inst.timeToBaselineMinutes == 0 {
            confidence = confidence.downgraded(to: .medium)
            caveats.append("BG didn't return to baseline — back-calc treats peak rise as final, slight under-estimate of carbs needed")
        }
        if inst.backfilled {
            confidence = confidence.downgraded(to: .medium)
            caveats.append("instance was backfilled, not live-tracked")
        }
        if !fallbacksUsed.isEmpty {
            confidence = confidence.downgraded(to: .low)
            caveats.append("using fallback values for: " + fallbacksUsed.joined(separator: ", "))
        }
        if inst.totalInsulinDeliveredU < 0, abs(inst.totalInsulinDeliveredU) > smbSum {
            confidence = confidence.downgraded(to: .low)
            caveats.append("legacy row, stored insulin (\(String(format: "%.2f", inst.totalInsulinDeliveredU)) U) was from the pre-fix overlap bug; using SMB sum (\(String(format: "%.2f", smbSum)) U) — back-calc CR will skew slightly high")
        }
        if isfIndeterminate {
            caveats.append("back-calc ISF is indeterminate — verified carbs (\(Int(verified.rounded()))g) were ≤ what \(String(format: "%.2f", insulin))U at CR \(String(format: "%.1f", cr)) already covered, so no rise budget remains for ISF to explain")
        }

        let footnote: String = {
            var parts = [
                "Back-calculated from verified carbs (\(Int(verified.rounded()))g) against observed peak rise (\(Int(rise.rounded())) mg/dL) + insulin delivered (\(String(format: "%.2f", insulin)) U). CR back-calc assumes current ISF (\(Int(isf)) mg/dL/U) is correct; ISF back-calc assumes current CR (\(String(format: "%.1f", cr)) g/U) is correct."
            ]
            if !caveats.isEmpty {
                parts.append("Caveats: " + caveats.joined(separator: "; ") + ".")
            }
            return parts.joined(separator: " ")
        }()

        return Result(
            verifiedCarbs: verified,
            assumedISF: isf,
            assumedCR: cr,
            backCalcCR: backCR,
            backCalcISF: backISF,
            deltaCRPercent: deltaCRPct,
            deltaISFPercent: deltaISFPct,
            confidence: confidence,
            footnote: footnote,
            isfIndeterminate: isfIndeterminate
        )
    }

    private static func smbSumFromJSON(_ inst: SavedMealInstance) -> Double {
        guard let json = inst.smbsJSON,
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([SMBJSONEntry].self, from: data)
        else { return 0 }
        return arr.reduce(0) { $0 + $1.units }
    }

    private struct SMBJSONEntry: Decodable {
        let t: Double
        let units: Double
    }

    // MARK: - Aggregate

    struct Aggregate {
        let instanceCount: Int
        let medianBackCalcCR: Double?
        let medianBackCalcISF: Double?
        let currentCR: Double?
        let currentISF: Double?
        let deltaCRPercent: Double?
        let deltaISFPercent: Double?
        let usedISFIndeterminateCount: Int
        let footnote: String
    }

    /// Median across an instance set. Only includes rows where the back-calc
    /// produced a value (`backCalcCR != nil` for CR median, etc.). ISF
    /// indeterminate rows automatically drop from the ISF median.
    static func aggregate(
        instances: [SavedMealInstance],
        fallback: (SavedMealInstance) -> CarbsEstimator.FallbackInputs = { _ in .empty }
    ) -> Aggregate {
        let results = instances.compactMap { inst -> Result? in
            calibrate(from: inst, fallback: fallback(inst))
        }
        let crValues = results.compactMap(\.backCalcCR).sorted()
        let isfValues = results.compactMap(\.backCalcISF).sorted()
        let medianCR = crValues.isEmpty ? nil : crValues[crValues.count / 2]
        let medianISF = isfValues.isEmpty ? nil : isfValues[isfValues.count / 2]
        let currentCR = results.first?.assumedCR
        let currentISF = results.first?.assumedISF
        let deltaCR: Double? = {
            guard let m = medianCR, let c = currentCR, c > 0 else { return nil }
            return (m - c) / c * 100
        }()
        let deltaISF: Double? = {
            guard let m = medianISF, let c = currentISF, c > 0 else { return nil }
            return (m - c) / c * 100
        }()
        let indeterminateCount = results.filter(\.isfIndeterminate).count
        var notes: [String] = []
        notes.append("\(results.count) verified instance\(results.count == 1 ? "" : "s").")
        if indeterminateCount > 0 {
            notes.append("\(indeterminateCount) excluded from ISF median (indeterminate).")
        }
        notes.append("Treat as one data point; needs ≥3 verified meals before considering a profile change.")
        return Aggregate(
            instanceCount: results.count,
            medianBackCalcCR: medianCR,
            medianBackCalcISF: medianISF,
            currentCR: currentCR,
            currentISF: currentISF,
            deltaCRPercent: deltaCR,
            deltaISFPercent: deltaISF,
            usedISFIndeterminateCount: indeterminateCount,
            footnote: notes.joined(separator: " ")
        )
    }
}

private extension CarbsEstimator.Confidence {
    /// Walks confidence down — never up. Mirrors the local `min` shim in
    /// SavedMealInstanceDetailView so callers don't have to remember the
    /// ordering trick.
    func downgraded(to floor: CarbsEstimator.Confidence) -> CarbsEstimator.Confidence {
        func rank(_ c: CarbsEstimator.Confidence) -> Int {
            switch c {
            case .high: return 3
            case .medium: return 2
            case .low: return 1
            case .none: return 0
            }
        }
        return rank(self) <= rank(floor) ? self : floor
    }
}
