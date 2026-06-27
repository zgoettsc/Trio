import CoreData
import Foundation

public extension SavedMealInstance {
    @nonobjc class func fetchRequest() -> NSFetchRequest<SavedMealInstance> {
        NSFetchRequest<SavedMealInstance>(entityName: "SavedMealInstance")
    }

    @NSManaged var id: UUID?
    @NSManaged var windowId: String?
    @NSManaged var startedAt: Date?
    @NSManaged var closedAt: Date?

    /// Macros captured at activation (optional — zero-entry flow leaves these nil).
    @NSManaged var carbsAtActivation: NSDecimalNumber?
    @NSManaged var fatAtActivation: NSDecimalNumber?
    @NSManaged var proteinAtActivation: NSDecimalNumber?

    @NSManaged var initialClassification: String?
    @NSManaged var finalClassification: String?

    /// Optimization: BG curve, SMBs, floor activations, and classifier upgrades
    /// are stored as JSON blobs rather than separate child entities. Each instance
    /// caps at ~50 BG samples (10h × 12/hr = 120 max, typical 50) — at 30 bytes/sample
    /// that's <4KB JSON, plenty cheap.
    @NSManaged var bgCurveJSON: String?
    @NSManaged var smbsJSON: String?
    @NSManaged var floorActivationsJSON: String?
    @NSManaged var classifierUpgradesJSON: String?

    /// Outcome metrics — auto-computed at window close from loop sample stream.
    @NSManaged var outcomeScore: Int32
    @NSManaged var peakBG: Double
    @NSManaged var timeInRangeMinutes: Int32
    @NSManaged var timeAboveRangeMinutes: Int32
    @NSManaged var timeBelowRangeMinutes: Int32
    @NSManaged var lowsCount: Int32
    @NSManaged var timeToBaselineMinutes: Int32
    @NSManaged var totalInsulinDeliveredU: Double
    @NSManaged var smbCount: Int32
    @NSManaged var floorActivationCount: Int32

    /// "macros" if user entered them, "inferred" if derived from BG response.
    @NSManaged var carbBucketSource: String?

    @NSManaged var savedMeal: SavedMeal?
}

extension SavedMealInstance: Identifiable {}

/// Carb bucket derived from `carbsAtActivation` for stratified analytics.
/// See MEAL_INTELLIGENCE_DESIGN.md §9.
extension SavedMealInstance {
    enum CarbBucket: String {
        case small, medium, large

        static func from(carbs: Decimal?) -> CarbBucket? {
            guard let carbs else { return nil }
            let d = NSDecimalNumber(decimal: carbs).doubleValue
            if d < 40 { return .small }
            if d < 80 { return .medium }
            return .large
        }
    }

    var carbBucket: CarbBucket? {
        CarbBucket.from(carbs: carbsAtActivation as Decimal?)
    }
}
