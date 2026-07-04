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
    /// JSON-encoded array of MealTag UUIDs. Shares the tag library with
    /// SavedMeal.tagIDsJSON — same tags, same picker. Nil / empty when the
    /// user hasn't tagged this entry. Retroactively editable via the
    /// long-press edit sheet on the History treatments list.
    @NSManaged var tagIDsJSON: String?
}

public extension CarbEntryStored {
    /// Decoded tag-ID list. Empty when nil/invalid.
    var tagIDs: [UUID] {
        get {
            guard let json = tagIDsJSON,
                  let data = json.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([UUID].self, from: data)
            else { return [] }
            return arr
        }
        set {
            guard !newValue.isEmpty else {
                tagIDsJSON = nil
                return
            }
            if let data = try? JSONEncoder().encode(newValue),
               let s = String(data: data, encoding: .utf8)
            {
                tagIDsJSON = s
            }
        }
    }
}

extension CarbEntryStored: Identifiable {}
