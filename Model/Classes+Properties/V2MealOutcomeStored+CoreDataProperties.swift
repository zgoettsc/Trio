import CoreData
import Foundation

public extension V2MealOutcomeStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<V2MealOutcomeStored> {
        NSFetchRequest<V2MealOutcomeStored>(entityName: "V2MealOutcomeStored")
    }

    // Core identifiers
    @NSManaged var id: UUID?
    @NSManaged var date: Date?
    @NSManaged var mealID: String?

    // Original macros
    @NSManaged var carbs: Double
    @NSManaged var fat: Double
    @NSManaged var protein: Double
    @NSManaged var fiber: Double

    // V2 curve parameters used
    @NSManaged var tauCarb: Double
    @NSManaged var proteinFactor: Double
    @NSManaged var fatTotalEquiv: Double
    @NSManaged var upfrontPercent: Double
    @NSManaged var curveSuggestedPercent: Double
    @NSManaged var insulinDemandFactor: Double
    @NSManaged var safeWindowMinutes: Int16

    // Dosing context
    @NSManaged var bgAtMeal: Int16
    @NSManaged var carbRatioAtMeal: Double
    @NSManaged var isfAtMeal: Double

    // SMB enhancement
    @NSManaged var mealSMBMultiplier: Double
    @NSManaged var mealModeWasActive: Bool

    // Confounding meal flag
    @NSManaged var hasConfoundingMeal: Bool

    // JSON-encoded nested data
    @NSManaged var checkpointsJSON: Data?
    @NSManaged var adaptiveAdjustmentsJSON: Data?
    @NSManaged var garminSnapshotJSON: Data?
    @NSManaged var garminContributionsJSON: Data?  // critique item #10: stored at meal time
}

extension V2MealOutcomeStored: Identifiable {}
