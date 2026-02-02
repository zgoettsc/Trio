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

## Architecture

### Data Flow

```
Cronometer App
    |
    v
Apple Health (HealthKit)
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
    |
    v
MatchedMealAnalysis[] + NutritionAnalysisSummary (display in NutritionAnalysisView)
```

### Settings

| Setting | Default | Purpose |
|---------|---------|---------|
| `writeNutritionToHealth` | `true` | Send Trio carb/fat/protein entries to Apple Health |
| `readNutritionFromHealth` | `false` | Read nutrition data from external apps via Apple Health |

### File Structure

```
Trio/Sources/
├── Models/
│   ├── HealthNutrition.swift          # Nutrition entry & day models
│   └── NutritionAnalysis.swift        # Analysis result models
├── Services/HealthKit/
│   ├── NutritionHealthService.swift   # HealthKit nutrition reading
│   └── NutritionAnalysisService.swift # Trio vs Cronometer comparison
└── Modules/HealthKit/
    ├── HealthKitStateModel.swift       # State management (modified)
    └── View/
        ├── AppleHealthKitRootView.swift    # Nutrition display (modified)
        └── NutritionAnalysisView.swift     # Analysis + export view
```

---

## Future Phases (Planned)

### Phase 2: Real-Time Nutrition Display
- Show Cronometer nutrition alongside Trio's main glucose chart
- Daily macro summary widget on home screen

### Phase 3: Dosing Awareness (Informational)
- Show "Cronometer says X carbs, you entered Y" at bolus time
- Suggest carb entry based on recent Cronometer data
- Still informational only — user manually confirms

### Phase 4: Dosing Integration
- Option to use Apple Health carbs for COB calculation
- Requires ICR recalibration based on analysis findings
- Requires extensive safety review and user acknowledgment
- Would need real-time meal detection (not just daily totals)

---

## Known Limitations

1. **Cronometer midnight timestamps**: All Cronometer Apple Health entries have 00:00 timestamps. This prevents per-meal analysis. Even Cronometer Gold does not fix this for Apple Health sync.
2. **No meal-level matching**: Because of the timestamp limitation, analysis is daily only. Individual meal accuracy cannot be assessed.
3. **Bolus attribution**: Daily bolus totals include all non-SMB boluses, which may include correction boluses not tied to meals.
4. **Source filtering**: Entries are filtered by `org.nightscout` bundle prefix. If other apps write nutrition with different bundle IDs, those entries will be included alongside Cronometer data.
