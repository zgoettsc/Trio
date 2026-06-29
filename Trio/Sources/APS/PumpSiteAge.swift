import CoreData
import Foundation
import Swinject

/// Pump-site age — hours since the cannula started delivering on the
/// current site. The variable most correlated with site degradation
/// and the resulting effective-CR/ISF drift we observed in the 6-27
/// telemetry analysis.
///
/// Two data paths, tried in order:
///
/// 1. **`monitor/pod-age.json`** — Omnipod's pod activation timestamp,
///    persisted by `DeviceDataManager.pumpManager.heartbeat(...)` from
///    `omni.state.podState?.activatedAt`. This is the canonical Omnipod
///    source; rewind events aren't logged into `PumpEventStored` for
///    Omnipod, so without this read, pod age would always be nil.
///
/// 2. **`PumpEventStored` rewind query** — fallback for pumps that
///    log rewinds as pump events (Medtronic / Dana / Medtrum). One
///    fetchLimit=1 query against the latest `type == "Rewind"` row.
///
/// Returns nil when neither path produces a date (fresh install with
/// no pod activated yet, or a pump driver that doesn't surface
/// activation in either form).
enum PumpSiteAge {
    static func hoursSinceLastRewind(now: Date = Date()) -> Double? {
        // Path 1: Omnipod's podState.activatedAt, persisted by Trio's
        // DeviceDataManager to monitor/pod-age.json.
        if let podActivated = readOmnipodActivation() {
            return now.timeIntervalSince(podActivated) / 3600.0
        }

        // Path 2: PumpEventStored rewind history (Medtronic-style pumps).
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

    /// Read the Omnipod pod activation timestamp from FileStorage.
    /// Resolved each call rather than cached so a swap mid-session is
    /// picked up immediately on the next meal-window activation.
    private static func readOmnipodActivation() -> Date? {
        let resolver: Resolver = TrioApp.resolver
        guard let fileStorage = resolver.resolve(FileStorage.self) else { return nil }
        return fileStorage.retrieve(OpenAPS.Monitor.podAge, as: Date.self)
    }
}
