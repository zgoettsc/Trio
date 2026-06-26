import CoreData
import Foundation

/// Computes post-prandial outcomes (peak BG, time-above-180, insulin totals, etc.)
/// for closed meal windows after the +6h tail has elapsed.
///
/// Flow:
/// 1. When a window closes, the manager calls `recordPendingOutcome` which appends
///    the window's metadata to `pending_outcomes.json` (a small JSON array file in
///    the telemetry directory).
/// 2. On app foreground (or any other trigger), `processReadyOutcomes` runs through
///    pending entries, finds any whose `closedAt + 6h` is in the past, queries
///    CoreData for BG samples + bolus events in [activatedAt, closedAt+6h], computes
///    outcome metrics, writes a completed `AlgorithmTelemetryWindowSummary` row,
///    and removes the entry from pending.
///
/// Note: the close-time summary written immediately at window close (in the manager)
/// carries the same windowId. Analysis can join the two rows by windowId to get the
/// outcome-enriched version. Or just look at the second row, which has everything.
final class AlgorithmTelemetryOutcomes {
    struct Pending: Codable {
        let windowId: String
        let activatedAt: Date
        let closedAt: Date
        let closeReason: String
        let estimatedCarbs: Double?
        let carbsConfirmed: Bool
    }

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "AlgorithmTelemetryOutcomes.queue", qos: .utility)

    private var pendingFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("pending_outcomes.json")
    }

    func enqueue(_ entry: Pending) {
        queue.sync {
            var list = readPending()
            // Replace any existing entry with the same windowId (idempotent).
            list.removeAll { $0.windowId == entry.windowId }
            list.append(entry)
            writePending(list)
        }
    }

    /// Find any entries whose closedAt + 6h has elapsed. Returns them and removes them
    /// from the pending list. Caller is responsible for actually computing + writing
    /// the summary (this class doesn't know about the logger).
    func dequeueReady(now: Date = Date(), tailHours: Double = 6) -> [Pending] {
        queue.sync {
            var list = readPending()
            let cutoff = now.addingTimeInterval(-tailHours * 3600)
            let ready = list.filter { $0.closedAt <= cutoff }
            list.removeAll { entry in ready.contains { $0.windowId == entry.windowId } }
            writePending(list)
            return ready
        }
    }

    /// Compute the outcome rollup for a pending entry from CoreData. Returns nil if
    /// the required data can't be loaded. Runs on the passed context's queue.
    func computeOutcome(
        for pending: Pending,
        bgAtActivation: Double?,
        iobAtActivation: Double?,
        cobAtActivation: Double?,
        floorActivationCount: Int,
        currentMaxIOB: Decimal,
        currentSmbDeliveryRatio: Decimal,
        currentMaxSMBBasalMinutes: Decimal,
        currentMaxUAMSMBBasalMinutes: Decimal,
        context: NSManagedObjectContext
    ) -> AlgorithmTelemetryWindowSummary? {
        let postTail = pending.closedAt.addingTimeInterval(6 * 3600)
        let analysisEnd = min(postTail, Date())

        // BG samples in [activatedAt, analysisEnd]
        let glucoseReq = GlucoseStored.fetchRequest()
        glucoseReq.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@",
            pending.activatedAt as NSDate,
            analysisEnd as NSDate
        )
        glucoseReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

        // Bolus events in same window
        let bolusReq = PumpEventStored.fetchRequest()
        bolusReq.predicate = NSPredicate(
            format: "timestamp >= %@ AND timestamp <= %@ AND type == %@",
            pending.activatedAt as NSDate,
            analysisEnd as NSDate,
            PumpEventStored.EventType.bolus.rawValue
        )
        bolusReq.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        var glucoseSamples: [(date: Date, glucose: Int)] = []
        var smbInsulin: Double = 0
        var manualInsulin: Double = 0

        context.performAndWait {
            if let results = try? context.fetch(glucoseReq) {
                glucoseSamples = results.compactMap { sample in
                    guard let date = sample.date else { return nil }
                    return (date: date, glucose: Int(sample.glucose))
                }
            }
            if let bolusEvents = try? context.fetch(bolusReq) {
                for event in bolusEvents {
                    guard let bolus = event.bolus, let amount = bolus.amount else { continue }
                    let units = Double(truncating: amount)
                    if bolus.isExternal { continue } // external = not pump-enacted; tracked separately
                    if bolus.isSMB {
                        smbInsulin += units
                    } else {
                        manualInsulin += units
                    }
                }
            }
        }

        // Sort + summarize
        guard !glucoseSamples.isEmpty else { return nil }
        let peak = glucoseSamples.max { $0.glucose < $1.glucose }!
        let nadir = glucoseSamples.min { $0.glucose < $1.glucose }!

        // Time above/below = sum of (next-sample-time - current-sample-time) where current is above/below.
        // Trapezoidal-ish; samples are typically 5min apart so this is close enough.
        func timeAbove(_ threshold: Int) -> Double {
            var total: Double = 0
            for i in 0 ..< glucoseSamples.count - 1 where glucoseSamples[i].glucose > threshold {
                total += glucoseSamples[i + 1].date.timeIntervalSince(glucoseSamples[i].date)
            }
            return total / 60.0 // seconds → minutes
        }
        func timeBelow(_ threshold: Int) -> Double {
            var total: Double = 0
            for i in 0 ..< glucoseSamples.count - 1 where glucoseSamples[i].glucose < threshold {
                total += glucoseSamples[i + 1].date.timeIntervalSince(glucoseSamples[i].date)
            }
            return total / 60.0
        }

        func bgAt(minutesAfter offsetMinutes: Double) -> Double? {
            let target = pending.activatedAt.addingTimeInterval(offsetMinutes * 60)
            return glucoseSamples
                .min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
                .map { Double($0.glucose) }
        }

        return AlgorithmTelemetryWindowSummary(
            windowId: pending.windowId,
            activatedAt: pending.activatedAt,
            closedAt: pending.closedAt,
            closeReason: pending.closeReason,
            estimatedCarbsHint: pending.estimatedCarbs,
            realCarbsLogged: nil, // could be filled from CarbEntryStored in a follow-up
            realFatLogged: nil,
            realProteinLogged: nil,
            carbsConfirmed: pending.carbsConfirmed,
            bgAtActivation: bgAtActivation,
            iobAtActivation: iobAtActivation,
            cobAtActivation: cobAtActivation,
            velocityAtActivation: nil,
            accelerationAtActivation: nil,
            mealDetectionAtActivation: nil,
            peakBG: Double(peak.glucose),
            peakBGMinutesAfterActivation: peak.date.timeIntervalSince(pending.activatedAt) / 60,
            nadirBG: Double(nadir.glucose),
            nadirBGMinutesAfterActivation: nadir.date.timeIntervalSince(pending.activatedAt) / 60,
            bgAt2hr: bgAt(minutesAfter: 120),
            bgAt4hr: bgAt(minutesAfter: 240),
            bgAt6hr: bgAt(minutesAfter: 360),
            minutesAbove180: timeAbove(180),
            minutesAbove250: timeAbove(250),
            minutesBelow70: timeBelow(70),
            totalSMBInsulin: smbInsulin,
            totalScheduledBasalInsulin: nil, // would require summing temp basal events; deferred
            totalManualBolusInsulin: manualInsulin,
            floorActivationCount: floorActivationCount,
            target: nil,
            isf: nil,
            carbRatio: nil,
            maxIOB: Double(truncating: currentMaxIOB as NSDecimalNumber),
            smbDeliveryRatio: Double(truncating: currentSmbDeliveryRatio as NSDecimalNumber),
            maxSMBBasalMinutes: Double(truncating: currentMaxSMBBasalMinutes as NSDecimalNumber),
            maxUAMSMBBasalMinutes: Double(truncating: currentMaxUAMSMBBasalMinutes as NSDecimalNumber)
        )
    }

    // MARK: - Pending list persistence

    private func readPending() -> [Pending] {
        guard let data = try? Data(contentsOf: pendingFileURL) else { return [] }
        return (try? TelemetryCoding.decoder.decode([Pending].self, from: data)) ?? []
    }

    private func writePending(_ list: [Pending]) {
        do {
            try fileManager.createDirectory(
                at: pendingFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try TelemetryCoding.encoder.encode(list)
            try data.write(to: pendingFileURL, options: .atomic)
        } catch {
            debug(.service, "[Telemetry] pending outcomes write failed: \(error)")
        }
    }
}

/// Shared encoder alias so this file doesn't need to depend on the private struct.
private enum TelemetryCoding {
    static let encoder: JSONEncoder = AlgorithmTelemetryCoding.encoder
    static let decoder: JSONDecoder = AlgorithmTelemetryCoding.decoder
}
