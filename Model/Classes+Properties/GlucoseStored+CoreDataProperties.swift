import CoreData
import Foundation

public extension GlucoseStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<GlucoseStored> {
        NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
    }

    @NSManaged var date: Date?
    @NSManaged var direction: String?
    @NSManaged var glucose: Int16
    @NSManaged var id: UUID?
    @NSManaged var isManual: Bool
    @NSManaged var isUploadedToHealth: Bool
    @NSManaged var isUploadedToNS: Bool
    @NSManaged var isUploadedToTidepool: Bool
    @NSManaged var smoothedGlucose: NSDecimalNumber?
    /// S0.3a — CGM quality fields (nil when the source does not supply them, e.g. plugin CGMs).
    @NSManaged var noise: NSNumber?
    @NSManaged var device: String?
    @NSManaged var isCalibration: Bool
    @NSManaged var sessionStart: Date?
}

extension GlucoseStored: Identifiable {}
