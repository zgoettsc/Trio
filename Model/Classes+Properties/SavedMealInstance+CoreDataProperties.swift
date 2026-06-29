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

    /// "macros" if user entered them, "inferred" if derived from BG response,
    /// "manual" if entered at backfill time without a logged carb entry.
    @NSManaged var carbBucketSource: String?

    /// True when this instance was created retroactively from a past carb
    /// entry or custom time, not from a live meal-window activation.
    @NSManaged var backfilled: Bool

    /// Context markers — captured at instance close so analytics can filter
    /// out instances that ran under unusual conditions (Running override,
    /// low temp target, sensor outage) vs the normal coverage baseline.
    @NSManaged var windowHadOverride: Bool
    @NSManaged var overrideMinutesDuringWindow: Int32
    @NSManaged var overrideSuppressedSMB: Bool
    @NSManaged var windowHadTempTarget: Bool
    @NSManaged var sensorGapMinutes: Int32

    /// Snapshot of insulin-sensitivity context AT THE MOMENT the window
    /// opened. Lets analysis correlate excursion size (peakBG -
    /// bgAtActivation, AUC, etc.) with both the calculated Autosens ratio
    /// and the Smart-Sense blended ratio: does a high resistance reading
    /// actually predict a larger excursion, or are the sensors noise?
    /// All five are optional — nil means the value wasn't available at the
    /// time (e.g. fresh install, sensor outage, Smart-Sense disabled).
    @NSManaged var bgAtActivation: NSDecimalNumber?
    @NSManaged var bgTrendAtActivation: NSDecimalNumber?
    @NSManaged var autosensRatioAtActivation: NSDecimalNumber?
    @NSManaged var smartSenseRatioAtActivation: NSDecimalNumber?
    @NSManaged var effectiveISFAtActivation: NSDecimalNumber?
    /// CR (g/U) oref was using at activation — needed for the per-instance
    /// "estimated carbs from BG response" estimator: given total insulin
    /// delivered and the BG curve, back-calculates what the meal "looked
    /// like" in carb-equivalents.
    @NSManaged var carbRatioAtActivation: NSDecimalNumber?

    /// Cumulative carbs the live mid-meal estimator added via the user
    /// accepting "Add N g now" suggestions. Does NOT mutate
    /// `carbsAtActivation` — that stays frozen at the user's first decision
    /// so the post-hoc estimator's self-calibration math stays clean.
    /// `true_entered_for_this_meal = carbsAtActivation + carbsAddedByEstimator`.
    @NSManaged var carbsAddedByEstimator: NSDecimalNumber?
    /// If the user picked "Edit original to N g" instead of "Add now", the
    /// final value the original entry was edited to. Original timestamp is
    /// preserved; `carbsAtActivation` is NOT mutated.
    @NSManaged var carbsEditedTo: NSDecimalNumber?

    /// User-verified ground-truth carbs (label-read, weighed, or otherwise
    /// confidently known). When set, drives the inverse calibrator: given
    /// the BG response we observed, what CR/ISF would explain it? Reserved
    /// for meals where the user is certain — never auto-filled.
    @NSManaged var userVerifiedCarbsAmount: NSDecimalNumber?
    /// User-verified fat (grams). Optional — nil means "didn't verify",
    /// NOT zero. Captures fat composition for offline analysis even
    /// though the current inverse calibrator only uses carbs.
    @NSManaged var userVerifiedFatAmount: NSDecimalNumber?
    /// User-verified protein (grams). Optional — nil means "didn't verify",
    /// NOT zero. Same role as fat above.
    @NSManaged var userVerifiedProteinAmount: NSDecimalNumber?
    /// Timestamp the user marked this instance verified. Lets analytics
    /// track when calibration data accumulated and aging out old reads.
    @NSManaged var verifiedAt: Date?

    /// JSON-encoded snapshot of GarminContextSnapshot captured at
    /// meal-window activation. Nullable — Garmin may be unavailable
    /// for any given meal (Firestore down, user hasn't synced, device
    /// offline, or telemetryIncludeGarmin toggled off). Stored as JSON
    /// rather than columns so future Garmin fields don't require
    /// schema migration.
    @NSManaged var garminContextAtActivationJSON: String?
    /// Hours since the most recent pump rewind event (PumpEventStored
    /// type == "rewind"), computed at meal-window activation.
    /// Lets analytics correlate cannula age with per-meal effective
    /// CR/ISF — site degradation typically shows up day-2 onward.
    /// Nullable because there may be no rewind events recorded
    /// (fresh install, history clipped).
    @NSManaged var pumpSiteAgeHours: NSNumber?

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
        CarbBucket.from(carbs: carbsAtActivation?.decimalValue)
    }
}
