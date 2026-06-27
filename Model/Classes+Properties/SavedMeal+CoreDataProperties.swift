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

    @NSManaged var instances: NSSet?
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
