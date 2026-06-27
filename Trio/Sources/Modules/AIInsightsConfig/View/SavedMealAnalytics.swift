import Charts
import Foundation
import SwiftUI

/// Pure-functional analytics over a set of SavedMealInstance rows.
/// Used by SavedMealDetailView to render composite curves, key timings,
/// checkpoint tables, and outcome aggregates.
///
/// See docs/MEAL_INTELLIGENCE_DESIGN.md §3 (data model), §6 (outcome score),
/// §9 (size stratification).
enum SavedMealAnalytics {
    struct AggregatedCurve {
        /// minutes-from-activation values shared across instances (5-min cadence)
        let timeBuckets: [Double]
        /// median BG at each time bucket
        let median: [Double]
        /// 25th percentile band
        let p25: [Double]
        /// 75th percentile band
        let p75: [Double]
        /// raw curves for overlay
        let perInstance: [[CurvePoint]]
    }

    struct CurvePoint: Identifiable {
        var id: String { "\(seriesId)-\(t)" }
        let seriesId: String
        let t: Double  // minutes since activation
        let bg: Double
    }

    struct KeyTimings {
        let initialPeak: (t: Double, bg: Double)?
        let trough: (t: Double, bg: Double)?
        let latePeak: (t: Double, bg: Double)?
        let returnToBaseline: Double?  // minutes
    }

    struct CheckpointStat {
        let label: String
        let median: Double
        let range: (Double, Double)
    }

    struct InsulinBurden {
        let medianTotalU: Double
        let medianSMBCount: Int
        let medianFloorCount: Int
    }

    struct OutcomeAggregate {
        let medianScore: Int
        let medianTIRPercent: Int
        let medianPeak: Double
        let medianLowsCount: Int
        let medianWindowDurationMinutes: Int
    }

    struct ClassificationStats {
        let total: Int
        let upgradedMidWindow: Int
        let medianUpgradeMinutes: Double?
        let recommendedClassification: String?
    }

    /// Parses a SavedMealInstance's bgCurveJSON into typed sample points.
    static func parseBGCurve(_ json: String?) -> [SavedMealOutcomeCalculator.BGSample] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SavedMealOutcomeCalculator.BGSample].self, from: data)) ?? []
    }

    static func parseUpgrades(_ json: String?) -> [SavedMealOutcomeCalculator.ClassifierUpgradeSample] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SavedMealOutcomeCalculator.ClassifierUpgradeSample].self, from: data)) ?? []
    }

    /// Aggregate the BG curves of multiple instances into median + IQR bands.
    /// Buckets to 5-min resolution. Skips instances with no BG curve data.
    static func aggregate(instances: [SavedMealInstance]) -> AggregatedCurve {
        let bucketStep = 5.0
        let maxMinutes = 600.0
        var perInstance: [[CurvePoint]] = []
        var bucketed: [Double: [Double]] = [:]

        for inst in instances {
            let id = inst.id?.uuidString ?? UUID().uuidString
            let samples = parseBGCurve(inst.bgCurveJSON)
            guard !samples.isEmpty else { continue }
            var pts: [CurvePoint] = []
            for s in samples where s.t <= maxMinutes {
                let bucket = (s.t / bucketStep).rounded() * bucketStep
                bucketed[bucket, default: []].append(s.bg)
                pts.append(CurvePoint(seriesId: id, t: bucket, bg: s.bg))
            }
            perInstance.append(pts)
        }

        let buckets = bucketed.keys.sorted()
        var median: [Double] = []
        var p25: [Double] = []
        var p75: [Double] = []
        for b in buckets {
            let vals = bucketed[b]!.sorted()
            median.append(percentile(0.50, sortedValues: vals))
            p25.append(percentile(0.25, sortedValues: vals))
            p75.append(percentile(0.75, sortedValues: vals))
        }

        return AggregatedCurve(
            timeBuckets: buckets,
            median: median, p25: p25, p75: p75,
            perInstance: perInstance
        )
    }

    /// Derive key timings (initial peak, trough, late peak, return-to-baseline)
    /// from the aggregated median curve.
    static func keyTimings(from agg: AggregatedCurve, baselineBG: Double?) -> KeyTimings {
        guard !agg.median.isEmpty else {
            return KeyTimings(initialPeak: nil, trough: nil, latePeak: nil, returnToBaseline: nil)
        }
        let times = agg.timeBuckets
        let bgs = agg.median

        // Initial peak: max BG in first 120 min
        var initialPeak: (Double, Double)?
        if let (idx, val) = enumerateMax(values: bgs, times: times, where: { $0 <= 120 }) {
            initialPeak = (times[idx], val)
        }
        // Trough: min BG between initialPeak time and 3h
        var trough: (Double, Double)?
        if let initial = initialPeak,
           let (idx, val) = enumerateMin(
               values: bgs, times: times,
               where: { $0 > initial.0 && $0 <= 180 }
           )
        {
            trough = (times[idx], val)
        }
        // Late peak: max BG after trough time (or 2h if no trough)
        let lateAfter = trough?.0 ?? 120
        var latePeak: (Double, Double)?
        if let (idx, val) = enumerateMax(values: bgs, times: times, where: { $0 > lateAfter }),
           val > (initialPeak?.1 ?? 0) * 0.85  // late peak must be substantial
        {
            latePeak = (times[idx], val)
        }
        // Return to baseline: first time after the latest peak when BG is within 20 of baseline
        var returnTime: Double?
        if let baseline = baselineBG ?? trough?.1 {
            let latestPeakTime = latePeak?.0 ?? initialPeak?.0 ?? 0
            for (i, t) in times.enumerated() {
                if t > latestPeakTime && abs(bgs[i] - baseline) <= 20 {
                    returnTime = t
                    break
                }
            }
        }
        return KeyTimings(initialPeak: initialPeak, trough: trough, latePeak: latePeak, returnToBaseline: returnTime)
    }

    /// Median + range at fixed checkpoints (1h, 3h, 6h, 8h, 10h).
    static func checkpoints(instances: [SavedMealInstance]) -> [CheckpointStat] {
        let labels: [(String, Double)] = [
            ("+1h", 60), ("+3h", 180), ("+6h", 360), ("+8h", 480), ("+10h", 600)
        ]
        var stats: [CheckpointStat] = []
        for (label, t) in labels {
            var vals: [Double] = []
            for inst in instances {
                let samples = parseBGCurve(inst.bgCurveJSON)
                if let nearest = samples.min(by: { abs($0.t - t) < abs($1.t - t) }),
                   abs(nearest.t - t) <= 10 // within ±10 min
                {
                    vals.append(nearest.bg)
                }
            }
            if !vals.isEmpty {
                let sorted = vals.sorted()
                stats.append(CheckpointStat(
                    label: label,
                    median: percentile(0.5, sortedValues: sorted),
                    range: (sorted.first!, sorted.last!)
                ))
            }
        }
        return stats
    }

    static func insulinBurden(instances: [SavedMealInstance]) -> InsulinBurden {
        let totals = instances.map { $0.totalInsulinDeliveredU }.sorted()
        let smbs = instances.map { Int($0.smbCount) }.sorted()
        let floors = instances.map { Int($0.floorActivationCount) }.sorted()
        return InsulinBurden(
            medianTotalU: percentile(0.5, sortedValues: totals),
            medianSMBCount: Int(percentile(0.5, sortedValues: smbs.map(Double.init))),
            medianFloorCount: Int(percentile(0.5, sortedValues: floors.map(Double.init)))
        )
    }

    static func outcome(instances: [SavedMealInstance]) -> OutcomeAggregate {
        let scores = instances.map { Int($0.outcomeScore) }
        let tir = instances.compactMap { inst -> Int? in
            let total = inst.timeInRangeMinutes + inst.timeAboveRangeMinutes + inst.timeBelowRangeMinutes
            guard total > 0 else { return nil }
            return Int(Double(inst.timeInRangeMinutes) / Double(total) * 100)
        }
        let peaks = instances.map { $0.peakBG }
        let lows = instances.map { Int($0.lowsCount) }
        let durations = instances.compactMap { inst -> Int? in
            guard let started = inst.startedAt, let closed = inst.closedAt else { return nil }
            return Int(closed.timeIntervalSince(started) / 60)
        }
        return OutcomeAggregate(
            medianScore: Int(percentile(0.5, sortedValues: scores.map(Double.init).sorted())),
            medianTIRPercent: Int(percentile(0.5, sortedValues: tir.map(Double.init).sorted())),
            medianPeak: percentile(0.5, sortedValues: peaks.sorted()),
            medianLowsCount: Int(percentile(0.5, sortedValues: lows.map(Double.init).sorted())),
            medianWindowDurationMinutes: Int(percentile(0.5, sortedValues: durations.map(Double.init).sorted()))
        )
    }

    static func classificationStats(instances: [SavedMealInstance]) -> ClassificationStats {
        var upgraded = 0
        var upgradeMinutes: [Double] = []
        var classCounts: [String: Int] = [:]
        for inst in instances {
            if let cls = inst.finalClassification {
                classCounts[cls, default: 0] += 1
            }
            let upgrades = parseUpgrades(inst.classifierUpgradesJSON)
            if let firstUpgrade = upgrades.first {
                upgraded += 1
                upgradeMinutes.append(firstUpgrade.t)
            }
        }
        let recommended = classCounts.max(by: { $0.value < $1.value })?.key
        return ClassificationStats(
            total: instances.count,
            upgradedMidWindow: upgraded,
            medianUpgradeMinutes: upgradeMinutes.isEmpty ? nil
                : percentile(0.5, sortedValues: upgradeMinutes.sorted()),
            recommendedClassification: recommended
        )
    }

    // MARK: - Stratification

    /// Returns instances filtered by carb bucket, plus the carb total ranges
    /// for each bucket (Small/Medium/Large per spec §9).
    static func stratify(
        instances: [SavedMealInstance],
        bucket: SavedMealInstance.CarbBucket?
    ) -> [SavedMealInstance] {
        guard let bucket else { return instances }
        return instances.filter { $0.carbBucket == bucket }
    }

    // MARK: - Internals

    /// `sortedValues` MUST be sorted ascending. Returns 0 for empty input.
    static func percentile(_ p: Double, sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        if sortedValues.count == 1 { return sortedValues[0] }
        let rank = p * Double(sortedValues.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sortedValues[lower] }
        let weight = rank - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private static func enumerateMax(
        values: [Double], times: [Double],
        where include: (Double) -> Bool
    ) -> (Int, Double)? {
        var best: (Int, Double)?
        for i in values.indices where include(times[i]) {
            if best == nil || values[i] > best!.1 {
                best = (i, values[i])
            }
        }
        return best
    }

    private static func enumerateMin(
        values: [Double], times: [Double],
        where include: (Double) -> Bool
    ) -> (Int, Double)? {
        var best: (Int, Double)?
        for i in values.indices where include(times[i]) {
            if best == nil || values[i] < best!.1 {
                best = (i, values[i])
            }
        }
        return best
    }
}
