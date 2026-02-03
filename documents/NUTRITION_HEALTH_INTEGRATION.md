# Apple Health Nutrition Integration (Cronometer)

## Overview

This document describes the implementation of Apple Health nutrition data integration in Trio. The feature enables Trio to read nutrition data (carbs, fat, protein) written to Apple Health by external apps like Cronometer, display it in an informational view, and run retroactive analysis comparing Trio's manual carb entries against actual nutrition data to understand carb estimation patterns.

## Motivation

Many Trio users log their food in a dedicated nutrition app (e.g., Cronometer) that syncs to Apple Health. These apps provide accurate, weighed nutrition data — but users also manually enter carb estimates into Trio for bolus calculations. Over time, a systematic gap develops between the rough carb estimates in Trio and the precise nutritional data in Cronometer. Understanding this gap is critical because:

- **ICR calibration**: If a user consistently enters 50g when the actual amount is 121g, their ICR is calibrated to the *estimated* carbs, not real carbs.
- **Future automation**: If Trio eventually reads carbs from Apple Health for dosing, the ICR would need to be recalibrated to match actual carb values.
- **Self-awareness**: Simply seeing the gap helps users understand their carb counting habits.

## Key Design Decision: Day-Based Grouping

**Problem:** Cronometer writes all Apple Health nutrition entries with midnight (00:00) timestamps. This is a known, long-standing Cronometer limitation — even Cronometer Gold subscriptions do not write per-meal timestamps to Apple Health.

**Solution:** All nutrition data is grouped and compared at the *daily* level rather than per-meal. This means:
- Nutrition preview shows daily totals (not individual meals)
- Analysis compares daily Trio carb totals vs daily Cronometer totals
- BG data is summarized as daily averages and daily maximums

## Safety: Complete Isolation from Dosing

The nutrition reading feature is **strictly informational**. Apple Health nutrition data does NOT feed into:
- COB (Carbs on Board) calculations — COB comes from `CarbsStorage` (CoreData) via the oref algorithm
- Bolus calculator — uses COB from oref `Determination` plus manually entered carbs, divided by ICR
- Any dosing logic whatsoever

`NutritionHealthService` has zero references to `CarbsStorage`, `CarbEntryStored`, CoreData, or any dosing-related code. The data flows one way: Apple Health -> display only.

---

## Implementation History

### Phase 1A: Core Nutrition Reading & Display

**Date:** January 2026

**Changes:**
- Added granular nutrition sync toggles (write/read independently)
- Implemented HealthKit nutrition reading service
- Created daily nutrition display in Apple Health settings
- Filters out Trio's own entries to avoid double-counting

#### New Files Created:

1. **`Trio/Sources/Models/HealthNutrition.swift`**
   - `HealthNutritionEntry` — individual nutrition sample (carbs, fat, protein, calories, source, date)
   - `HealthNutritionDay` — all entries for a calendar day, aggregated
   - Computed properties: `totalCarbs`, `totalFat`, `totalProtein`, `totalCalories`, `entryCount`
   - Macro percentage calculations: `carbPercentage`, `fatPercentage`, `proteinPercentage`
   - `dayDescription` — "Today", "Yesterday", or formatted date string
   - `typealias HealthNutritionMeal = HealthNutritionDay` for backward compatibility

2. **`Trio/Sources/Services/HealthKit/NutritionHealthService.swift`**
   - Protocol: `NutritionHealthService` with `fetchMeals(from:to:)` method
   - Implementation: `BaseNutritionHealthService`
   - Reads `dietaryCarbohydrates`, `dietaryFatTotal`, `dietaryProtein` from HealthKit
   - Filters out Trio entries by bundle ID prefix `org.nightscout`
   - Merges carb/fat/protein samples by 2-second timestamp window (for entries written simultaneously)
   - Groups entries by calendar day using `Calendar.startOfDay(for:)`
   - Includes metadata debug logging for investigating source app behavior

#### Modified Files:

3. **`Trio/Sources/Models/TrioSettings.swift`**
   - Added `writeNutritionToHealth: Bool = true` — controls whether Trio writes nutrition to Apple Health
   - Added `readNutritionFromHealth: Bool = false` — controls whether Trio reads nutrition from Apple Health
   - Added `Decodable` support for new fields

4. **`Trio/Sources/Services/HealthKit/HealthKitManager.swift`**
   - Added `nutritionReadPermissions` to `AppleHealthConfig` — read permissions for carbs, fat, protein
   - `requestPermission()` conditionally requests nutrition read permissions when `readNutritionFromHealth` is enabled
   - `uploadCarbs()` gated on `writeNutritionToHealth` toggle (prevents writes when Cronometer is source of truth)

5. **`Trio/Sources/Modules/HealthKit/HealthKitStateModel.swift`**
   - Added `@Injected() var nutritionHealthService: NutritionHealthService!`
   - Added `@Published` properties: `writeNutritionToHealth`, `readNutritionFromHealth`, `recentMeals`, `isLoadingNutrition`
   - Subscribes to new settings via `subscribeSetting`
   - Requests nutrition permissions on toggle change
   - `fetchRecentNutrition()` fetches last 7 days of nutrition data

6. **`Trio/Sources/Modules/HealthKit/View/AppleHealthKitRootView.swift`**
   - Added "Nutrition Data" section with explanatory text
   - Added "Nutrition Sync" section with write/read toggles
   - Added "Daily Nutrition" section showing per-day nutrition with:
     - Day name, entry count, source app badge
     - Macro totals (C/F/P in grams)
     - Calorie total
     - Color-coded macro percentage bar (carbs=orange, fat=yellow, protein=red)
   - Added "Insights" section with NavigationLink to Nutrition Analysis view
   - Helper views: `dailyNutritionRow()`, `macroLabel()`, `macroPercentageBar()`

7. **`Trio/Sources/Assemblies/ServiceAssembly.swift`**
   - Registered `NutritionHealthService` → `BaseNutritionHealthService`

8. **`Trio.xcodeproj/project.pbxproj`**
   - Added PBXFileReference, PBXBuildFile, PBXGroup, and PBXSourcesBuildPhase entries for `HealthNutrition.swift` and `NutritionHealthService.swift`

---

### Phase 1B: Retroactive Nutrition Analysis

**Date:** January 2026

**Changes:**
- Added analysis service that compares Trio carb entries vs Cronometer daily totals
- Created analysis view showing estimation accuracy, ICR analysis, BG outcomes
- Added share/export button for sharing reports

#### New Files Created:

1. **`Trio/Sources/Models/NutritionAnalysis.swift`**
   - `MatchedMealAnalysis` — a single matched day with both Trio and Cronometer data:
     - Daily Trio totals: `trioCarbs`, `trioFat`, `trioProtein`
     - Daily Cronometer totals: `actualCarbs`, `actualFat`, `actualProtein`
     - Daily bolus insulin total (non-SMB): `bolusInsulin`
     - Daily BG summary: `bgAtMeal` (daily avg), `bgPeak` (daily max)
     - Computed: `estimationRatio`, `missedCarbs`, `effectiveICR`, `apparentICR`
     - Computed: `averageBG`, `maxBG`, `dayDescription`
     - Computed: `actualCarbPercent`, `actualFatPercent`, `actualProteinPercent`
   - `NutritionAnalysisSummary` — aggregate statistics across all matched days:
     - Matching info: `totalMatchedDays`, `unmatchedTrioDays`, `unmatchedHealthDays`, `analysisPeriodDays`
     - Estimation accuracy: `averageEstimationRatio`, `medianEstimationRatio`, `minEstimationRatio`, `maxEstimationRatio`
     - Carb counting: `averageMissedCarbs`, `totalMissedCarbs`, `averageTrioCarbs`, `averageActualCarbs`
     - ICR analysis: `averageApparentICR`, `averageEffectiveICR`, `suggestedICRAdjustment`
     - BG summary: `averageDailyBG`, `averageDailyMaxBG`
     - Computed: `estimationDescription`, `suggestedICRDescription`

2. **`Trio/Sources/Services/HealthKit/NutritionAnalysisService.swift`**
   - Protocol: `NutritionAnalysisService` with `runAnalysis(days:)` returning `(days:summary:)` tuple
   - Implementation: `BaseNutritionAnalysisService`
   - Fetches from multiple sources in parallel using `async let`:
     - Apple Health nutrition days (via `NutritionHealthService`)
     - Trio carb entries from CoreData (`CarbEntryStored`, excluding FPU entries)
     - Glucose readings from CoreData (`GlucoseStored`)
     - Bolus events from CoreData (`BolusStored` via `PumpEventStored.timestamp`)
   - `matchByDay()` — groups Trio entries by calendar day, matches against Apple Health daily totals
   - For each matched day: computes daily average BG, daily max BG, total non-SMB bolus
   - `computeSummary()` — calculates all aggregate statistics including median estimation ratio
   - Private data types: `TrioCarbRecord`, `BGReading`, `BolusRecord`

3. **`Trio/Sources/Modules/HealthKit/View/NutritionAnalysisView.swift`**
   - Full analysis display view with sections:
     - **Summary**: estimation accuracy headline, stats grid (matched days, avg ratio, avg entered/actual, avg missed, median ratio), estimation range
     - **ICR Analysis**: current ICR vs true ICR, adjustment factor for switching to actual carbs
     - **Glucose Outcomes**: avg daily BG and avg daily max BG with color coding
     - **Daily Comparison**: per-day rows showing entered/actual/missed carbs, ratio, bolus, macro split, avg/max BG
   - "Run Analysis" button triggers async analysis for configurable period (default 14 days)
   - Refresh button in toolbar to re-run analysis
   - **Share/Export button** in toolbar — generates plain text report and presents iOS share sheet
   - Report includes: estimation accuracy, ICR analysis, glucose outcomes, data coverage, daily breakdown table
   - `ShareSheet` — `UIViewControllerRepresentable` wrapping `UIActivityViewController`

#### Modified Files:

4. **`Trio/Sources/Router/Screen.swift`**
   - Added `case nutritionAnalysis` to `Screen` enum
   - Added view builder case returning `NutritionAnalysisView(resolver: resolver)`

5. **`Trio/Sources/Assemblies/ServiceAssembly.swift`**
   - Registered `NutritionAnalysisService` → `BaseNutritionAnalysisService`

6. **`Trio.xcodeproj/project.pbxproj`**
   - Added PBXFileReference, PBXBuildFile, PBXGroup, and PBXSourcesBuildPhase entries for `NutritionAnalysis.swift`, `NutritionAnalysisService.swift`, and `NutritionAnalysisView.swift`

---

### Phase 1C: Low Treatment Detection & Real-Time Nutrition Monitoring

**Date:** February 2026

**Changes:**
- Added low BG episode detection with trend analysis and recovery tracking
- Estimated treatment carbs are subtracted from Cronometer totals for accurate meal-carb comparison
- Added HKObserverQuery for real-time nutrition change detection (infers meal times from snapshot deltas)
- Analysis view shows low treatment patterns: over-correction rate, avg nadir, recovery rise, etc.
- Export report includes low treatment and adjusted sections

#### New Files Created:

1. **`Trio/Sources/Models/NutritionSnapshot.swift`**
   - `NutritionSnapshot` — point-in-time cumulative nutrition totals from Apple Health for a given day
   - `InferredMealEvent` — meal event derived from delta between consecutive snapshots (approximate meal timing)
   - `LowEpisode` — detected low BG episode with full recovery tracking:
     - `startTime`, `nadirTime`, `nadirBG` — when and how low
     - `recoveryTime`, `recoveryBG` — when BG returned above threshold
     - `peakAfterTime`, `peakAfterBG` — highest BG within 3h of nadir (over-correction detection)
     - Computed: `overCorrected` (peak > 180), `recoveryRise`, `durationMinutes`
   - `LowTreatmentSummary` — aggregate stats across all episodes:
     - `totalEpisodes`, `episodesPerDay`, `averageNadir`, `averageDurationMinutes`
     - `overCorrectionCount`, `overCorrectionRate`, `averageRecoveryRise`, `averagePeakAfterLow`
     - `estimatedDailyTreatmentCarbs`, `correctionPattern` (human-readable)
   - `NutritionSnapshotStore` — singleton file-based persistence for snapshots (JSON, 14-day retention)
     - `saveSnapshot()`, `loadSnapshots()`, `snapshotsForDate()`
     - `inferredMealEvents(for:)` — derives meal timing from snapshot deltas

#### Modified Files:

2. **`Trio/Sources/Models/NutritionAnalysis.swift`**
   - `MatchedMealAnalysis` — added:
     - `lowEpisodes: [LowEpisode]` — detected low episodes for the day
     - `estimatedTreatmentCarbs: Double` — estimated carbs consumed to treat lows
     - Computed: `adjustedActualCarbs` (actual minus treatment), `adjustedEstimationRatio`, `adjustedMissedCarbs`
   - `NutritionAnalysisSummary` — added:
     - `lowTreatmentSummary: LowTreatmentSummary?` — aggregate low treatment stats
     - `adjustedAverageEstimationRatio: Double?` — ratio excluding low treatment carbs
     - `adjustedAverageActualCarbs: Double?` — meal-only actual carbs
     - Computed: `adjustedEstimationDescription`

3. **`Trio/Sources/Services/HealthKit/NutritionAnalysisService.swift`**
   - Added `detectLowEpisodes()` — scans glucose readings for low episodes:
     - Detects BG below `lowGlucose` setting threshold (default 72 mg/dL)
     - Also detects "trending low" — BG < threshold+10 AND dropping > 1 mg/dL/min
     - Tracks nadir, recovery, and 3-hour post-nadir peak for over-correction detection
     - Handles episodes that don't recover by end of day
   - Added `estimateTreatmentCarbs()` — estimates carbs per episode from BG recovery magnitude:
     - Uses ~4 mg/dL rise per gram of fast carbs heuristic
     - Clamped to 8-60g range, defaults to 15g if no recovery data
   - Updated `matchByDay()` to detect low episodes per day and compute treatment carbs
   - Updated `computeSummary()` to produce `LowTreatmentSummary` and adjusted ratios

4. **`Trio/Sources/Services/HealthKit/NutritionHealthService.swift`**
   - Protocol: added `startObservingNutritionChanges()`, `stopObservingNutritionChanges()`, `inferredMealEvents(for:)`
   - Implementation: `HKObserverQuery` on `dietaryCarbohydrates` with `enableBackgroundDelivery(.immediate)`
   - On notification: queries today's cumulative totals, saves `NutritionSnapshot`
   - Records initial snapshot when observation starts
   - `inferredMealEvents(for:)` delegates to `NutritionSnapshotStore`

5. **`Trio/Sources/Modules/HealthKit/HealthKitStateModel.swift`**
   - Starts nutrition observer when `readNutritionFromHealth` is toggled on
   - Stops observer when toggled off
   - Starts observer on initial load if reading is already enabled

6. **`Trio/Sources/Modules/HealthKit/View/NutritionAnalysisView.swift`**
   - Added "Low BG Treatment Analysis" section showing:
     - Correction pattern headline (over-correction/mixed/good)
     - Stats grid: total episodes, per day, avg nadir, avg duration, avg rise, avg peak
     - Estimated daily treatment carbs
     - Over-correction count and warning
   - Summary section now shows adjusted ratio when low treatments detected
   - Daily rows show low episode count badge, "Low Tx" column, adjusted missed carbs
   - Export report includes: adjusted estimation section, low treatment patterns section, expanded daily breakdown with low tx and low count columns

7. **`Trio.xcodeproj/project.pbxproj`**
   - Added PBXFileReference, PBXBuildFile, PBXGroup, and PBXSourcesBuildPhase entries for `NutritionSnapshot.swift`

---

### Phase 1D: Low Episode Classification & Setting Recommendations

**Date:** February 2026

**Changes:**
- Each low BG episode is now classified by probable cause: exercise, post-bolus, fasting/basal, or mixed
- Workouts are fetched from HealthKit and correlated with low episodes (workout within 4h of low)
- Bolus history is correlated with low episodes (non-SMB bolus within 1-4h of low)
- Fasting/basal lows are identified when no recent exercise or bolus explains the low
- Guardrailed setting recommendations are generated based on the cause breakdown
- Analysis view shows visual cause breakdown with proportional bars and daily cause badges
- Export report includes cause breakdown section and detailed recommendations

#### Modified Files:

1. **`Trio/Sources/Models/NutritionSnapshot.swift`**
   - Added `LowEpisodeCause` enum: `.exercise`, `.postBolus`, `.fasting`, `.mixed`, `.unknown`
     - Each case has `displayName` and `emoji` computed properties
   - `LowEpisode` — added fields:
     - `cause: LowEpisodeCause` — classified cause of the low
     - `relatedWorkout: String?` — workout type if exercise-related
     - `recentBolusAmount: Double?` — bolus amount if post-bolus
   - Added `SettingRecommendation` struct:
     - `setting: RecommendedSetting` — what to change (basal, ICR, exercise, general)
     - `rationale: String` — why this is recommended
     - `confidence: RecommendationConfidence` — low/medium/high based on data quantity
     - `severity: RecommendationSeverity` — informational/suggested/recommended
   - Added `RecommendedSetting` enum: `.reduceBasal`, `.weakenICR`, `.exerciseAdjustment`, `.general`
   - `LowTreatmentSummary` — added:
     - Cause counts: `exerciseCount`, `postBolusCount`, `fastingCount`, `mixedCount`, `unknownCount`
     - Cause rates: computed `exerciseRate`, `postBolusRate`, `fastingRate`, `mixedRate`
     - `dominantCause: LowEpisodeCause` — the most frequent cause
     - `causeBreakdown: String` — human-readable breakdown
     - `recommendations: [SettingRecommendation]` — guardrailed suggestions

2. **`Trio/Sources/Services/HealthKit/NutritionAnalysisService.swift`**
   - Injected `HealthMetricsService` for workout data and `FileStorage` for basal profiles
   - Added `maxRecommendedAdjustment = 20.0` guardrail constant
   - Added `fetchWorkouts()` — fetches workout sessions from HealthKit via `HealthMetricsService`
   - Added `classifyLowEpisode()` — classifies each low by context:
     - Checks for workouts ending 0-4h before low (exercise)
     - Checks for non-SMB boluses 1-4h before low (post-bolus)
     - Falls back to fasting/basal if neither applies
     - Marks as mixed if both exercise and bolus contributed
   - Added `generateRecommendations()` — produces guardrailed suggestions:
     - Exercise-related: suggests temp targets or reduced basal before workouts
     - Post-bolus: suggests ICR weakening (% based on frequency, capped at 20%)
     - Fasting/basal: suggests basal reduction during peak low-occurrence time windows
     - Overall: warns if >2 lows/day, suggests endo consultation
     - Over-correction: suggests glucose tabs and 15/15 rule
   - Updated `runAnalysis()` to fetch workouts in parallel with other data
   - Updated `matchByDay()` to accept workouts and classify detected low episodes
   - Updated `computeSummary()` to compute cause breakdown counts and generate recommendations

3. **`Trio/Sources/Modules/HealthKit/View/NutritionAnalysisView.swift`**
   - Added "Low Episode Causes" section with:
     - Visual proportional bars for each cause (exercise=green, post-bolus=blue, fasting=orange, mixed=yellow)
     - Dominant cause callout
   - Added "Setting Recommendations" section with:
     - Color-coded severity badges (informational=gray, suggested=blue, recommended=orange)
     - Confidence level display
     - Main suggestion text and rationale for each recommendation
     - Footer disclaiming 20% max adjustment cap and advising endo consultation
   - Daily rows now show per-cause badges (e.g., "2E 1B" = 2 exercise, 1 post-bolus)
   - Export report includes:
     - "LOW EPISODE CAUSES" section with counts and percentages per cause
     - "SETTING RECOMMENDATIONS" section with numbered suggestions, rationale, and confidence
     - Daily breakdown shows cause breakdown per day as E/B/F/M counts

4. **`documents/NUTRITION_HEALTH_INTEGRATION.md`**
   - Added Phase 1D documentation

#### Guardrail Design:
- Maximum recommended setting change: 20% (matching Claude-o-Tune default)
- Recommendations include confidence levels based on data quantity (≥5 episodes = high)
- Severity levels help users prioritize (informational < suggested < recommended)
- Time-window specificity for basal recommendations (identifies peak hours)
- All recommendations include rationale explaining the data behind the suggestion
- Footer text advises discussing all changes with an endocrinologist
- ICR weakening suggestions are rounded to nearest 5% for practical applicability

---

## Architecture

### Data Flow

```
Cronometer App
    |
    v  (writes instantly, timestamped at midnight)
Apple Health (HealthKit)
    |
    ├──> HKObserverQuery (background delivery)
    |       |
    |       v
    |    NutritionSnapshotStore (records cumulative totals with real timestamps)
    |       |
    |       v
    |    InferredMealEvent[] (approximate meal times from snapshot deltas)
    |
    v
NutritionHealthService.fetchMeals()
    |-- Reads HKQuantityType: dietaryCarbohydrates, dietaryFatTotal, dietaryProtein
    |-- Filters out entries from org.nightscout.* (Trio's own writes)
    |-- Merges samples within 2-second windows
    |-- Groups by calendar day
    |
    v
HealthNutritionDay[] (display in AppleHealthKitRootView)
    |
    v
NutritionAnalysisService.runAnalysis()
    |-- Fetches Trio carbs from CoreData (CarbEntryStored)
    |-- Fetches glucose from CoreData (GlucoseStored)
    |-- Fetches boluses from CoreData (BolusStored)
    |-- Matches by calendar day
    |-- Detects low BG episodes from glucose data
    |-- Estimates treatment carbs from BG recovery
    |-- Computes adjusted ratios (actual - treatment carbs)
    |
    v
MatchedMealAnalysis[] + NutritionAnalysisSummary + LowTreatmentSummary
    (display in NutritionAnalysisView, export via share sheet)
```

### Settings

| Setting | Default | Purpose |
|---------|---------|---------|
| `writeNutritionToHealth` | `true` | Send Trio carb/fat/protein entries to Apple Health |
| `readNutritionFromHealth` | `false` | Read nutrition data from external apps via Apple Health |
| `lowGlucose` | `72` | Low BG threshold (mg/dL) — used for low episode detection |

### File Structure

```
Trio/Sources/
├── Models/
│   ├── HealthNutrition.swift          # Nutrition entry & day models
│   ├── NutritionAnalysis.swift        # Analysis result models (with low treatment fields)
│   └── NutritionSnapshot.swift        # Snapshot, inferred meals, low episodes, snapshot store
├── Services/HealthKit/
│   ├── NutritionHealthService.swift   # HealthKit reading + HKObserverQuery
│   └── NutritionAnalysisService.swift # Trio vs Cronometer comparison + low detection
└── Modules/HealthKit/
    ├── HealthKitStateModel.swift       # State management (modified)
    └── View/
        ├── AppleHealthKitRootView.swift    # Nutrition display (modified)
        └── NutritionAnalysisView.swift     # Analysis + low treatment + export
```

---

## Future Phases (Planned)

### Phase 2: Real-Time Nutrition Display
- Show Cronometer nutrition alongside Trio's main glucose chart
- Daily macro summary widget on home screen
- Use inferred meal events (from snapshot deltas) to show approximate meal times

### Phase 3: Dosing Awareness (Informational)
- Show "Cronometer says X carbs, you entered Y" at bolus time
- Suggest carb entry based on recent Cronometer data (using inferred meal events)
- Still informational only — user manually confirms

### Phase 4: Dosing Integration
- Option to use Apple Health carbs for COB calculation
- Requires ICR recalibration based on analysis findings
- Requires extensive safety review and user acknowledgment
- Would need real-time meal detection (snapshot-based inferred meals as foundation)

---

## Known Limitations

1. **Cronometer midnight timestamps**: All Cronometer Apple Health entries have 00:00 timestamps. This prevents per-meal analysis. Even Cronometer Gold does not fix this for Apple Health sync. The HKObserverQuery snapshot approach works around this by detecting when daily totals change.
2. **Inferred meal timing resolution**: Depends on how frequently the HK observer fires and app is active. Background delivery is enabled but iOS may batch notifications. Typical resolution: 5-30 minutes.
3. **Treatment carb estimation**: Uses a ~4 mg/dL per gram heuristic which varies by individual, glucose absorption speed, and whether insulin was also active. Estimates are approximate.
4. **Low episode detection**: Uses a simple threshold + trend approach. May miss episodes where BG briefly dips and recovers, or count prolonged lows as a single episode when they were actually multiple.
5. **Bolus attribution**: Daily bolus totals include all non-SMB boluses, which may include correction boluses not tied to meals.
6. **Source filtering**: Entries are filtered by `org.nightscout` bundle prefix. If other apps write nutrition with different bundle IDs, those entries will be included alongside Cronometer data.
