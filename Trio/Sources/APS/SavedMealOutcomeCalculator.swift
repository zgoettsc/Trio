import CoreData
import Foundation

/// Reads the per-loop telemetry samples for a closed meal window, computes the
/// outcome metrics, and serializes the time-series fields (BG curve, SMBs,
/// floor activations, classifier upgrades) for inclusion on the
/// SavedMealInstance row.
///
/// Called from AlgorithmTelemetryManager.recordWindowClose when the closing
/// window is linked to a saved-meal instance.
///
/// See docs/MEAL_INTELLIGENCE_DESIGN.md §6 (outcome score), §8 (metrics).
struct SavedMealOutcomeCalculator {
    let viewContext: NSManagedObjectContext

    /// Sample point along the BG curve, minutes-from-activation + BG mg/dL.
    struct BGSample: Codable {
        let t: Double
        let bg: Double
    }

    struct SMBSample: Codable {
        let t: Double
        let units: Double
    }

    struct FloorSample: Codable {
        let t: Double
        let prior: Double?
        let floored: Double?
        let factor: Double?
    }

    struct ClassifierUpgradeSample: Codable {
        let t: Double
        let from: String
        let to: String
    }

    struct Computed {
        let metrics: SavedMealInstanceMetrics
        let score: Int
        let bgCurveJSON: String?
        let smbsJSON: String?
        let floorActivationsJSON: String?
        let classifierUpgradesJSON: String?
    }

    func compute(
        activatedAt: Date,
        closedAt: Date,
        baselineBG: Double?,
        classifierUpgrades: [ClassifierUpgradeSample]
    ) -> Computed {
        let glucose = fetchGlucose(from: activatedAt, to: closedAt)
        let bgCurve = glucose.map { sample in
            BGSample(
                t: sample.date.map { ($0.timeIntervalSince(activatedAt) / 60).rounded(.toNearestOrEven) } ?? 0,
                bg: Double(sample.glucose)
            )
        }

        let smbEvents = fetchSMBs(from: activatedAt, to: closedAt)
        let smbs = smbEvents.map { evt in
            SMBSample(
                t: evt.0.timeIntervalSince(activatedAt) / 60,
                units: evt.1
            )
        }

        // Metrics
        let bgs = bgCurve.map(\.bg)
        let peak = bgs.max() ?? 0
        // 5-min sample cadence assumed
        let minutesPerSample = 5
        var tir = 0
        var tar = 0
        var tbr = 0
        var lowsCount = 0
        var wasLow = false
        for bg in bgs {
            if bg >= 70 && bg <= 180 {
                tir += minutesPerSample
                wasLow = false
            } else if bg > 180 {
                tar += minutesPerSample
                wasLow = false
            } else { // < 70
                tbr += minutesPerSample
                if !wasLow {
                    lowsCount += 1
                    wasLow = true
                }
            }
        }

        // Time to baseline — minutes from peak back to within 20 of baseline.
        // Falls back to nil (0) if peak or baseline missing.
        var timeToBaseline = 0
        if let baseline = baselineBG, peak > 0,
           let peakIdx = bgs.firstIndex(of: peak)
        {
            for i in peakIdx..<bgs.count {
                if abs(bgs[i] - baseline) <= 20 {
                    timeToBaseline = i * minutesPerSample
                    break
                }
            }
        }

        let totalSMB = smbs.reduce(0) { $0 + $1.units }

        let metrics = SavedMealInstanceMetrics(
            peakBG: peak,
            timeInRangeMinutes: tir,
            timeAboveRangeMinutes: tar,
            timeBelowRangeMinutes: tbr,
            lowsCount: lowsCount,
            timeToBaselineMinutes: timeToBaseline,
            totalInsulinDeliveredU: totalSMB,
            smbCount: smbs.count,
            floorActivationCount: 0  // caller fills from telemetry's running tally
        )
        let score = computeScore(metrics: metrics)

        return Computed(
            metrics: metrics,
            score: score,
            bgCurveJSON: encode(bgCurve),
            smbsJSON: encode(smbs),
            floorActivationsJSON: nil,  // floor activation events not yet plumbed here; future enhancement
            classifierUpgradesJSON: encode(classifierUpgrades)
        )
    }

    // MARK: - Score (see MEAL_INTELLIGENCE_DESIGN.md §6)

    /// Auto-computed 0–100 score from BG-derived metrics.
    /// No user rating required.
    func computeScore(metrics: SavedMealInstanceMetrics) -> Int {
        var s: Double = 100

        // Penalty: BG > 180 — each mg over caps the score
        if metrics.peakBG > 180 {
            s -= (metrics.peakBG - 180) * 0.3
        }
        // Penalty: each low episode is -20
        if metrics.lowsCount > 0 {
            s -= Double(metrics.lowsCount) * 20
        }
        // Penalty: time-above-range over 30 min
        if metrics.timeAboveRangeMinutes > 30 {
            s -= Double(metrics.timeAboveRangeMinutes - 30) * 0.2
        }
        // Penalty: any minute below range is heavy
        if metrics.timeBelowRangeMinutes > 0 {
            s -= Double(metrics.timeBelowRangeMinutes)
        }
        // Bonus: returned to baseline within 4h
        if metrics.timeToBaselineMinutes > 0 && metrics.timeToBaselineMinutes < 240 {
            s += 5
        }

        return Int(max(0, min(100, s.rounded())))
    }

    // MARK: - Helpers

    private func fetchGlucose(from start: Date, to end: Date) -> [GlucoseStored] {
        var results: [GlucoseStored] = []
        viewContext.performAndWait {
            let req = GlucoseStored.fetchRequest()
            req.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            results = (try? viewContext.fetch(req)) ?? []
        }
        return results
    }

    /// Fetch SMB bolus events that happened during the window. Trio stores boluses
    /// as `BolusStored` with `isSMB: true` and a relationship to `PumpEventStored`
    /// for the timestamp.
    private func fetchSMBs(from start: Date, to end: Date) -> [(Date, Double)] {
        var results: [(Date, Double)] = []
        viewContext.performAndWait {
            let req = PumpEventStored.fetchRequest()
            req.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@ AND bolus != nil AND bolus.isSMB == YES",
                start as NSDate, end as NSDate
            )
            req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            let events = (try? viewContext.fetch(req)) ?? []
            for evt in events {
                if let ts = evt.timestamp, let bolus = evt.bolus, let amt = bolus.amount {
                    results.append((ts, Double(truncating: amt)))
                }
            }
        }
        return results
    }

    private func encode<T: Codable>(_ value: T) -> String? {
        do {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
