import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

// MARK: - Phase C: Garmin Firestore Service
//
// Queries Garmin health data from the user's Firestore database.
// Garmin Health API webhooks → Cloud Function → Firestore.
//
// Firestore path: /users/{uid}/garminData/{summaryType}/{documents}
// Summary types: dailies, sleeps, stressDetails, hrv, userMetrics
//
// Firebase project configuration is injected at build time from GitHub secrets
// via GarminFirebaseConfig.swift. If secrets are not configured, the service
// returns nil (graceful fallback to no Garmin adjustment).

// MARK: - Protocol

protocol GarminFirestoreServiceProtocol {
    func fetchContext() async -> GarminContextSnapshot?
    var isConfigured: Bool { get }
}

// MARK: - Configuration

struct GarminFirestoreConfig: Codable {
    var isEnabled: Bool = false
    var userID: String = ""  // Firestore user ID: e.g. "0Zp7LAT9bLMIEFWNyy694Gylf0n1"

    /// Base path: /users/{userID}/garminData
    var basePath: String { "users/\(userID)/garminData" }

    /// Collection names under garminData/ — these match the Garmin Health API push summary types.
    /// The cloud function stores each push notification's payload as a document keyed by calendarDate.
    var dailiesCollection: String = "dailies"
    var sleepsCollection: String = "sleeps"
    var stressDetailsCollection: String = "stressDetails"
    var hrvCollection: String = "hrv"
    var userMetricsCollection: String = "userMetrics"

    /// Cache duration — don't re-query within this interval (seconds)
    var cacheDurationSeconds: TimeInterval = 5 * 60 // 5 minutes
}

// MARK: - Garmin Firebase App Manager

/// Manages the secondary Firebase app instance for the user's Garmin Firestore project.
/// The default FirebaseApp is used by Trio for Crashlytics. This creates a separate
/// named app ("garmin") for accessing the user's personal Firestore.
enum GarminFirebaseManager {
    private static let appName = "garmin"
    private(set) static var isSignedIn = false

    /// Configure the secondary Firebase app and sign in.
    /// Safe to call multiple times — skips if already configured.
    static func configureAndSignIn() async {
        guard GarminFirebaseConstants.isConfigured else {
            debug(.service, "Garmin Firebase: not configured (secrets not injected)")
            return
        }

        // Configure the secondary Firebase app if not already done
        if FirebaseApp.app(name: appName) == nil {
            let options = FirebaseOptions(
                googleAppID: GarminFirebaseConstants.googleAppID,
                gcmSenderID: GarminFirebaseConstants.gcmSenderID
            )
            options.apiKey = GarminFirebaseConstants.apiKey
            options.projectID = GarminFirebaseConstants.projectID
            options.storageBucket = GarminFirebaseConstants.storageBucket
            options.clientID = GarminFirebaseConstants.clientID

            FirebaseApp.configure(name: appName, options: options)
            debug(.service, "Garmin Firebase: secondary app configured (project: \(GarminFirebaseConstants.projectID))")
        }

        // Sign in if not already authenticated
        guard let app = FirebaseApp.app(name: appName) else { return }
        let auth = Auth.auth(app: app)

        if auth.currentUser != nil {
            isSignedIn = true
            debug(.service, "Garmin Firebase: already signed in as \(auth.currentUser?.uid ?? "unknown")")
            return
        }

        do {
            let result = try await auth.signIn(
                withEmail: GarminFirebaseConstants.authEmail,
                password: GarminFirebaseConstants.authPassword
            )
            isSignedIn = true
            debug(.service, "Garmin Firebase: signed in as \(result.user.uid)")
        } catch {
            isSignedIn = false
            debug(.service, "Garmin Firebase: sign-in failed — \(error.localizedDescription)")
        }
    }

    /// Get the Firestore instance for the Garmin Firebase app.
    /// Returns nil if not configured or not signed in.
    static var firestore: Firestore? {
        guard isSignedIn, let app = FirebaseApp.app(name: appName) else { return nil }
        return Firestore.firestore(app: app)
    }
}

// MARK: - Garmin Firestore Service

/// Service that queries Garmin health data from Firestore and builds a GarminContextSnapshot.
final class GarminFirestoreService: GarminFirestoreServiceProtocol {

    private var cachedSnapshot: GarminContextSnapshot?
    private var cacheTimestamp: Date?
    private let config: GarminFirestoreConfig

    var isConfigured: Bool {
        config.isEnabled && !config.userID.isEmpty && GarminFirebaseManager.isSignedIn
    }

    init(config: GarminFirestoreConfig = GarminFirestoreConfig()) {
        self.config = config
    }

    /// Convenience initializer that builds config from GarminFirebaseConstants.
    convenience init() {
        let config = GarminFirestoreConfig(
            isEnabled: GarminFirebaseConstants.isConfigured,
            userID: GarminFirebaseConstants.firestoreUserID
        )
        self.init(config: config)
    }

    /// Fetch the latest Garmin context snapshot from Firestore.
    /// Returns nil if Firestore is unavailable, the query fails, or Garmin is not configured.
    func fetchContext() async -> GarminContextSnapshot? {
        guard isConfigured else { return nil }

        // Check cache
        if let cached = cachedSnapshot,
           let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < config.cacheDurationSeconds
        {
            return cached
        }

        // Build snapshot from Firestore documents
        let snapshot = await buildSnapshot()
        if snapshot != nil {
            cachedSnapshot = snapshot
            cacheTimestamp = Date()
        }
        return snapshot
    }

    // MARK: - Build Snapshot

    /// Queries all relevant Firestore collections and builds a GarminContextSnapshot.
    private func buildSnapshot() async -> GarminContextSnapshot? {
        let today = calendarDateString(for: Date())
        let yesterday = calendarDateString(for: Date().addingTimeInterval(-86400))

        // Fetch documents in parallel
        async let dailyToday = fetchDocument(collection: config.dailiesCollection, documentID: today)
        async let dailyYesterday = fetchDocument(collection: config.dailiesCollection, documentID: yesterday)
        async let sleepToday = fetchMostRecentDocument(collection: config.sleepsCollection, onOrBefore: today)
        async let stressToday = fetchDocument(collection: config.stressDetailsCollection, documentID: today)
        async let hrvToday = fetchMostRecentDocument(collection: config.hrvCollection, onOrBefore: today)
        async let userMetrics = fetchMostRecentDocument(collection: config.userMetricsCollection, onOrBefore: today)

        // Also fetch last 7 days of dailies and HRV for computing averages
        async let dailies7Day = fetchDocuments(collection: config.dailiesCollection, lastDays: 7)
        async let hrv7Day = fetchDocuments(collection: config.hrvCollection, lastDays: 7)

        let (daily, yDaily, sleep, stress, hrv, metrics, recentDailies, recentHRV) = await (
            dailyToday, dailyYesterday, sleepToday, stressToday, hrvToday, userMetrics, dailies7Day, hrv7Day
        )

        // If we got no data at all, return nil
        guard daily != nil || sleep != nil || stress != nil || hrv != nil else { return nil }

        // Extract body battery from stress details (timeOffsetBodyBatteryValues map)
        let (currentBB, wakeBB) = extractBodyBattery(from: stress)
        let currentStress = extractCurrentStress(from: stress)

        // Compute 7-day averages
        let avgRHR = compute7DayAvgRHR(from: recentDailies)
        let avgHRV = compute7DayAvgHRV(from: recentHRV)

        return GarminContextSnapshot(
            queryTime: Date(),
            // Daily
            restingHeartRateInBeatsPerMinute: daily?["restingHeartRateInBeatsPerMinute"] as? Int,
            averageHeartRateInBeatsPerMinute: daily?["averageHeartRateInBeatsPerMinute"] as? Int,
            averageStressLevel: daily?["averageStressLevel"] as? Int,
            maxStressLevel: daily?["maxStressLevel"] as? Int,
            stressDurationInSeconds: daily?["stressDurationInSeconds"] as? Int,
            restStressDurationInSeconds: daily?["restStressDurationInSeconds"] as? Int,
            lowStressDurationInSeconds: daily?["lowStressDurationInSeconds"] as? Int,
            mediumStressDurationInSeconds: daily?["mediumStressDurationInSeconds"] as? Int,
            highStressDurationInSeconds: daily?["highStressDurationInSeconds"] as? Int,
            stressQualifier: daily?["stressQualifier"] as? String,
            steps: daily?["steps"] as? Int,
            activeKilocalories: daily?["activeKilocalories"] as? Int,
            moderateIntensityDurationInSeconds: daily?["moderateIntensityDurationInSeconds"] as? Int,
            vigorousIntensityDurationInSeconds: daily?["vigorousIntensityDurationInSeconds"] as? Int,
            bodyBatteryChargedValue: daily?["bodyBatteryChargedValue"] as? Int,
            bodyBatteryDrainedValue: daily?["bodyBatteryDrainedValue"] as? Int,
            // Yesterday
            yesterdaySteps: yDaily?["steps"] as? Int,
            yesterdayActiveKilocalories: yDaily?["activeKilocalories"] as? Int,
            yesterdayModerateIntensityDurationInSeconds: yDaily?["moderateIntensityDurationInSeconds"] as? Int,
            yesterdayVigorousIntensityDurationInSeconds: yDaily?["vigorousIntensityDurationInSeconds"] as? Int,
            // Sleep
            sleepDurationInSeconds: sleep?["durationInSeconds"] as? Int,
            deepSleepDurationInSeconds: sleep?["deepSleepDurationInSeconds"] as? Int,
            lightSleepDurationInSeconds: sleep?["lightSleepDurationInSeconds"] as? Int,
            remSleepInSeconds: sleep?["remSleepInSeconds"] as? Int,
            awakeDurationInSeconds: sleep?["awakeDurationInSeconds"] as? Int,
            sleepScoreValue: (sleep?["overallSleepScore"] as? [String: Any])?["value"] as? Int,
            sleepScoreQualifier: (sleep?["overallSleepScore"] as? [String: Any])?["qualifierKey"] as? String,
            sleepValidation: sleep?["validation"] as? String,
            // Stress Details (extracted)
            currentBodyBattery: currentBB,
            bodyBatteryAtWake: wakeBB,
            currentStressLevel: currentStress,
            // HRV
            lastNightAvg: hrv?["lastNightAvg"] as? Int,
            lastNight5MinHigh: hrv?["lastNight5MinHigh"] as? Int,
            // User Metrics
            vo2Max: metrics?["vo2Max"] as? Double,
            fitnessAge: metrics?["fitnessAge"] as? Int,
            // 7-day averages (computed)
            restingHR7DayAvg: avgRHR,
            hrvWeeklyAvg: avgHRV
        )
    }

    // MARK: - Body Battery & Stress Extraction

    /// Extract current and wake body battery from stressDetails timeOffsetBodyBatteryValues.
    /// The map has keys = offset in seconds from startTime, values = body battery reading.
    /// First entry ≈ wake BB, last entry ≈ current BB.
    private func extractBodyBattery(from stressDoc: [String: Any]?) -> (current: Int?, wake: Int?) {
        guard let doc = stressDoc,
              let bbMap = doc["timeOffsetBodyBatteryValues"] as? [String: Any]
        else { return (nil, nil) }

        let sorted = bbMap.compactMap { (key, value) -> (Int, Int)? in
            guard let offset = Int(key), let bb = value as? Int else { return nil }
            return (offset, bb)
        }.sorted { $0.0 < $1.0 }

        let wake = sorted.first?.1
        let current = sorted.last?.1
        return (current, wake)
    }

    /// Extract the most recent stress level from timeOffsetStressLevelValues.
    /// Values: 1-100 are real stress. Negative values are special (-1=off_wrist, -2=motion, etc).
    private func extractCurrentStress(from stressDoc: [String: Any]?) -> Int? {
        guard let doc = stressDoc,
              let stressMap = doc["timeOffsetStressLevelValues"] as? [String: Any]
        else { return nil }

        let sorted = stressMap.compactMap { (key, value) -> (Int, Int)? in
            guard let offset = Int(key), let stress = value as? Int else { return nil }
            return (offset, stress)
        }.sorted { $0.0 > $1.0 } // newest first

        // Find the most recent valid stress reading (positive values only)
        return sorted.first(where: { $0.1 > 0 })?.1
    }

    // MARK: - 7-Day Averages

    private func compute7DayAvgRHR(from dailies: [[String: Any]]) -> Int? {
        let rhrValues = dailies.compactMap { $0["restingHeartRateInBeatsPerMinute"] as? Int }
        guard !rhrValues.isEmpty else { return nil }
        return rhrValues.reduce(0, +) / rhrValues.count
    }

    private func compute7DayAvgHRV(from hrvDocs: [[String: Any]]) -> Int? {
        let hrvValues = hrvDocs.compactMap { $0["lastNightAvg"] as? Int }
        guard !hrvValues.isEmpty else { return nil }
        return hrvValues.reduce(0, +) / hrvValues.count
    }

    // MARK: - Firestore Document Access

    /// Fetch a single document by collection and calendar date.
    /// Path: /users/{uid}/garminData/{collection}/{calendarDate}
    private func fetchDocument(collection: String, documentID: String) async -> [String: Any]? {
        guard let db = GarminFirebaseManager.firestore else { return nil }

        do {
            let docRef = db.document("\(config.basePath)/\(collection)/\(documentID)")
            let snapshot = try await docRef.getDocument()
            return snapshot.data()
        } catch {
            debug(.service, "Garmin Firestore: fetchDocument(\(collection)/\(documentID)) failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch the most recent document on or before a given date.
    /// Documents are keyed by calendarDate (yyyy-MM-dd), so lexicographic ordering works.
    private func fetchMostRecentDocument(collection: String, onOrBefore dateString: String) async -> [String: Any]? {
        guard let db = GarminFirebaseManager.firestore else { return nil }

        do {
            // First try the exact date (most common case)
            let exactDoc = try await db.document("\(config.basePath)/\(collection)/\(dateString)").getDocument()
            if exactDoc.exists, let data = exactDoc.data() {
                return data
            }

            // Fall back to querying by document ID (lexicographic order on calendarDate keys)
            let collectionRef = db.collection("\(config.basePath)/\(collection)")
            let snapshot = try await collectionRef
                .whereField(FieldPath.documentID(), isLessThanOrEqualTo: dateString)
                .order(by: FieldPath.documentID(), descending: true)
                .limit(to: 1)
                .getDocuments()
            return snapshot.documents.first?.data()
        } catch {
            debug(.service, "Garmin Firestore: fetchMostRecent(\(collection), ≤\(dateString)) failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch documents for the last N days (for computing averages).
    private func fetchDocuments(collection: String, lastDays: Int) async -> [[String: Any]] {
        guard let db = GarminFirebaseManager.firestore else { return [] }

        let cutoff = calendarDateString(for: Date().addingTimeInterval(-Double(lastDays) * 86400))

        do {
            let collectionRef = db.collection("\(config.basePath)/\(collection)")
            let snapshot = try await collectionRef
                .whereField(FieldPath.documentID(), isGreaterThanOrEqualTo: cutoff)
                .order(by: FieldPath.documentID(), descending: true)
                .getDocuments()
            return snapshot.documents.map { $0.data() }
        } catch {
            debug(.service, "Garmin Firestore: fetchDocuments(\(collection), \(lastDays)d) failed — \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Helpers

    /// Format a date as "yyyy-MM-dd" to match Garmin Health API calendarDate format.
    private func calendarDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
