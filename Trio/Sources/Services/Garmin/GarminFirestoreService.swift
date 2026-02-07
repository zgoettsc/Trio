import Foundation

// MARK: - Phase C: Garmin Firestore Service
//
// Queries Garmin health data from the user's existing Firestore database.
// Firestore receives Garmin Health API data when the watch syncs to Garmin Connect.
//
// NOTE: This service requires the Firebase iOS SDK (FirebaseFirestore).
// Until the dependency is added, this provides the protocol and a stub
// implementation that returns nil (graceful fallback to no adjustment).

// MARK: - Protocol

protocol GarminFirestoreService {
    /// Query the latest Garmin health context from Firestore.
    /// Returns nil if Firestore is unavailable or the query fails.
    func fetchContext() async -> GarminContextSnapshot?

    /// Whether the service is configured and available.
    var isConfigured: Bool { get }
}

// MARK: - Configuration

struct GarminFirestoreConfig: Codable {
    var isEnabled: Bool = false
    var projectID: String = ""

    // Collection paths (configurable to match user's actual Firestore schema)
    var dailySummariesPath: String = "dailySummaries"
    var sleepDataPath: String = "sleepData"
    var stressDataPath: String = "stressData"
    var heartRateDataPath: String = "heartRateData"
    var hrvDataPath: String = "hrvData"
    var bodyBatteryPath: String = "bodyBattery"
    var trainingStatusPath: String = "trainingStatus"
    var activitiesPath: String = "activities"

    /// Cache duration — don't re-query within this interval (seconds)
    var cacheDurationSeconds: TimeInterval = 5 * 60 // 5 minutes
}

// MARK: - Stub Implementation (until Firebase SDK is added)

/// Stub implementation that always returns nil.
/// When Firebase SDK is integrated, this will be replaced with the real implementation
/// that queries Firestore collections for today's and yesterday's Garmin data.
final class StubGarminFirestoreService: GarminFirestoreService {

    private var cachedSnapshot: GarminContextSnapshot?
    private var cacheTimestamp: Date?
    private let config: GarminFirestoreConfig

    var isConfigured: Bool { config.isEnabled && !config.projectID.isEmpty }

    init(config: GarminFirestoreConfig = GarminFirestoreConfig()) {
        self.config = config
    }

    func fetchContext() async -> GarminContextSnapshot? {
        // Check cache
        if let cached = cachedSnapshot,
           let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < config.cacheDurationSeconds
        {
            return cached
        }

        // Stub: return nil (falls back to insulinDemandFactor = 1.0)
        // Real implementation will query Firestore here:
        //   1. Fetch today's dailySummary document
        //   2. Fetch last night's sleep document
        //   3. Fetch today's stress data
        //   4. Fetch heart rate and HRV data
        //   5. Fetch body battery data
        //   6. Fetch training status
        //   7. Fetch yesterday's daily summary (for delayed activity effects)
        //   8. Build and return GarminContextSnapshot

        return nil
    }
}

// MARK: - Future: Real Firestore Implementation
//
// When Firebase SDK is added via SPM, implement:
//
// final class FirebaseGarminFirestoreService: GarminFirestoreService {
//     private let db: Firestore
//     private let config: GarminFirestoreConfig
//
//     func fetchContext() async -> GarminContextSnapshot? {
//         let dateString = DateFormatter.garminDate.string(from: Date())
//         let yesterdayString = DateFormatter.garminDate.string(from: Date().addingTimeInterval(-86400))
//
//         async let daily = db.collection(config.dailySummariesPath).document(dateString).getDocument()
//         async let sleep = db.collection(config.sleepDataPath).document(dateString).getDocument()
//         async let stress = db.collection(config.stressDataPath).document(dateString).getDocument()
//         async let hr = db.collection(config.heartRateDataPath).document(dateString).getDocument()
//         async let hrv = db.collection(config.hrvDataPath).document(dateString).getDocument()
//         async let bb = db.collection(config.bodyBatteryPath).document(dateString).getDocument()
//         async let training = db.collection(config.trainingStatusPath).document("latest").getDocument()
//         async let yesterday = db.collection(config.dailySummariesPath).document(yesterdayString).getDocument()
//
//         // Build GarminContextSnapshot from document fields...
//     }
// }
