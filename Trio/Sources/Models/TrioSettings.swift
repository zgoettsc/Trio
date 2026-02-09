import Foundation

enum BolusShortcutLimit: String, JSON, CaseIterable, Identifiable {
    var id: String { rawValue }
    case notAllowed
    case limitBolusMax

    var displayName: String {
        switch self {
        case .notAllowed:
            return String(localized: "Not allowed")
        case .limitBolusMax:
            return String(localized: "Max bolus")
        }
    }
}

struct TrioSettings: JSON, Equatable {
    var units: GlucoseUnits = .mgdL
    var closedLoop: Bool = false
    var isUploadEnabled: Bool = false
    var isDownloadEnabled: Bool = false
    var useLocalGlucoseSource: Bool = false
    var localGlucosePort: Int = 8080
    var debugOptions: Bool = false
    var cgm: CGMType = .none
    var cgmPluginIdentifier: String = ""
    var uploadGlucose: Bool = true
    var useCalendar: Bool = false
    var displayCalendarIOBandCOB: Bool = false
    var displayCalendarEmojis: Bool = false
    var glucoseBadge: Bool = false
    var notificationsPump: Bool = true
    var notificationsCgm: Bool = true
    var notificationsCarb: Bool = true
    var notificationsAlgorithm: Bool = true
    var glucoseNotificationsOption: GlucoseNotificationsOption = .onlyAlarmLimits
    var addSourceInfoToGlucoseNotifications: Bool = false
    var lowGlucose: Decimal = 72
    var highGlucose: Decimal = 270
    var carbsRequiredThreshold: Decimal = 10
    var showCarbsRequiredBadge: Bool = true
    var useFPUconversion: Bool = true
    var individualAdjustmentFactor: Decimal = 0.5
    var timeCap: Decimal = 8
    var minuteInterval: Decimal = 30
    var delay: Decimal = 60
    var useAppleHealth: Bool = false
    var writeNutritionToHealth: Bool = true
    var readNutritionFromHealth: Bool = false
    var healthMetricsSettings: HealthMetricsSettings = HealthMetricsSettings()
    var smoothGlucose: Bool = false
    var eA1cDisplayUnit: EstimatedA1cDisplayUnit = .percent
    var high: Decimal = 180
    var low: Decimal = 70
    var glucoseColorScheme: GlucoseColorScheme = .staticColor
    var xGridLines: Bool = true
    var yGridLines: Bool = true
    var rulerMarks: Bool = true
    var forecastDisplayType: ForecastDisplayType = .cone
    var maxCarbs: Decimal = 250
    var maxFat: Decimal = 250
    var maxProtein: Decimal = 250
    var confirmBolusFaster: Bool = false
    var overrideFactor: Decimal = 0.8
    var fattyMeals: Bool = false
    var fattyMealFactor: Decimal = 0.7
    var sweetMeals: Bool = false
    var sweetMealFactor: Decimal = 1
    var displayPresets: Bool = true
    var confirmBolus: Bool = false
    var useLiveActivity: Bool = false
    var lockScreenView: LockScreenView = .simple
    var smartStackView: LockScreenView = .simple
    var bolusShortcut: BolusShortcutLimit = .notAllowed
    var timeInRangeType: TimeInRangeType = .timeInTightRange

    // MARK: - V2 Macro Absorption Engine Settings

    /// Use the V2 three-curve absorption engine instead of the linear Warsaw Method.
    var useV2MacroAbsorption: Bool = false
    /// Insulin type for safe window calculation.
    var insulinType: String = "rapidActing" // "ultraRapid" or "rapidActing"
    /// Override for the safe window (minutes). nil = use insulin type default.
    var v2SafeWindowMinutes: Int?
    /// Meal-mode SMB multiplier (1.0 = no enhancement, 2.0 = default, max 3.0).
    var mealModeSMBMultiplier: Decimal = 2.0
    /// BG floor for meal-mode SMB activation (mg/dL).
    var mealModeBGFloor: Decimal = 90
    /// Minimum upfront bolus floor for high-fat meals (0-1). Default 0.25 (25%).
    /// Low-fat meals get up to 80% upfront via fat-scaled lerp; this is the absolute floor for ≥50g fat.
    var v2MinUpfrontFloor: Decimal = 0.25
    /// Enable Garmin sensitivity integration.
    var garminEnabled: Bool = false
    /// Firebase project ID for Garmin Firestore.
    var garminFirebaseProjectID: String = ""
    /// Enable V2 outcome learning.
    var v2OutcomeLearningEnabled: Bool = true
    /// Enable Claude weekly recalibration.
    var claudeRecalibrationEnabled: Bool = true
    /// Analysis window for Claude recalibration (days). Options: 7, 14, 21, 30. Default 14.
    var recalibrationWindowDays: Int = 14
}

extension TrioSettings: Decodable {
    // Needed to decode incomplete JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var settings = TrioSettings()

        if let units = try? container.decode(GlucoseUnits.self, forKey: .units) {
            settings.units = units
        }

        if let closedLoop = try? container.decode(Bool.self, forKey: .closedLoop) {
            settings.closedLoop = closedLoop
        }

        if let isUploadEnabled = try? container.decode(Bool.self, forKey: .isUploadEnabled) {
            settings.isUploadEnabled = isUploadEnabled
        }

        if let isDownloadEnabled = try? container.decode(Bool.self, forKey: .isDownloadEnabled) {
            settings.isDownloadEnabled = isDownloadEnabled
        }

        if let useLocalGlucoseSource = try? container.decode(Bool.self, forKey: .useLocalGlucoseSource) {
            settings.useLocalGlucoseSource = useLocalGlucoseSource
        }

        if let localGlucosePort = try? container.decode(Int.self, forKey: .localGlucosePort) {
            settings.localGlucosePort = localGlucosePort
        }

        if let debugOptions = try? container.decode(Bool.self, forKey: .debugOptions) {
            settings.debugOptions = debugOptions
        }

        if let cgm = try? container.decode(CGMType.self, forKey: .cgm) {
            settings.cgm = cgm
        }

        if let cgmPluginIdentifier = try? container.decode(String.self, forKey: .cgmPluginIdentifier) {
            settings.cgmPluginIdentifier = cgmPluginIdentifier
        }

        if let uploadGlucose = try? container.decode(Bool.self, forKey: .uploadGlucose) {
            settings.uploadGlucose = uploadGlucose
        }

        if let useCalendar = try? container.decode(Bool.self, forKey: .useCalendar) {
            settings.useCalendar = useCalendar
        }

        if let displayCalendarIOBandCOB = try? container.decode(Bool.self, forKey: .displayCalendarIOBandCOB) {
            settings.displayCalendarIOBandCOB = displayCalendarIOBandCOB
        }

        if let displayCalendarEmojis = try? container.decode(Bool.self, forKey: .displayCalendarEmojis) {
            settings.displayCalendarEmojis = displayCalendarEmojis
        }

        if let useAppleHealth = try? container.decode(Bool.self, forKey: .useAppleHealth) {
            settings.useAppleHealth = useAppleHealth
        }

        if let writeNutritionToHealth = try? container.decode(Bool.self, forKey: .writeNutritionToHealth) {
            settings.writeNutritionToHealth = writeNutritionToHealth
        }

        if let readNutritionFromHealth = try? container.decode(Bool.self, forKey: .readNutritionFromHealth) {
            settings.readNutritionFromHealth = readNutritionFromHealth
        }

        if let healthMetricsSettings = try? container.decode(HealthMetricsSettings.self, forKey: .healthMetricsSettings) {
            settings.healthMetricsSettings = healthMetricsSettings
        }

        if let glucoseBadge = try? container.decode(Bool.self, forKey: .glucoseBadge) {
            settings.glucoseBadge = glucoseBadge
        }

        if let useFPUconversion = try? container.decode(Bool.self, forKey: .useFPUconversion) {
            settings.useFPUconversion = useFPUconversion
        }

        if let individualAdjustmentFactor = try? container.decode(Decimal.self, forKey: .individualAdjustmentFactor) {
            settings.individualAdjustmentFactor = individualAdjustmentFactor
        }

        if let fattyMeals = try? container.decode(Bool.self, forKey: .fattyMeals) {
            settings.fattyMeals = fattyMeals
        }

        if let fattyMealFactor = try? container.decode(Decimal.self, forKey: .fattyMealFactor) {
            settings.fattyMealFactor = fattyMealFactor
        }

        if let sweetMeals = try? container.decode(Bool.self, forKey: .sweetMeals) {
            settings.sweetMeals = sweetMeals
        }

        if let sweetMealFactor = try? container.decode(Decimal.self, forKey: .sweetMealFactor) {
            settings.sweetMealFactor = sweetMealFactor
        }

        if let overrideFactor = try? container.decode(Decimal.self, forKey: .overrideFactor) {
            settings.overrideFactor = overrideFactor
        }

        if let timeCap = try? container.decode(Decimal.self, forKey: .timeCap) {
            settings.timeCap = timeCap
        }

        if let minuteInterval = try? container.decode(Decimal.self, forKey: .minuteInterval) {
            settings.minuteInterval = minuteInterval
        }

        if let delay = try? container.decode(Decimal.self, forKey: .delay) {
            settings.delay = delay
        }

        if let notificationsPump = try? container.decode(Bool.self, forKey: .notificationsPump) {
            settings.notificationsPump = notificationsPump
        }

        if let notificationsCgm = try? container.decode(Bool.self, forKey: .notificationsCgm) {
            settings.notificationsCgm = notificationsCgm
        }

        if let notificationsCarb = try? container.decode(Bool.self, forKey: .notificationsCarb) {
            settings.notificationsCarb = notificationsCarb
        }

        if let notificationsAlgorithm = try? container.decode(Bool.self, forKey: .notificationsAlgorithm) {
            settings.notificationsAlgorithm = notificationsAlgorithm
        }

        if let glucoseNotificationsOption = try? container.decode(
            GlucoseNotificationsOption.self,
            forKey: .glucoseNotificationsOption
        ) {
            settings.glucoseNotificationsOption = glucoseNotificationsOption
        }

        if let addSourceInfoToGlucoseNotifications = try? container.decode(
            Bool.self,
            forKey: .addSourceInfoToGlucoseNotifications
        ) {
            settings.addSourceInfoToGlucoseNotifications = addSourceInfoToGlucoseNotifications
        }

        if let lowGlucose = try? container.decode(Decimal.self, forKey: .lowGlucose) {
            settings.lowGlucose = lowGlucose
        }

        if let highGlucose = try? container.decode(Decimal.self, forKey: .highGlucose) {
            settings.highGlucose = highGlucose
        }

        if let carbsRequiredThreshold = try? container.decode(Decimal.self, forKey: .carbsRequiredThreshold) {
            settings.carbsRequiredThreshold = carbsRequiredThreshold
        }

        if let showCarbsRequiredBadge = try? container.decode(Bool.self, forKey: .showCarbsRequiredBadge) {
            settings.showCarbsRequiredBadge = showCarbsRequiredBadge
        }

        if let smoothGlucose = try? container.decode(Bool.self, forKey: .smoothGlucose) {
            settings.smoothGlucose = smoothGlucose
        }

        if let low = try? container.decode(Decimal.self, forKey: .low) {
            settings.low = low
        }

        if let high = try? container.decode(Decimal.self, forKey: .high) {
            settings.high = high
        }

        if let glucoseColorScheme = try? container.decode(GlucoseColorScheme.self, forKey: .glucoseColorScheme) {
            settings.glucoseColorScheme = glucoseColorScheme
        }

        if let xGridLines = try? container.decode(Bool.self, forKey: .xGridLines) {
            settings.xGridLines = xGridLines
        }

        if let yGridLines = try? container.decode(Bool.self, forKey: .yGridLines) {
            settings.yGridLines = yGridLines
        }

        if let rulerMarks = try? container.decode(Bool.self, forKey: .rulerMarks) {
            settings.rulerMarks = rulerMarks
        }

        if let forecastDisplayType = try? container.decode(ForecastDisplayType.self, forKey: .forecastDisplayType) {
            settings.forecastDisplayType = forecastDisplayType
        }

        if let eA1cDisplayUnit = try? container.decode(EstimatedA1cDisplayUnit.self, forKey: .eA1cDisplayUnit) {
            settings.eA1cDisplayUnit = eA1cDisplayUnit
        }

        if let maxCarbs = try? container.decode(Decimal.self, forKey: .maxCarbs) {
            settings.maxCarbs = maxCarbs
        }

        if let maxFat = try? container.decode(Decimal.self, forKey: .maxFat) {
            settings.maxFat = maxFat
        }

        if let maxProtein = try? container.decode(Decimal.self, forKey: .maxProtein) {
            settings.maxProtein = maxProtein
        }

        if let confirmBolusFaster = try? container.decode(Bool.self, forKey: .confirmBolusFaster) {
            settings.confirmBolusFaster = confirmBolusFaster
        }

        if let displayPresets = try? container.decode(Bool.self, forKey: .displayPresets) {
            settings.displayPresets = displayPresets
        }

        if let confirmBolus = try? container.decode(Bool.self, forKey: .confirmBolus) {
            settings.confirmBolus = confirmBolus
        }

        if let useLiveActivity = try? container.decode(Bool.self, forKey: .useLiveActivity) {
            settings.useLiveActivity = useLiveActivity
        }

        if let lockScreenView = try? container.decode(LockScreenView.self, forKey: .lockScreenView) {
            settings.lockScreenView = lockScreenView
        }

        if let smartStackView = try? container.decode(LockScreenView.self, forKey: .smartStackView) {
            settings.smartStackView = smartStackView
        }

        if let bolusShortcut = try? container.decode(BolusShortcutLimit.self, forKey: .bolusShortcut) {
            settings.bolusShortcut = bolusShortcut
        }

        if let timeInRangeType = try? container.decode(TimeInRangeType.self, forKey: .timeInRangeType) {
            settings.timeInRangeType = timeInRangeType
        }

        // V2 Macro Absorption Engine settings
        if let useV2MacroAbsorption = try? container.decode(Bool.self, forKey: .useV2MacroAbsorption) {
            settings.useV2MacroAbsorption = useV2MacroAbsorption
        }
        if let insulinType = try? container.decode(String.self, forKey: .insulinType) {
            settings.insulinType = insulinType
        }
        if let v2SafeWindowMinutes = try? container.decode(Int.self, forKey: .v2SafeWindowMinutes) {
            settings.v2SafeWindowMinutes = v2SafeWindowMinutes
        }
        if let mealModeSMBMultiplier = try? container.decode(Decimal.self, forKey: .mealModeSMBMultiplier) {
            settings.mealModeSMBMultiplier = mealModeSMBMultiplier
        }
        if let mealModeBGFloor = try? container.decode(Decimal.self, forKey: .mealModeBGFloor) {
            settings.mealModeBGFloor = mealModeBGFloor
        }
        if let v2MinUpfrontFloor = try? container.decode(Decimal.self, forKey: .v2MinUpfrontFloor) {
            settings.v2MinUpfrontFloor = v2MinUpfrontFloor
        }
        if let garminEnabled = try? container.decode(Bool.self, forKey: .garminEnabled) {
            settings.garminEnabled = garminEnabled
        }
        if let garminFirebaseProjectID = try? container.decode(String.self, forKey: .garminFirebaseProjectID) {
            settings.garminFirebaseProjectID = garminFirebaseProjectID
        }
        if let v2OutcomeLearningEnabled = try? container.decode(Bool.self, forKey: .v2OutcomeLearningEnabled) {
            settings.v2OutcomeLearningEnabled = v2OutcomeLearningEnabled
        }
        if let claudeRecalibrationEnabled = try? container.decode(Bool.self, forKey: .claudeRecalibrationEnabled) {
            settings.claudeRecalibrationEnabled = claudeRecalibrationEnabled
        }
        if let recalibrationWindowDays = try? container.decode(Int.self, forKey: .recalibrationWindowDays) {
            settings.recalibrationWindowDays = recalibrationWindowDays
        }

        self = settings
    }
}
