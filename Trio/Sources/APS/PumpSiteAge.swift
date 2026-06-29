import CoreData
import Foundation

/// Pump-site age — hours since the most recent rewind event in
/// `PumpEventStored`. For Omnipod this corresponds to a pod swap; for
/// Medtronic, a reservoir/infusion-set change. Either way, "time since
/// last fresh cannula in the body" — the variable most correlated with
/// site degradation and the resulting effective-CR/ISF drift we
/// observed in the 6-27 telemetry analysis.
///
/// Returns nil when no rewind events are recorded (fresh install,
/// pump-history retention rolled past the last change, or non-pod /
/// non-reservoir pump types that don't emit rewind events).
enum PumpSiteAge {
    /// Compute hours since latest rewind. Synchronous + fast — just a
    /// fetchLimit=1 query on PumpEventStored, runs in a few ms.
    static func hoursSinceLastRewind(now: Date = Date()) -> Double? {
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        var lastDate: Date?
        ctx.performAndWait {
            let req = PumpEventStored.fetchRequest()
            req.predicate = NSPredicate(
                format: "type == %@",
                PumpEventStored.EventType.rewind.rawValue
            )
            req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            req.fetchLimit = 1
            lastDate = (try? ctx.fetch(req))?.first?.timestamp
        }
        guard let lastDate else { return nil }
        return now.timeIntervalSince(lastDate) / 3600.0
    }
}
