import CoreData
import Foundation

public extension SavedMeal {
    @nonobjc class func fetchRequest() -> NSFetchRequest<SavedMeal> {
        NSFetchRequest<SavedMeal>(entityName: "SavedMeal")
    }

    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var icon: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?

    /// Optional macro defaults — nil when the user hasn't specified them.
    @NSManaged var defaultCarbs: NSDecimalNumber?
    @NSManaged var defaultFat: NSDecimalNumber?
    @NSManaged var defaultProtein: NSDecimalNumber?

    /// Seeded classification for windows started from this meal. Nil → use
    /// the live classifier's default (Simple → Medium → Complex progression).
    /// String form of MealClassification.rawValue.
    @NSManaged var defaultClassification: String?

    /// Per-meal overrides for window behavior. Nil → fall back to the global
    /// classifier defaults from TrioSettings.
    @NSManaged var defaultExtendedDurationMinutes: Int32
    @NSManaged var defaultPhantomCOBEnabled: Bool
    @NSManaged var defaultPhantomCOBGrams: NSDecimalNumber?

    /// Cached derived stats — kept on the row for fast picker rendering so we
    /// don't have to aggregate every instance on every list refresh. Recomputed
    /// whenever an instance closes.
    @NSManaged var cachedInstanceCount: Int32
    @NSManaged var cachedRecommendedClassification: String?

    /// JSON-encoded array of MealTag UUIDs assigned to this meal.
    /// Looked up against TrioSettings.mealTags for the tag's current
    /// name / category memberships. Stored as JSON string so future
    /// per-meal tag metadata (e.g. per-meal overrides on a tag) can
    /// land without a Core Data migration.
    @NSManaged var tagIDsJSON: String?

    @NSManaged var instances: NSSet?
}

public extension SavedMeal {
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

public extension SavedMeal {
    @objc(addInstancesObject:)
    @NSManaged func addToInstances(_ value: SavedMealInstance)

    @objc(removeInstancesObject:)
    @NSManaged func removeFromInstances(_ value: SavedMealInstance)

    @objc(addInstances:)
    @NSManaged func addToInstances(_ values: NSSet)

    @objc(removeInstances:)
    @NSManaged func removeFromInstances(_ values: NSSet)
}

extension SavedMeal: Identifiable {}
