import Foundation

enum BolusShortcutLimit: String, JSON, CaseIterable, Identifiable {
    var id: String { rawValue }
    case notAllowed
    case limitWithSafetyChecks

    var displayName: String {
        switch self {
        case .notAllowed:
            return String(localized: "Not allowed")
        case .limitWithSafetyChecks:
            return String(localized: "Limit with Safety Checks")
        }
    }
}

struct TrioSettings: JSON, Equatable, Encodable {
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
    var useFPUconversion: Bool = false
    var individualAdjustmentFactor: Decimal = 0.5
    var minuteInterval: Decimal = 30
    var delay: Decimal = 60
    var useAppleHealth: Bool = false
    var readNutritionFromHealth: Bool = false
    var healthMetricsSettings: HealthMetricsSettings = HealthMetricsSettings()
    var smoothGlucose: Bool = false
    var eA1cDisplayUnit: EstimatedA1cDisplayUnit = .percent
    var high: Decimal = 180
    var low: Decimal = 70
    var glucoseColorScheme: GlucoseColorScheme = .staticColor
    var xGridLines: Bool = true
    var yGridLines: Bool = true
    var hideInsulinBadge: Bool = false
    var allowDilution: Bool = false
    var insulinConcentration: Decimal = 1
    var showCobIobChart: Bool = true
    var rulerMarks: Bool = true
    var bolusDisplayThreshold: BolusDisplayThreshold = .allUnits
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
    var toughMeals: Bool = false
    var toughMealDuration: Decimal = 7 // hours
    var toughMealActivationDate: Date? = nil
    var toughMealStartingBG: Decimal = 0
    var toughMealIOBAtDose: Decimal = 0
    var toughMealFatPlusProtein: Decimal = 0
    var toughMealAutoDetected: Bool = false

    // Meal-window state, set by AnnounceMealIntent ("I'm eating now" Action Button).
    // Active from activation until activation + mealWindowDurationMinutes, then auto-expires.
    var mealWindowActivationDate: Date? = nil
    var mealWindowDurationMinutes: Decimal = 90
    var mealWindowExtendedDurationMinutes: Decimal = 240
    var mealWindowEstimatedCarbs: Decimal = 0
    var mealWindowCarbsConfirmed: Bool = false
    /// Stable identifier for the currently-active meal window. Set on activation, read
    /// by every site that logs telemetry events so all events for one window can be joined.
    var mealWindowId: String? = nil

    // Eating-mode tuning knobs — control how aggressively the loop treats a rise
    // while a meal window is active. See PLAN.md on the telemetry branch.
    var mealWindowBoostSMBRatio: Bool = true               // item 1: bump SMB ratio
    var mealWindowSMBRatioValue: Decimal = 0.8             // item 1: ratio used (0.5-1.0)
    var mealWindowRelaxRisingGuard: Bool = true            // item 2: floor allows delta > -2
    var mealWindowAdditiveFloor: Bool = false              // item 3: insReq = insReq + floor
    var mealWindowForceUAM: Bool = true                    // item 4: force enableUAM in window
    var mealWindowPhantomCOB: Bool = false                 // item 5: synthesize phantom COB
    var mealWindowPhantomCOBGrams: Decimal = 20            // item 5: amount to synthesize
    var mealWindowSMBMinutesMultiplier: Decimal = 2.0      // item 6: multiply maxSMBBasalMinutes
    var mealWindowToughMealCapPercent: Decimal = 75        // configurable tough-meal cap (50-100)

    // Meal classifier (Phase A of MEAL_INTELLIGENCE_DESIGN.md) — three-phase rule
    // upgrades the window classification mid-flight when a late-fat-onset pattern
    // is detected. Upgrade-only, never downgrades. All knobs exposed in the new
    // Settings → Meals → Classification Rules screen.
    var mealClassifierEnabled: Bool = true
    var mealCurrentClassification: MealClassification = .simple
    var mealClassifierUpgradedAt: Date? = nil
    /// Activation BG captured at window open, used as the Phase 2 baseline reference
    /// alongside the post-Phase-1 trough.
    var mealClassifierActivationBG: Double? = nil
    var mealClassifierPhase1ConfirmedAt: Date? = nil
    var mealClassifierPhase1Trough: Double? = nil
    var mealClassifierPhase2ConfirmedAt: Date? = nil
    /// Maximum total window duration the classifier is allowed to extend to,
    /// from activation (not from upgrade trigger). Per design Q1 recommendation:
    /// on Complex upgrade we push to this max for full overnight coverage.
    var mealClassifierMaxTotalDurationMinutes: Decimal = 600
    var mealClassifierPhase1DeltaThreshold: Decimal = 2          // mg/dL/5min
    var mealClassifierPhase1SustainedReadings: Decimal = 3       // count
    var mealClassifierPhase1AbsoluteRiseMgdL: Decimal = 15
    var mealClassifierPhase2RangeMgdL: Decimal = 20              // ±N from baseline
    var mealClassifierPhase2MinDurationMinutes: Decimal = 30
    var mealClassifierPhase3DeltaThreshold: Decimal = 2
    var mealClassifierPhase3SustainedDurationMinutes: Decimal = 15
    var mealClassifierPhase3CarbExclusionMinutes: Decimal = 30
    var mealClassifierPhantomCOBGramsOnUpgrade: Decimal = 20

    /// Optional link to the SavedMeal that started the current window. Lets us
    /// fetch the live instance row to backfill metrics at window close.
    /// Both nil for windows started from "Quick (auto-classify)".
    var mealWindowSavedMealId: String? = nil
    var mealWindowSavedMealInstanceId: String? = nil

    /// When true, saved-meal names are stripped from telemetry uploads
    /// (replaced with `null`; the UUID still uniquely identifies the meal).
    /// See MEAL_INTELLIGENCE_DESIGN.md §7.5.
    var telemetryAnonymizeMealNames: Bool = false

    // Telemetry — auto-pushes meal-window data + loop decisions to a private branch
    // on the trio repo for tuning analysis. PAT is in Keychain, not here.
    var telemetryEnabled: Bool = false
    var telemetryRepo: String = "zgoettsc/trio"
    var telemetryBranch: String = "telemetry"
    var telemetryLastSuccessfulPushDate: Date? = nil
    var telemetryLastError: String? = nil
    var telemetryLastRemoteCleanupDate: Date? = nil

    var displayPresets: Bool = true
    var confirmBolus: Bool = false
    var useLiveActivity: Bool = false
    var lockScreenView: LockScreenView = .simple
    var smartStackView: LockScreenView = .simple
    var bolusShortcut: BolusShortcutLimit = .notAllowed
    var timeInRangeType: TimeInRangeType = .timeInTightRange
    var smartSenseSettings: SmartSenseSettings = SmartSenseSettings()
    var requireAdjustmentsConfirmation: Bool = false

    /// Selected Garmin watchface (Trio or SwissAlpine)
    var garminWatchface: GarminWatchface = .trio
    var garminDatafield: GarminDatafield = .none

    /// Primary attribute choice for Garmin display (COB, ISF, or Sensitivity Ratio)
    var primaryAttributeChoice: GarminPrimaryAttributeChoice = .cob

    /// Secondary attribute choice for Garmin display (TBR or Eventual BG)
    var secondaryAttributeChoice: GarminSecondaryAttributeChoice = .tbr

    /// Controls whether watchface data transmission is enabled
    var isWatchfaceDataEnabled: Bool = false

    /// Computed property that groups all Garmin settings into a single struct
    var garminSettings: GarminWatchSettings {
        get {
            GarminWatchSettings(
                watchface: garminWatchface,
                datafield: garminDatafield,
                primaryAttributeChoice: primaryAttributeChoice,
                secondaryAttributeChoice: secondaryAttributeChoice,
                isWatchfaceDataEnabled: isWatchfaceDataEnabled
            )
        }
        set {
            garminWatchface = newValue.watchface
            garminDatafield = newValue.datafield
            primaryAttributeChoice = newValue.primaryAttributeChoice
            secondaryAttributeChoice = newValue.secondaryAttributeChoice
            isWatchfaceDataEnabled = newValue.isWatchfaceDataEnabled
        }
    }
}

extension TrioSettings: Decodable {
    /// Custom decoder to handle incomplete JSON and provide default values for missing fields
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

        if let toughMeals = try? container.decode(Bool.self, forKey: .toughMeals) {
            settings.toughMeals = toughMeals
        }

        if let toughMealDuration = try? container.decode(Decimal.self, forKey: .toughMealDuration) {
            settings.toughMealDuration = toughMealDuration
        }

        if let toughMealActivationDate = try? container.decode(Date.self, forKey: .toughMealActivationDate) {
            settings.toughMealActivationDate = toughMealActivationDate
        }

        if let toughMealStartingBG = try? container.decode(Decimal.self, forKey: .toughMealStartingBG) {
            settings.toughMealStartingBG = toughMealStartingBG
        }

        if let toughMealIOBAtDose = try? container.decode(Decimal.self, forKey: .toughMealIOBAtDose) {
            settings.toughMealIOBAtDose = toughMealIOBAtDose
        }

        if let toughMealFatPlusProtein = try? container.decode(Decimal.self, forKey: .toughMealFatPlusProtein) {
            settings.toughMealFatPlusProtein = toughMealFatPlusProtein
        }

        if let toughMealAutoDetected = try? container.decode(Bool.self, forKey: .toughMealAutoDetected) {
            settings.toughMealAutoDetected = toughMealAutoDetected
        }

        if let mealWindowActivationDate = try? container.decode(Date.self, forKey: .mealWindowActivationDate) {
            settings.mealWindowActivationDate = mealWindowActivationDate
        }

        if let mealWindowDurationMinutes = try? container.decode(Decimal.self, forKey: .mealWindowDurationMinutes) {
            settings.mealWindowDurationMinutes = mealWindowDurationMinutes
        }

        if let mealWindowExtendedDurationMinutes = try? container.decode(
            Decimal.self,
            forKey: .mealWindowExtendedDurationMinutes
        ) {
            settings.mealWindowExtendedDurationMinutes = mealWindowExtendedDurationMinutes
        }

        if let mealWindowEstimatedCarbs = try? container.decode(Decimal.self, forKey: .mealWindowEstimatedCarbs) {
            settings.mealWindowEstimatedCarbs = mealWindowEstimatedCarbs
        }

        if let mealWindowCarbsConfirmed = try? container.decode(Bool.self, forKey: .mealWindowCarbsConfirmed) {
            settings.mealWindowCarbsConfirmed = mealWindowCarbsConfirmed
        }
        if let mealWindowId = try? container.decode(String.self, forKey: .mealWindowId) {
            settings.mealWindowId = mealWindowId
        }

        // Eating-mode tuning
        if let v = try? container.decode(Bool.self, forKey: .mealWindowBoostSMBRatio) {
            settings.mealWindowBoostSMBRatio = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealWindowSMBRatioValue) {
            settings.mealWindowSMBRatioValue = v
        }
        if let v = try? container.decode(Bool.self, forKey: .mealWindowRelaxRisingGuard) {
            settings.mealWindowRelaxRisingGuard = v
        }
        if let v = try? container.decode(Bool.self, forKey: .mealWindowAdditiveFloor) {
            settings.mealWindowAdditiveFloor = v
        }
        if let v = try? container.decode(Bool.self, forKey: .mealWindowForceUAM) {
            settings.mealWindowForceUAM = v
        }
        if let v = try? container.decode(Bool.self, forKey: .mealWindowPhantomCOB) {
            settings.mealWindowPhantomCOB = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealWindowPhantomCOBGrams) {
            settings.mealWindowPhantomCOBGrams = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealWindowSMBMinutesMultiplier) {
            settings.mealWindowSMBMinutesMultiplier = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealWindowToughMealCapPercent) {
            settings.mealWindowToughMealCapPercent = v
        }
        if let v = try? container.decode(Bool.self, forKey: .mealClassifierEnabled) {
            settings.mealClassifierEnabled = v
        }
        if let v = try? container.decode(MealClassification.self, forKey: .mealCurrentClassification) {
            settings.mealCurrentClassification = v
        }
        if let v = try? container.decode(Date.self, forKey: .mealClassifierUpgradedAt) {
            settings.mealClassifierUpgradedAt = v
        }
        if let v = try? container.decode(Double.self, forKey: .mealClassifierActivationBG) {
            settings.mealClassifierActivationBG = v
        }
        if let v = try? container.decode(Date.self, forKey: .mealClassifierPhase1ConfirmedAt) {
            settings.mealClassifierPhase1ConfirmedAt = v
        }
        if let v = try? container.decode(Double.self, forKey: .mealClassifierPhase1Trough) {
            settings.mealClassifierPhase1Trough = v
        }
        if let v = try? container.decode(Date.self, forKey: .mealClassifierPhase2ConfirmedAt) {
            settings.mealClassifierPhase2ConfirmedAt = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierMaxTotalDurationMinutes) {
            settings.mealClassifierMaxTotalDurationMinutes = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase1DeltaThreshold) {
            settings.mealClassifierPhase1DeltaThreshold = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase1SustainedReadings) {
            settings.mealClassifierPhase1SustainedReadings = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase1AbsoluteRiseMgdL) {
            settings.mealClassifierPhase1AbsoluteRiseMgdL = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase2RangeMgdL) {
            settings.mealClassifierPhase2RangeMgdL = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase2MinDurationMinutes) {
            settings.mealClassifierPhase2MinDurationMinutes = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase3DeltaThreshold) {
            settings.mealClassifierPhase3DeltaThreshold = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase3SustainedDurationMinutes) {
            settings.mealClassifierPhase3SustainedDurationMinutes = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhase3CarbExclusionMinutes) {
            settings.mealClassifierPhase3CarbExclusionMinutes = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .mealClassifierPhantomCOBGramsOnUpgrade) {
            settings.mealClassifierPhantomCOBGramsOnUpgrade = v
        }
        if let v = try? container.decode(String.self, forKey: .mealWindowSavedMealId) {
            settings.mealWindowSavedMealId = v
        }
        if let v = try? container.decode(String.self, forKey: .mealWindowSavedMealInstanceId) {
            settings.mealWindowSavedMealInstanceId = v
        }
        if let v = try? container.decode(Bool.self, forKey: .telemetryAnonymizeMealNames) {
            settings.telemetryAnonymizeMealNames = v
        }

        if let telemetryEnabled = try? container.decode(Bool.self, forKey: .telemetryEnabled) {
            settings.telemetryEnabled = telemetryEnabled
        }
        if let telemetryRepo = try? container.decode(String.self, forKey: .telemetryRepo) {
            settings.telemetryRepo = telemetryRepo
        }
        if let telemetryBranch = try? container.decode(String.self, forKey: .telemetryBranch) {
            settings.telemetryBranch = telemetryBranch
        }
        if let telemetryLastSuccessfulPushDate = try? container.decode(
            Date.self,
            forKey: .telemetryLastSuccessfulPushDate
        ) {
            settings.telemetryLastSuccessfulPushDate = telemetryLastSuccessfulPushDate
        }
        if let telemetryLastError = try? container.decode(String.self, forKey: .telemetryLastError) {
            settings.telemetryLastError = telemetryLastError
        }
        if let telemetryLastRemoteCleanupDate = try? container.decode(
            Date.self,
            forKey: .telemetryLastRemoteCleanupDate
        ) {
            settings.telemetryLastRemoteCleanupDate = telemetryLastRemoteCleanupDate
        }

        if let overrideFactor = try? container.decode(Decimal.self, forKey: .overrideFactor) {
            settings.overrideFactor = overrideFactor
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

        if let showCobIobChart = try? container.decode(Bool.self, forKey: .showCobIobChart) {
            settings.showCobIobChart = showCobIobChart
        }

        if let hideInsulinBadge = try? container.decode(Bool.self, forKey: .hideInsulinBadge) {
            settings.hideInsulinBadge = hideInsulinBadge
        }

        if let allowDilution = try? container.decode(Bool.self, forKey: .allowDilution) {
            settings.allowDilution = allowDilution
        }

        if let insulinConcentration = try? container.decode(Decimal.self, forKey: .insulinConcentration) {
            settings.insulinConcentration = insulinConcentration
        }

        if let rulerMarks = try? container.decode(Bool.self, forKey: .rulerMarks) {
            settings.rulerMarks = rulerMarks
        }

        if let bolusDisplayThreshold = try? container.decode(BolusDisplayThreshold.self, forKey: .bolusDisplayThreshold) {
            settings.bolusDisplayThreshold = bolusDisplayThreshold
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

        if let smartSenseSettings = try? container.decode(SmartSenseSettings.self, forKey: .smartSenseSettings) {
            settings.smartSenseSettings = smartSenseSettings
        }

        if let requireAdjustmentsConfirmation = try? container.decode(Bool.self, forKey: .requireAdjustmentsConfirmation) {
            settings.requireAdjustmentsConfirmation = requireAdjustmentsConfirmation
        }

        if let garminWatchface = try? container.decode(GarminWatchface.self, forKey: .garminWatchface) {
            settings.garminWatchface = garminWatchface
        }

        if let garminDatafield = try? container.decode(GarminDatafield.self, forKey: .garminDatafield) {
            settings.garminDatafield = garminDatafield
        }

        if let primaryAttributeChoice = try? container
            .decode(GarminPrimaryAttributeChoice.self, forKey: .primaryAttributeChoice)
        {
            settings.primaryAttributeChoice = primaryAttributeChoice
        }

        if let secondaryAttributeChoice = try? container.decode(
            GarminSecondaryAttributeChoice.self,
            forKey: .secondaryAttributeChoice
        ) {
            settings.secondaryAttributeChoice = secondaryAttributeChoice
        }

        if let isWatchfaceDataEnabled = try? container.decode(Bool.self, forKey: .isWatchfaceDataEnabled) {
            settings.isWatchfaceDataEnabled = isWatchfaceDataEnabled
        }

        self = settings
    }
}
