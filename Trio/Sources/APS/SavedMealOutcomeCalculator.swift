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

        // Insulin "above baseline" = SMBs + integral of POSITIVE (temp -
        // scheduled) delta over the window. Captures the loop's positive
        // contribution to the meal. We deliberately ignore basal
        // suppression (temp < scheduled) because that's a separate loop
        // behavior — reacting to a falling-BG-risk prediction, not
        // "negative meal coverage." Including it would mean a well-bolused
        // meal that briefly crashed BG would have a negative metric, which
        // is meaningless. Result is always ≥ 0 for any real meal.
        let smbContribution = smbs.reduce(0) { $0 + $1.units }
        let tempBasalContribution = integrateTempBasalDelta(from: activatedAt, to: closedAt)
        let insulinAboveBaseline = smbContribution + tempBasalContribution

        let metrics = SavedMealInstanceMetrics(
            peakBG: peak,
            timeInRangeMinutes: tir,
            timeAboveRangeMinutes: tar,
            timeBelowRangeMinutes: tbr,
            lowsCount: lowsCount,
            timeToBaselineMinutes: timeToBaseline,
            totalInsulinDeliveredU: insulinAboveBaseline,
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

    // MARK: - Temp basal delta integral

    /// Sums the (actual rate - scheduled rate) × duration over the window
    /// for all temp basals that overlapped it. Result is in units of insulin.
    /// Positive when the loop ran above baseline (high temps), negative when
    /// below (low temps / zero temps that suppressed scheduled basal).
    ///
    /// Combined with SMBs, this gives "insulin above what the user would have
    /// gotten from the plain basal profile" — a much truer "meal cost" than
    /// SMB-only counting.
    private func integrateTempBasalDelta(from start: Date, to end: Date) -> Double {
        let basalProfile = loadBasalProfile()
        let tempBasals = fetchTempBasals(from: start, to: end)
        guard !basalProfile.isEmpty else { return 0 }

        // CRITICAL — Trio writes a NEW temp basal on every loop pass
        // (every 5 min), each with a 30-min nominal duration. Each new
        // temp implicitly CANCELS the prior one on the pump. The naive
        // "integrate each over its full duration" approach double-counts
        // by ~6× because every clock-minute is covered by multiple
        // overlapping records. Clip each temp basal's effective end to
        // the start of the next one. The last one runs to its nominal
        // end or the window end, whichever is sooner.
        let sorted = tempBasals
            .compactMap { tb -> (start: Date, rate: NSDecimalNumber, nominalEnd: Date)? in
                guard let s = tb.start, let r = tb.rate else { return nil }
                return (s, r, s.addingTimeInterval(Double(tb.duration) * 60))
            }
            .sorted { $0.start < $1.start }

        var total: Double = 0
        for i in 0 ..< sorted.count {
            let tb = sorted[i]
            // Effective end = min(nominal end, next temp's start). Beyond
            // the last entry there's no next-start; nominal end stands.
            let nextStart: Date = (i + 1) < sorted.count ? sorted[i + 1].start : .distantFuture
            let effectiveEnd = min(tb.nominalEnd, nextStart)
            let sliceStart = max(tb.start, start)
            let sliceEnd = min(effectiveEnd, end)
            guard sliceEnd > sliceStart else { continue }
            let stepSeconds: TimeInterval = 5 * 60
            var cursor = sliceStart
            while cursor < sliceEnd {
                let stepEnd = min(cursor.addingTimeInterval(stepSeconds), sliceEnd)
                let durationHours = stepEnd.timeIntervalSince(cursor) / 3600
                let scheduledRate = scheduledBasalRate(at: cursor, profile: basalProfile)
                let actualRate = Double(truncating: tb.rate)
                // Only POSITIVE deltas count toward meal coverage. A loop
                // suspension below scheduled basal is a falling-BG-risk
                // reaction, not negative meal dosing — counting it here
                // would let a meal with a brief BG crash come out with a
                // negative "insulin above baseline" metric, which is
                // meaningless. See the F-21 follow-up in FINDINGS.md.
                let delta = actualRate - scheduledRate
                if delta > 0 {
                    total += delta * durationHours
                }
                cursor = stepEnd
            }
        }
        return total
    }

    /// Looks up the scheduled basal rate U/h at a given wall-clock moment
    /// using the day's basal schedule.
    private func scheduledBasalRate(at date: Date, profile: [BasalProfileEntry]) -> Double {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minutesIntoDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        // Profile entries are sorted by `minutes`; find the latest one at or
        // before this minute.
        var best: BasalProfileEntry?
        for entry in profile {
            if entry.minutes <= minutesIntoDay {
                best = entry
            } else {
                break
            }
        }
        guard let chosen = best ?? profile.first else { return 0 }
        return Double(truncating: chosen.rate as NSNumber)
    }

    private func loadBasalProfile() -> [BasalProfileEntry] {
        // FileStorage path: `OpenAPS.Settings.basalProfile` is the persisted
        // JSON the loop uses. Read synchronously via the standard file path.
        // Falls back to an empty array if missing (delta then collapses to 0).
        let path = OpenAPS.Settings.basalProfile
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BasalProfileEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.minutes < $1.minutes }
    }

    /// All temp basal events that overlapped the window.
    private func fetchTempBasals(from start: Date, to end: Date) -> [(start: Date?, rate: NSDecimalNumber?, duration: Int16)] {
        var results: [(Date?, NSDecimalNumber?, Int16)] = []
        viewContext.performAndWait {
            let req = PumpEventStored.fetchRequest()
            // Pull anything overlapping; we'll filter precisely below.
            let earliestPossibleStart = start.addingTimeInterval(-24 * 3600)
            req.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@ AND tempBasal != nil",
                earliestPossibleStart as NSDate, end as NSDate
            )
            req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            let events = (try? viewContext.fetch(req)) ?? []
            for e in events {
                guard let tb = e.tempBasal else { continue }
                let evStart = e.timestamp
                let durMin = tb.duration
                if let evStart {
                    let evEnd = evStart.addingTimeInterval(Double(durMin) * 60)
                    if evStart < end && evEnd > start {
                        results.append((evStart, tb.rate, durMin))
                    }
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
