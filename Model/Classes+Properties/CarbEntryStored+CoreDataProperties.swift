import CoreData
import Foundation

public extension CarbEntryStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<CarbEntryStored> {
        NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
    }

    @NSManaged var carbs: Double
    @NSManaged var date: Date?
    @NSManaged var fat: Double
    @NSManaged var fpuID: UUID?
    @NSManaged var id: UUID?
    @NSManaged var isFPU: Bool
    @NSManaged var isUploadedToNS: Bool
    @NSManaged var isUploadedToHealth: Bool
    @NSManaged var isUploadedToTidepool: Bool
    @NSManaged var note: String?
    @NSManaged var protein: Double
    /// True when the user logged this entry to TREAT A LOW (juice, glucose
    /// tabs, etc.) rather than as a meal. Excluded from oref's meal.json
    /// COB calculation so the loop doesn't dose extra insulin against
    /// carbs the user ate specifically to RECOVER from being low — which
    /// is what causes the dropping → eat-juice → loop doses → drop-again
    /// cycle. Entry is still stored locally + telemetry'd for analytics.
    @NSManaged var isRescueCarbs: Bool
    /// Free-text name of the rescue preset used (e.g. "Juice box", "Glucose
    /// tabs", "Granola bar"). Nil when user typed a custom rescue entry.
    /// Lets analytics group BG-recovery curves by what was eaten.
    @NSManaged var rescuePresetName: String?
}

extension CarbEntryStored: Identifiable {}
