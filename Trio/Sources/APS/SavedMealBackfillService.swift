import CoreData
import Foundation
import Swinject

/// Phase E of MEAL_INTELLIGENCE_DESIGN.md — retroactively attach a past
/// eating event to a SavedMeal. Supports three anchor types:
///
/// 1. **Carb entry** — user logged carbs at a past time (most reliable anchor;
///    macros come from the entry).
/// 2. **Custom time** — user specifies "I ate at 7pm last night"; optional
///    macros.
/// 3. **Past activation event** — a `mealWindowActivated` event from earlier
///    (e.g., quick action without carb entry).
///
/// All three paths funnel through the same engine: compute window-end,
/// run the outcome calculator on the historical BG/SMB data, run the
/// 3-phase classifier algorithm retroactively, detect override / temp-target /
/// sensor-gap context, mark the instance backfilled.
struct SavedMealBackfillService {
    let resolver: Resolver
    let viewContext: NSManagedObjectContext
    let settingsManager: SettingsManager

    /// Maximum window length: 12 hours from anchor (or until next carb entry,
    /// whichever is sooner). Matches user's Indian-food spec decision.
    private let maxWindowMinutes: Double = 12 * 60

    /// Result of a preview operation — what would happen if user confirms.
    /// Returned by `preview(…)` so the UI can render before commit.
    struct Preview {
        let anchorTimestamp: Date
        let windowEnd: Date
        let windowEndReason: WindowEndReason
        let bgSampleCount: Int
        let macros: Macros?
        let suggestedMacrosFromNearbyEntry: SuggestedMacros?
        let overrideContext: OverrideContext
        let sensorGapMinutes: Int
        let classificationPath: ClassificationPath
        let outcomeMetrics: SavedMealInstanceMetrics
        let outcomeScore: Int

        struct Macros: Equatable {
            let carbs: Decimal?
            let fat: Decimal?
            let protein: Decimal?
        }

        struct SuggestedMacros {
            let entryDate: Date
            let macros: Macros
            let entryId: UUID
        }

        struct OverrideContext {
            let hadOverride: Bool
            let overrideMinutes: Int
            let overrideName: String?
            let suppressedSMB: Bool
            let hadTempTarget: Bool
            let tempTargetName: String?
        }

        struct ClassificationPath {
            let initial: MealClassification
            let final: MealClassification
            let upgrades: [SavedMealOutcomeCalculator.ClassifierUpgradeSample]
        }

        enum WindowEndReason: String {
            case maxDuration       // hit 12h
            case nextCarbEntry     // capped by a later carb entry
        }
    }

    enum AnchorType {
        case carbEntry(UUID)
        case customTime(Date, manualMacros: Preview.Macros?)
        case mealWindowActivation(windowId: String, at: Date)
    }

    // MARK: - Preview

    /// Build a preview for the given anchor without committing.
    /// Returns nil if the anchor data can't be resolved.
    func preview(anchor: AnchorType) -> Preview? {
        let anchorTimestamp: Date
        var macrosFromAnchor: Preview.Macros?

        switch anchor {
        case let .carbEntry(entryId):
            guard let entry = fetchCarbEntry(id: entryId), let ts = entry.date else { return nil }
            anchorTimestamp = ts
            macrosFromAnchor = Preview.Macros(
                carbs: entry.carbs > 0 ? Decimal(entry.carbs) : nil,
                fat: entry.fat > 0 ? Decimal(entry.fat) : nil,
                protein: entry.protein > 0 ? Decimal(entry.protein) : nil
            )
        case let .customTime(time, manual):
            anchorTimestamp = time
            macrosFromAnchor = manual
        case let .mealWindowActivation(_, at):
            anchorTimestamp = at
        }

        // Window end = anchor + 12h, or next carb entry, whichever sooner.
        let nextEntry = fetchNextCarbEntryAfter(date: anchorTimestamp, excluding: {
            if case let .carbEntry(id) = anchor { return id } else { return nil }
        }())
        let maxEnd = anchorTimestamp.addingTimeInterval(maxWindowMinutes * 60)
        let (windowEnd, reason): (Date, Preview.WindowEndReason) = {
            if let next = nextEntry?.date, next < maxEnd {
                return (next, .nextCarbEntry)
            }
            return (maxEnd, .maxDuration)
        }()

        // For custom-time anchors with no macros, look for a carb entry
        // within ±30 min to suggest as an auto-pick.
        var suggested: Preview.SuggestedMacros?
        if case .customTime = anchor, macrosFromAnchor == nil {
            if let nearby = fetchCarbEntryNear(date: anchorTimestamp, windowMinutes: 30),
               let nid = nearby.id, let ndate = nearby.date
            {
                suggested = Preview.SuggestedMacros(
                    entryDate: ndate,
                    macros: Preview.Macros(
                        carbs: nearby.carbs > 0 ? Decimal(nearby.carbs) : nil,
                        fat: nearby.fat > 0 ? Decimal(nearby.fat) : nil,
                        protein: nearby.protein > 0 ? Decimal(nearby.protein) : nil
                    ),
                    entryId: nid
                )
            }
        }

        // Outcome computation
        let calc = SavedMealOutcomeCalculator(viewContext: viewContext)
        let baseline = fetchBaselineBG(at: anchorTimestamp)
        // Retroactive classifier first — drives upgrades list AND baseline
        let classification = retroClassify(
            from: anchorTimestamp,
            to: windowEnd,
            baselineBG: baseline
        )
        let computed = calc.compute(
            activatedAt: anchorTimestamp,
            closedAt: windowEnd,
            baselineBG: baseline,
            classifierUpgrades: classification.upgrades
        )

        // Override / temp target / sensor-gap detection
        let overrideCtx = detectOverrideContext(from: anchorTimestamp, to: windowEnd)
        let gapMinutes = detectSensorGapMinutes(from: anchorTimestamp, to: windowEnd)

        let bgSamples = SavedMealAnalytics.parseBGCurve(computed.bgCurveJSON)
        return Preview(
            anchorTimestamp: anchorTimestamp,
            windowEnd: windowEnd,
            windowEndReason: reason,
            bgSampleCount: bgSamples.count,
            macros: macrosFromAnchor,
            suggestedMacrosFromNearbyEntry: suggested,
            overrideContext: overrideCtx,
            sensorGapMinutes: gapMinutes,
            classificationPath: classification,
            outcomeMetrics: computed.metrics,
            outcomeScore: computed.score
        )
    }

    // MARK: - Commit

    /// Commit a backfilled instance for the given meal + anchor.
    /// Uses the same calculation as preview() so the persisted values match
    /// what the user saw before confirming.
    /// Returns the created instance's UUID on success.
    @discardableResult
    func backfill(
        savedMealId: UUID,
        anchor: AnchorType,
        macrosOverride: Preview.Macros? = nil
    ) -> UUID? {
        guard let prev = preview(anchor: anchor) else { return nil }
        guard let storage = resolver.resolve(SavedMealStorage.self),
              let meal = storage.meal(id: savedMealId)
        else { return nil }

        let macros = macrosOverride ?? prev.macros
        let instanceId = UUID()
        let context = CoreDataStack.shared.newTaskContext()

        // Use a synthetic windowId for backfilled instances (we never had a
        // real Action Button activation to anchor to in some cases).
        let windowId = "backfill-\(instanceId.uuidString)"

        context.performAndWait {
            guard let mealInCtx = fetchSavedMeal(id: savedMealId, in: context) else { return }
            let inst = SavedMealInstance(context: context)
            inst.id = instanceId
            inst.windowId = windowId
            inst.startedAt = prev.anchorTimestamp
            inst.closedAt = prev.windowEnd
            inst.carbsAtActivation = macros?.carbs.map(NSDecimalNumber.init(decimal:))
            inst.fatAtActivation = macros?.fat.map(NSDecimalNumber.init(decimal:))
            inst.proteinAtActivation = macros?.protein.map(NSDecimalNumber.init(decimal:))
            inst.carbBucketSource = {
                if macrosOverride != nil { return "manual" }
                if let m = prev.macros, m.carbs != nil { return "macros" }
                return "inferred"
            }()
            inst.initialClassification = prev.classificationPath.initial.rawValue
            inst.finalClassification = prev.classificationPath.final.rawValue
            inst.bgCurveJSON = encodeUpgrades(curve: nil, calc: prev)
            inst.classifierUpgradesJSON = encodeUpgrades(curve: prev.classificationPath.upgrades)
            inst.outcomeScore = Int32(prev.outcomeScore)
            inst.peakBG = prev.outcomeMetrics.peakBG
            inst.timeInRangeMinutes = Int32(prev.outcomeMetrics.timeInRangeMinutes)
            inst.timeAboveRangeMinutes = Int32(prev.outcomeMetrics.timeAboveRangeMinutes)
            inst.timeBelowRangeMinutes = Int32(prev.outcomeMetrics.timeBelowRangeMinutes)
            inst.lowsCount = Int32(prev.outcomeMetrics.lowsCount)
            inst.timeToBaselineMinutes = Int32(prev.outcomeMetrics.timeToBaselineMinutes)
            inst.totalInsulinDeliveredU = prev.outcomeMetrics.totalInsulinDeliveredU
            inst.smbCount = Int32(prev.outcomeMetrics.smbCount)
            inst.floorActivationCount = Int32(prev.outcomeMetrics.floorActivationCount)
            inst.backfilled = true
            inst.windowHadOverride = prev.overrideContext.hadOverride
            inst.overrideMinutesDuringWindow = Int32(prev.overrideContext.overrideMinutes)
            inst.overrideSuppressedSMB = prev.overrideContext.suppressedSMB
            inst.windowHadTempTarget = prev.overrideContext.hadTempTarget
            inst.sensorGapMinutes = Int32(prev.sensorGapMinutes)
            mealInCtx.addToInstances(inst)
            // Refresh cached counts (mirror BaseSavedMealStorage.closeInstance behavior).
            let all = (mealInCtx.instances?.allObjects as? [SavedMealInstance]) ?? []
            let closed = all.filter { $0.closedAt != nil }
            mealInCtx.cachedInstanceCount = Int32(closed.count)
            mealInCtx.updatedAt = Date()
            try? context.save()
        }
        // Push this row to telemetry (meals.jsonl + per-meal history) and
        // refresh the definitions snapshot so cachedInstanceCount updates.
        resolver.resolve(AlgorithmTelemetryManager.self)?.emitBackfilledInstance(instanceId: instanceId)
        return instanceId
    }

    // MARK: - Retroactive 3-phase classifier

    /// Apply the same 3-phase rule used by the live classifier to a sequence
    /// of historical BG samples between anchor and windowEnd. Returns the
    /// final classification + the upgrade history that WOULD have fired.
    func retroClassify(
        from start: Date,
        to end: Date,
        baselineBG: Double?
    ) -> Preview.ClassificationPath {
        let settings = settingsManager.settings
        let bgs = fetchBGSamples(from: start, to: end)
        guard !bgs.isEmpty else {
            return Preview.ClassificationPath(initial: .simple, final: .simple, upgrades: [])
        }

        let activationBG = baselineBG ?? Double(bgs.first?.glucose ?? 0)
        let phase1DeltaThresh = settings.mealClassifierPhase1DeltaThreshold.doubleValue
        let phase1Sustained = Int(truncating: settings.mealClassifierPhase1SustainedReadings as NSNumber)
        let phase1AbsRise = settings.mealClassifierPhase1AbsoluteRiseMgdL.doubleValue
        let phase2Range = settings.mealClassifierPhase2RangeMgdL.doubleValue
        let phase2MinMin = settings.mealClassifierPhase2MinDurationMinutes.doubleValue
        let phase3DeltaThresh = settings.mealClassifierPhase3DeltaThreshold.doubleValue
        let phase3SustainedMin = settings.mealClassifierPhase3SustainedDurationMinutes.doubleValue

        var current: MealClassification = .simple
        var phase1At: Date?
        var phase1Trough: Double = activationBG
        var phase2At: Date?
        var upgrades: [SavedMealOutcomeCalculator.ClassifierUpgradeSample] = []

        // Convert BG samples to (date, bg) for cleaner iteration
        let samples = bgs.compactMap { s -> (Date, Double)? in
            guard let d = s.date else { return nil }
            return (d, Double(s.glucose))
        }

        for i in samples.indices {
            let (now, bg) = samples[i]

            // Phase 1: large rise from activation
            if phase1At == nil, now.timeIntervalSince(start) / 60 <= 90 {
                let rise = bg - activationBG
                if rise >= phase1AbsRise {
                    phase1At = now
                    if current.rank < MealClassification.medium.rank {
                        current = .medium
                    }
                } else if i >= phase1Sustained {
                    let recent = samples[max(0, i - phase1Sustained) ... i]
                    let deltas = zip(recent.dropLast(), recent.dropFirst()).map { $1.1 - $0.1 }
                    if deltas.allSatisfy({ $0 >= phase1DeltaThresh }) {
                        phase1At = now
                        if current.rank < MealClassification.medium.rank {
                            current = .medium
                        }
                    }
                }
            }

            // Track trough after Phase 1 confirmed (for Phase 2 baseline).
            if phase1At != nil, phase2At == nil, bg < phase1Trough {
                phase1Trough = bg
            }

            // Phase 2: stable within range of baseline for N minutes
            if phase1At != nil, phase2At == nil {
                let baseline = min(activationBG, phase1Trough)
                let cutoff = now.addingTimeInterval(-phase2MinMin * 60)
                let inWindow = samples.filter { $0.0 >= cutoff && $0.0 <= now }
                if !inWindow.isEmpty,
                   let earliest = inWindow.first?.0,
                   now.timeIntervalSince(earliest) >= phase2MinMin * 60 - 30,
                   inWindow.allSatisfy({ abs($0.1 - baseline) <= phase2Range })
                {
                    phase2At = now
                }
            }

            // Phase 3: late re-rise → upgrade to Complex
            if phase2At != nil, current.rank < MealClassification.complex.rank {
                let cutoff = now.addingTimeInterval(-phase3SustainedMin * 60)
                let tail = samples.filter { $0.0 >= cutoff && $0.0 <= now }
                guard tail.count >= 2,
                      let earliest = tail.first?.0,
                      now.timeIntervalSince(earliest) >= phase3SustainedMin * 60 - 30
                else { continue }
                let deltas = zip(tail.dropLast(), tail.dropFirst()).map { $1.1 - $0.1 }
                if deltas.allSatisfy({ $0 >= phase3DeltaThresh }) {
                    upgrades.append(SavedMealOutcomeCalculator.ClassifierUpgradeSample(
                        t: now.timeIntervalSince(start) / 60,
                        from: current.rawValue,
                        to: MealClassification.complex.rawValue
                    ))
                    current = .complex
                }
            }
        }

        return Preview.ClassificationPath(
            initial: phase1At == nil ? .simple : .medium,
            final: current,
            upgrades: upgrades
        )
    }

    // MARK: - Helpers (override / sensor / lookups)

    private func detectOverrideContext(from start: Date, to end: Date) -> Preview.OverrideContext {
        var hadOverride = false
        var hadTempTarget = false
        var suppressedSMB = false
        var minutes = 0
        var overrideName: String?
        var tempTargetName: String?

        viewContext.performAndWait {
            // Override: any OverrideStored with overlap of (start, end) and enabled
            let oReq = OverrideStored.fetchRequest()
            oReq.predicate = NSPredicate(format: "date <= %@", end as NSDate)
            let overrides = (try? viewContext.fetch(oReq)) ?? []
            for o in overrides {
                guard let oStart = o.date, let durDec = o.duration else { continue }
                let dur = Double(truncating: durDec)
                let oEnd = oStart.addingTimeInterval(dur * 60)
                if oStart < end && oEnd > start && o.enabled {
                    hadOverride = true
                    overrideName = o.name ?? overrideName
                    let overlap = min(oEnd, end).timeIntervalSince(max(oStart, start))
                    minutes += Int(overlap / 60)
                    if o.smbIsOff { suppressedSMB = true }
                }
            }

            let tReq = TempTargetStored.fetchRequest()
            tReq.predicate = NSPredicate(format: "date <= %@", end as NSDate)
            let tts = (try? viewContext.fetch(tReq)) ?? []
            for t in tts {
                guard let tStart = t.date, let durDec = t.duration else { continue }
                let dur = Double(truncating: durDec)
                let tEnd = tStart.addingTimeInterval(dur * 60)
                if tStart < end && tEnd > start && t.enabled {
                    hadTempTarget = true
                    tempTargetName = t.name ?? tempTargetName
                }
            }
        }
        return Preview.OverrideContext(
            hadOverride: hadOverride,
            overrideMinutes: minutes,
            overrideName: overrideName,
            suppressedSMB: suppressedSMB,
            hadTempTarget: hadTempTarget,
            tempTargetName: tempTargetName
        )
    }

    /// Sums minutes of sensor gap (>15 min between BG samples) inside the window.
    private func detectSensorGapMinutes(from start: Date, to end: Date) -> Int {
        let samples = fetchBGSamples(from: start, to: end)
        guard samples.count >= 2 else {
            return Int(end.timeIntervalSince(start) / 60)
        }
        var gap = 0
        for i in 1 ..< samples.count {
            guard let prev = samples[i - 1].date, let cur = samples[i].date else { continue }
            let diff = cur.timeIntervalSince(prev) / 60
            if diff > 15 { gap += Int(diff - 5) }  // 5-min cadence is normal; surplus is the gap
        }
        return gap
    }

    /// Best-effort baseline BG just before anchor (median of last 3 readings).
    private func fetchBaselineBG(at anchor: Date) -> Double? {
        let cutoff = anchor.addingTimeInterval(-30 * 60)
        var samples: [GlucoseStored] = []
        viewContext.performAndWait {
            let req = GlucoseStored.fetchRequest()
            req.predicate = NSPredicate(format: "date >= %@ AND date <= %@", cutoff as NSDate, anchor as NSDate)
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            req.fetchLimit = 3
            samples = (try? viewContext.fetch(req)) ?? []
        }
        guard !samples.isEmpty else { return nil }
        let vals = samples.map { Double($0.glucose) }.sorted()
        return vals[vals.count / 2]
    }

    // MARK: - CoreData lookups

    /// Scans the local telemetry events.jsonl files for `mealWindowActivated`
    /// rows from the last `hours` that don't already have a SavedMealInstance
    /// attached. Lets the backfill picker offer "past Action Button taps that
    /// you never logged carbs for" as a 3rd attachment source.
    func fetchAttachableActivations(within hours: Int) -> [(windowId: String, at: Date)] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("telemetry", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var results: [(String, Date)] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Walk recent date folders. Local-date partitioning means at most 2-3
        // folders need to be touched for a 48h lookback.
        let monthDirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for monthDir in monthDirs where monthDir != "meals" {
            let monthURL = root.appendingPathComponent(monthDir)
            let dayDirs = (try? FileManager.default.contentsOfDirectory(atPath: monthURL.path)) ?? []
            for dayDir in dayDirs {
                let eventsURL = monthURL.appendingPathComponent(dayDir).appendingPathComponent("events.jsonl")
                guard let data = try? String(contentsOf: eventsURL, encoding: .utf8) else { continue }
                for line in data.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          (obj["kind"] as? String) == "mealWindowActivated",
                          let windowId = obj["windowId"] as? String,
                          let tsString = obj["timestamp"] as? String,
                          let ts = formatter.date(from: tsString),
                          ts >= cutoff
                    else { continue }
                    results.append((windowId, ts))
                }
            }
        }

        // Filter out any windowIds already attached to a SavedMealInstance.
        let existingWindowIds = fetchExistingWindowIds()
        let unattached = results.filter { !existingWindowIds.contains($0.0) }
        // Sort newest first, dedupe by windowId.
        var seen = Set<String>()
        return unattached
            .sorted { $0.1 > $1.1 }
            .filter { seen.insert($0.0).inserted }
    }

    private func fetchExistingWindowIds() -> Set<String> {
        var ids = Set<String>()
        viewContext.performAndWait {
            let req = SavedMealInstance.fetchRequest()
            let all = (try? viewContext.fetch(req)) ?? []
            ids = Set(all.compactMap { $0.windowId })
        }
        return ids
    }

    func fetchAttachableCarbEntries(within hours: Int) -> [CarbEntryStored] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        var results: [CarbEntryStored] = []
        viewContext.performAndWait {
            let req = CarbEntryStored.fetchRequest()
            req.predicate = NSPredicate(
                format: "date >= %@ AND (carbs > 0 OR fat > 0 OR protein > 0) AND isFPU == NO",
                cutoff as NSDate
            )
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            results = (try? viewContext.fetch(req)) ?? []
        }
        return results
    }

    private func fetchCarbEntry(id: UUID) -> CarbEntryStored? {
        var result: CarbEntryStored?
        viewContext.performAndWait {
            let req = CarbEntryStored.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            result = (try? viewContext.fetch(req))?.first
        }
        return result
    }

    private func fetchCarbEntryNear(date: Date, windowMinutes: Double) -> CarbEntryStored? {
        let start = date.addingTimeInterval(-windowMinutes * 60)
        let end = date.addingTimeInterval(windowMinutes * 60)
        var result: CarbEntryStored?
        viewContext.performAndWait {
            let req = CarbEntryStored.fetchRequest()
            req.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@ AND (carbs > 0 OR fat > 0 OR protein > 0) AND isFPU == NO",
                start as NSDate, end as NSDate
            )
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            req.fetchLimit = 1
            result = (try? viewContext.fetch(req))?.first
        }
        return result
    }

    private func fetchNextCarbEntryAfter(date: Date, excluding excludedId: UUID?) -> CarbEntryStored? {
        var result: CarbEntryStored?
        viewContext.performAndWait {
            let req = CarbEntryStored.fetchRequest()
            var preds: [NSPredicate] = [
                NSPredicate(format: "date > %@", date as NSDate),
                NSPredicate(format: "carbs > 0"),
                NSPredicate(format: "isFPU == NO")
            ]
            if let excl = excludedId {
                preds.append(NSPredicate(format: "id != %@", excl as CVarArg))
            }
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            req.fetchLimit = 1
            result = (try? viewContext.fetch(req))?.first
        }
        return result
    }

    private func fetchBGSamples(from start: Date, to end: Date) -> [GlucoseStored] {
        var results: [GlucoseStored] = []
        viewContext.performAndWait {
            let req = GlucoseStored.fetchRequest()
            req.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            results = (try? viewContext.fetch(req)) ?? []
        }
        return results
    }

    private func fetchSavedMeal(id: UUID, in context: NSManagedObjectContext) -> SavedMeal? {
        let req = SavedMeal.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    private func encodeUpgrades(curve: [SavedMealOutcomeCalculator.ClassifierUpgradeSample]) -> String? {
        guard let data = try? JSONEncoder().encode(curve) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeUpgrades(curve: String?, calc: Preview) -> String? {
        // Pass-through helper: the BG curve JSON came out of SavedMealOutcomeCalculator
        // already. We re-use that path so the persisted format matches live-tracked rows.
        let computed = SavedMealOutcomeCalculator(viewContext: viewContext).compute(
            activatedAt: calc.anchorTimestamp,
            closedAt: calc.windowEnd,
            baselineBG: nil,
            classifierUpgrades: []
        )
        return computed.bgCurveJSON
    }
}

private extension Decimal {
    var doubleValue: Double { Double(truncating: self as NSDecimalNumber) }
}
