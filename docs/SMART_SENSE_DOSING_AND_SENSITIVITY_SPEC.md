# Smart Sense — Dosing & Sensitivity Specification

How Smart Sense modifies the standard Trio treatment flow. This covers the Garmin-derived insulin demand factor, how it adjusts carbs passed to oref, the simplified treatment UI flow (no split dosing, no curve engine), and the meal-mode SMB enhancement system.

**Companion docs:** `MEAL_DETECTION_AND_SELECTION_SPEC.md`, `GARMIN_INTEGRATION_SPEC.md`, `MEAL_DECISION_EXPORT_SPEC.md`, `EXPORT_JSON_SPEC.md`

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [End-to-End Treatment Flow](#2-end-to-end-treatment-flow)
3. [Garmin Demand Factor Summary](#3-garmin-demand-factor-summary)
4. [How Demand Factor Modifies Dosing](#4-how-demand-factor-modifies-dosing)
5. [Bolus Calculator Integration](#5-bolus-calculator-integration)
6. [Meal-Mode SMB Enhancement](#6-meal-mode-smb-enhancement)
7. [BG-Adaptive Entry Correction](#7-bg-adaptive-entry-correction)
8. [isDosed Tracking](#8-isdosed-tracking)
9. [Settings](#9-settings)
10. [Apple Watch Communication](#10-apple-watch-communication)
11. [Garmin Watch Communication](#11-garmin-watch-communication)
12. [What to Remove from V2](#12-what-to-remove-from-v2)
13. [What to Keep from V2](#13-what-to-keep-from-v2)
14. [Implementation Checklist](#14-implementation-checklist)

---

## 1. Design Philosophy

Smart Sense keeps the **detection** and **sensitivity** layers of the V2 system but removes the **dosing engine**:

| V2 Feature | Smart Sense | Status |
|---|---|---|
| HealthKit meal detection | Keep as-is | From `MEAL_DETECTION_AND_SELECTION_SPEC.md` |
| Garmin Firebase health data | Keep as-is | From `GARMIN_INTEGRATION_SPEC.md` |
| 10-metric sensitivity model | Keep as-is | `GarminSensitivityModel.swift` |
| Insulin demand factor (0.70–1.30) | Keep — applied to carbs | Core of Smart Sense |
| Three-curve absorption engine | **Remove** | `MacroAbsorptionEngine.swift` |
| Split dosing (upfront % + future entries) | **Remove** | No more FPU scheduling |
| Outcome learning | **Remove** | `V2CurveOutcomeLearning.swift` |
| BG-adaptive entry correction | **Simplify** | Optional, lighter version |
| Meal-mode SMB enhancement | Keep with simplification | Fewer gates |
| Meal decision export | Keep as-is | From `MEAL_DECISION_EXPORT_SPEC.md` |

**The core change:** Instead of computing split doses via a gamma CDF curve engine, Smart Sense multiplies the total selected carbs by the Garmin demand factor and passes the result directly to oref's standard bolus calculator.

---

## 2. End-to-End Treatment Flow

```
1. USER OPENS TREATMENTS
   └─ loadV2DetectedMeals() fires
      ├─ Triggers fresh HealthKit snapshot
      ├─ Runs inferredMealEvents(forLastHours: 8)
      └─ Populates meal feed with V2DetectedMeal[]

2. USER SELECTS MEALS (checkboxes)
   └─ Combined macros computed:
      totalCarbs = sum of selected meal carbs
      totalFat = sum of selected meal fat
      totalProtein = sum of selected meal protein
      totalFiber = sum of selected meal fiber

3. USER TAPS "CONTINUE"
   ├─ Fetch Garmin demand factor (if enabled)
   │   └─ GarminFirestoreService().fetchContext()
   │       → GarminSensitivityModel.computeDemandFactor(from:)
   │       → insulinDemandFactor (0.70–1.30)
   │
   ├─ Adjust carbs for sensitivity:
   │   effectiveCarbs = totalCarbs * insulinDemandFactor
   │   (e.g., 65g * 1.15 = 74.75g — poor sleep means more insulin needed)
   │
   ├─ Set state.carbs = Decimal(effectiveCarbs)
   │
   ├─ Show demand factor in UI:
   │   "Garmin: 1.15x demand (poor sleep, elevated RHR)"
   │   with contribution breakdown from SensitivityResult.contributions[]
   │
   └─ Navigate to standard V1 treatment form
      ├─ Forecast chart (existing)
      ├─ Bolus recommendation from oref calculator
      ├─ Fatty meal toggle (existing)
      ├─ Super bolus toggle (existing)
      ├─ Meal presets (existing)
      ├─ External insulin toggle (existing)
      └─ Confirm button

4. USER CONFIRMS DOSE
   ├─ Standard invokeTreatmentsTask() runs
   ├─ Carbs saved to Core Data (effectiveCarbs, not raw)
   ├─ Bolus delivered via pump
   ├─ NutritionSnapshotStore.shared.recordDoseTimestamp()
   │   (so next Cronometer entry becomes a separate meal)
   ├─ Capture MealDecisionSnapshot (per MEAL_DECISION_EXPORT_SPEC.md)
   └─ Done — oref handles everything from here
```

### Why Multiply Carbs Instead of Modifying ISF/CR?

Multiplying carbs by the demand factor is equivalent to dividing ISF/CR by the same factor, but:

1. **Simpler implementation** — one multiplication vs modifying two schedule-based values
2. **Visible to user** — the carbs field shows what oref will actually see
3. **oref stays unmodified** — no need to intercept or wrap the algorithm
4. **Export clarity** — the decision export captures both raw carbs and effective carbs

---

## 3. Garmin Demand Factor Summary

Full details in `GARMIN_INTEGRATION_SPEC.md`. Quick reference for the sensitivity signals:

### 10 Signals (Additive Impacts on Sensitivity Factor)

```
sensitivityFactor starts at 1.0
Each signal adds or subtracts from it:

Sleep Score:        <40 → -0.11  |  <55 → -0.08  |  <70 → -0.04  |  ≥85 → +0.03
Sleep Duration:     <5h → -0.05  |  <6h → -0.03
Body Battery:       <15 → -0.09  |  <30 → -0.06  |  <50 → -0.03  |  ≥75 → +0.03
Current Stress:     >75 → -0.04  |  >60 → -0.02
Avg Stress Today:   >60 → -0.03  |  >45 → -0.02
Resting HR Delta:   >12 → -0.06  |  >8  → -0.04  |  <-5 → +0.02
HRV Delta:          <-20% → -0.04 | <-10% → -0.02 | >+15% → +0.02
Yesterday Activity: >600cal → +0.08 | >400 → +0.05 | >250 → +0.03
Today Activity:     >400cal → +0.04 | >200 → +0.02
Vigorous Exercise:  >45min → +0.04 | >20min → +0.02
```

### Conversion to Demand Factor

```
insulinDemandFactor = 1.0 / sensitivityFactor
clamped to [0.70, 1.30]
```

**Examples:**
- Normal day: factor=1.0, demand=1.0 (no adjustment)
- Terrible sleep (score 38) + high stress (70) + elevated RHR (+10): factor≈0.83, demand≈1.20 (20% more insulin)
- Great sleep (90) + active yesterday (500cal) + low stress: factor≈1.11, demand≈0.90 (10% less insulin)

---

## 4. How Demand Factor Modifies Dosing

### Simple Path (Smart Sense)

```swift
// In the treatment flow, after meal selection:
let effectiveCarbs = totalCarbs * insulinDemandFactor

// Pass to oref calculator
state.carbs = Decimal(effectiveCarbs)

// oref does: bolus = effectiveCarbs / CR + BG_correction - IOB
// The demand factor is already baked into the carbs
```

### What About Fat and Protein?

In the simplified Smart Sense flow, fat and protein are **informational only** — displayed in the meal card and captured in the decision export, but not used for dosing. oref's standard COB model handles absorption timing.

If you want fat/protein to influence dosing in the future, the cleanest path is:
- Fat/protein → additional carb equivalents (simple formula, no curve engine)
- Add to effectiveCarbs before passing to oref
- This is optional and not part of the initial Smart Sense implementation

### Guard Pattern for Fetching Demand Factor

Every site that uses the demand factor follows this pattern:

```swift
var demandFactor = 1.0  // default: no adjustment

if settingsManager.settings.garminEnabled,
   GarminFirebaseManager.isSignedIn
{
    let service = GarminFirestoreService()  // uses 5-min cache
    let snapshot = await service.fetchContext()
    let result = GarminSensitivityModel.computeDemandFactor(from: snapshot)
    demandFactor = result.insulinDemandFactor
}
```

---

## 5. Bolus Calculator Integration

### Where the Calculator Lives

The existing `BolusCalculationManager` (or equivalent in your codebase) computes the recommended bolus from:
- Carbs entered (now demand-adjusted)
- Current BG
- Target BG
- ISF (from schedule)
- Carb ratio (from schedule)
- Current IOB
- Trend/momentum

### What Smart Sense Changes

**Before calculator runs:**
```swift
// 1. Sum carbs from selected meals
let rawCarbs = selectedMeals.reduce(0.0) { $0 + $1.carbs }

// 2. Apply Garmin demand factor
let effectiveCarbs = rawCarbs * demandFactor

// 3. Set on state
state.carbs = Decimal(effectiveCarbs)

// 4. Optionally set meal date to earliest selected meal
if let earliest = selectedMeals.min(by: { $0.date < $1.date }) {
    state.date = earliest.date
}

// 5. Run standard calculator
await state.updateForecasts()
state.insulinCalculated = await state.calculateInsulin()
```

**After dose confirmed (in invokeTreatmentsTask):**
```swift
// Record dose timestamp for meal grouping
NutritionSnapshotStore.shared.recordDoseTimestamp()

// Capture decision snapshot for export
let snapshot = MealDecisionSnapshot(
    id: UUID(),
    doseTimestamp: Date(),
    selectedMeals: v2SelectedMealsForChart ?? [],
    totalCarbs: rawCarbs,           // original carbs before demand adjustment
    effectiveCarbs: effectiveCarbs,  // what oref actually saw
    demandFactor: demandFactor,
    demandContributions: v2DemandContributions,
    // ... all other fields per MEAL_DECISION_EXPORT_SPEC.md
)
MealDecisionLogger.shared.saveSnapshot(snapshot)
```

### Delayed Meals

If a meal was detected 45 minutes ago but the user is only now dosing, oref naturally handles this correctly because:
- BG has already risen (so correction component is larger)
- Some carbs may already be absorbed (oref's COB model accounts for this)
- Setting `state.date` to the meal's original timestamp helps oref model the absorption curve from the right start time

---

## 6. Meal-Mode SMB Enhancement

When a meal is active, the loop can deliver larger SMBs to cover ongoing absorption. This is kept from V2 but simplified.

### How It Works

After a meal is dosed, oref sees the carbs as COB. The meal-mode system temporarily increases `maxSMBBasalMinutes` so the loop can deliver more aggressive micro-boluses while carbs are absorbing.

### Gate System

Four safety gates must ALL pass for meal-mode to activate:

```swift
struct MealModeState {
    let isActive: Bool
    let effectiveMaxSMBMinutes: Decimal

    static func evaluate(
        hasActiveMealEntries: Bool,         // Gate 1: COB > 0 from recent meal
        currentBG: Double?,                 // Gate 2: BG > bgFloor (default 90)
        bgTrend: Double?,                   // Gate 3: BG not dropping fast (≥ -3.0 mg/dL/5min)
        cgmAgeSeconds: TimeInterval?,       // Gate 4: CGM data fresh (< 10 min old)
        userMaxSMBMinutes: Decimal,         // User's configured maxSMBBasalMinutes
        mealSMBMultiplier: Double = 2.0     // Multiplier when active (default 2x)
    ) -> MealModeState
}
```

**Gate details:**

| Gate | Check | Why |
|---|---|---|
| 1. Active meal | COB > 0 from a meal dosed in last ~4h | No enhancement without carbs on board |
| 2. BG floor | Current BG > 90 mg/dL (configurable) | Don't push SMBs when already low-ish |
| 3. BG trend | Trend ≥ -3.0 mg/dL per 5min | Don't stack insulin while dropping |
| 4. CGM freshness | Last reading < 10 min old | Don't act on stale data |

**When all gates pass:**
```swift
effectiveMaxSMBMinutes = userMaxSMBMinutes * mealSMBMultiplier
// e.g., 30 min * 2.0 = 60 min worth of basal as SMB
```

**When any gate fails:**
```swift
effectiveMaxSMBMinutes = userMaxSMBMinutes  // normal (non-meal) limit
```

### Demand Factor Dampening (Optional)

If the Garmin demand factor is very high (>1.5), dampen the SMB multiplier to avoid front-loading too much insulin before BG confirms the resistance:

```swift
var effectiveMultiplier = mealSMBMultiplier
if demandFactor > 2.0 {
    effectiveMultiplier = min(effectiveMultiplier, 1.5)
} else if demandFactor > 1.5 {
    let ratio = (demandFactor - 1.5) / 0.5
    effectiveMultiplier = effectiveMultiplier - ratio * max(0, effectiveMultiplier - 1.5)
}
```

This is a safety measure: if Garmin says you need 2x insulin, don't also double the SMB rate — let the carb adjustment handle most of it and let BG confirm.

### Integration Point

Meal-mode evaluation runs each loop cycle (~5 min), BEFORE oref:

```swift
// In the loop cycle, before calling oref:
let mealMode = MealModeState.evaluate(
    hasActiveMealEntries: cob > 0 && recentMealDosed,
    currentBG: latestGlucose,
    bgTrend: bgDelta,
    cgmAgeSeconds: cgmAge,
    userMaxSMBMinutes: settings.maxSMBBasalMinutes,
    mealSMBMultiplier: settings.mealSMBMultiplier
)

// Pass to oref
orefInput.maxSMBBasalMinutes = mealMode.effectiveMaxSMBMinutes
```

---

## 7. BG-Adaptive Entry Correction

This is an **optional** feature for Smart Sense. In the full V2 system, the adaptive service scaled future carb entries up/down based on BG prediction error. In Smart Sense, since we don't create future entries (no split dosing), this simplifies to:

### Simplified Version: COB Scaling

If you want to keep some adaptive behavior, the simplest approach is to let oref's built-in `min_5m_carbimpact` and deviation-based COB decay handle it. oref already:
- Reduces COB faster when BG is dropping (deviations negative)
- Maintains COB when BG is rising as expected
- Uses `min_5m_carbimpact` as a floor for COB decay

This means **no custom adaptive service is needed** for the initial Smart Sense implementation. oref's existing deviation logic provides the same directional correction.

### If You Want More Aggressive Adaptation Later

The V2 adaptive service (`MacroAdaptiveService.swift`) can be simplified to only handle:
1. **Low BG protection** — if BG < 70 and dropping, zero out remaining COB entries
2. **High BG catch-up** — if BG >> predicted, add a small correction bolus via increased COB

But this is future work, not part of the initial implementation.

---

## 8. isDosed Tracking

### Purpose

Prevent double-dosing. When a meal is dosed, mark it so the user sees it's already been covered.

### Implementation

**Option A: Dose timestamp matching (simple)**

When a dose is confirmed, `recordDoseTimestamp()` saves the current time. When loading meals, any meal whose timestamp is before the most recent dose timestamp is marked `isDosed = true`:

```swift
func loadV2DetectedMeals() async {
    let inferredMeals = NutritionSnapshotStore.shared.inferredMealEvents(forLastHours: 8)
    let doseTimestamps = NutritionSnapshotStore.shared.loadDoseTimestamps()
    let latestDose = doseTimestamps.max() ?? .distantPast

    var meals: [V2DetectedMeal] = []
    for event in inferredMeals {
        let isDosed = event.detectedAt <= latestDose
        meals.append(V2DetectedMeal(
            date: event.detectedAt,
            label: inferMealLabel(for: event.detectedAt),
            carbs: event.carbsDelta,
            fat: event.fatDelta,
            protein: event.proteinDelta,
            fiber: event.fiberDelta,
            source: "Cronometer",
            isDosed: isDosed,
            healthKitID: nil
        ))
    }
    v2DetectedMeals = meals.sorted { $0.date > $1.date }
}
```

**Option B: Macro fingerprinting (more precise)**

Match dosed meals by comparing carbs/fat/protein within a tolerance:

```swift
let isDosed = todayDosedMeals.contains { dosed in
    abs(dosed.carbs - event.carbsDelta) < 2.0 &&
    abs(dosed.fat - event.fatDelta) < 2.0 &&
    abs(dosed.protein - event.proteinDelta) < 2.0
}
```

Option A is simpler and sufficient for the initial implementation. The dose timestamp already serves as a meal group boundary (see `MEAL_DETECTION_AND_SELECTION_SPEC.md` §4, Step 4).

### UI Behavior

- Dosed meals are dimmed (opacity 0.5)
- Dosed meals show a green checkmark badge
- User CAN still select a dosed meal (for re-dosing), but sees a warning:
  > "This meal was already dosed. Selecting it will add additional insulin coverage."

---

## 9. Settings

### New Settings for Smart Sense

```swift
// In TrioSettings:

/// Master toggle for Smart Sense meal detection + Garmin sensitivity
var smartSenseEnabled: Bool = false

/// Enable Garmin health data integration (requires Firebase secrets)
var garminEnabled: Bool = false

/// Meal-mode SMB multiplier (1.0x = no enhancement, 2.0x = default, 3.0x = max)
var mealSMBMultiplier: Double = 2.0

/// BG floor for meal-mode SMBs (mg/dL). Below this, meal-mode deactivates.
var mealSMBBGFloor: Double = 90.0

/// Read nutrition data from Apple Health (enables HealthKit observer)
var readNutritionFromHealth: Bool = false
```

### Existing Settings Used (No Changes Needed)

These existing oref/Trio settings are used as-is:

```swift
// From Preferences (oref settings):
var maxIOB: Decimal
var maxSMBBasalMinutes: Decimal
var maxUAMSMBBasalMinutes: Decimal
var smbDeliveryRatio: Decimal
var smbInterval: Decimal
var enableSMBAlways: Bool
var enableSMBWithCOB: Bool
var enableSMBAfterCarbs: Bool
var enableUAM: Bool
var autosensMax: Decimal
var autosensMin: Decimal

// From TrioSettings:
var insulinType: String          // for future use
var maxBolus: Decimal
```

### Settings UI

Add a "Smart Sense" section in Settings with:

1. **Smart Sense toggle** — master on/off
2. **Read Nutrition from Health** — enables HealthKit observer (already exists in Apple Health settings)
3. **Garmin Sensitivity** — sub-page with:
   - Enable/disable toggle
   - "Test Connection" → `GarminFirestoreStatusView`
   - Info cards (sleep, activity, HR, HRV descriptions)
4. **Meal-Mode SMB** — sub-section with:
   - Multiplier slider (1.0–3.0, step 0.1)
   - BG floor picker

---

## 10. Apple Watch Communication

### Existing Watch → iPhone Messages

The Apple Watch companion app already supports sending bolus and carb requests:

```swift
// Watch sends bolus request:
{ "bolus": Decimal }

// Watch sends carbs request:
{ "carbs": Int, "date": timeIntervalSince1970 }

// Watch requests bolus recommendation:
// iPhone calculates and returns recommendation
```

### Smart Sense Impact on Watch

The watch does NOT need to know about Smart Sense. The flow is:

1. Watch sends carbs → iPhone applies demand factor → oref calculates → Watch shows recommendation
2. Watch sends bolus → iPhone delivers as normal

The demand factor adjustment happens on the iPhone side before the calculator runs. The watch just sees the final recommendation.

### If Watch Shows Demand Factor (Optional Enhancement)

To display the Garmin demand factor on the watch:

```swift
// Add to watch state update:
struct WatchState {
    // ... existing fields ...
    var demandFactor: Double?  // nil if Garmin not enabled
}
```

This is optional and cosmetic — the watch doesn't use the factor for any calculation.

---

## 11. Garmin Watch Communication

Completely independent from Garmin health data. The ConnectIQ watch communication sends loop data to a Garmin watch face:

### Data Sent to Garmin Watch

```swift
struct GarminWatchState: Encodable {
    var glucose: String?           // "142" or "7.9"
    var trendRaw: String?          // "Flat", "FortyFiveUp", etc.
    var delta: String?             // "+3", "-8"
    var iob: String?               // "2.3"
    var cob: String?               // "45"
    var lastLoopDateInterval: UInt64?  // epoch seconds
    var eventualBGRaw: String?     // "120"
    var isf: String?               // "40"
}
```

### Update Triggers

Watch state rebuilds when any of these change:
- Glucose readings (new CGM data)
- IOB changes
- OrefDetermination saved (new loop cycle)
- Settings changes (unit switch)
- Watch sends "status" request

All throttled to 10-second intervals via Combine.

### No Smart Sense Changes Needed

The Garmin watch communication is unchanged by Smart Sense. It shows the same loop data regardless of how the bolus was calculated.

Full details: `GARMIN_INTEGRATION_SPEC.md` §8–10.

---

## 12. What to Remove from V2

These files/features are NOT part of Smart Sense:

### Files to Delete

| File | Reason |
|---|---|
| `MacroAbsorptionEngine.swift` | Three-curve engine — replaced by simple carb × demand |
| `MacroOnBoardCalculator.swift` | Macro absorption tracking — oref handles COB |
| `MacrosOnBoardTracker.swift` | Macro on-board tracking — not needed |
| `V2CurveOutcomeLearning.swift` | Outcome learning service — removed |
| `V2MealOutcomeStored+CoreData*.swift` | Outcome Core Data entity — removed |
| `V2DosePreviewView.swift` | Two-line forecast + split dose preview — removed |
| `V2ForecastChart.swift` | Two-line forecast chart — use standard chart |
| `V2MacroDosingSettingsView.swift` | V2-specific settings — replaced by Smart Sense settings |
| `V2MacroHubView.swift` | Macro hub view — removed |
| `V2OutcomeAnalysisView.swift` | Outcome analysis — removed |
| `V2NutritionSettingsView.swift` | V2 nutrition settings — consolidated into Smart Sense |
| `V2MacroEngineTests.swift` | V2 engine tests — removed |

### State Properties to Remove (from TreatmentsStateModel)

```swift
// DELETE all of these:
var v2UpfrontCarbs: Double?
var v2UpfrontPercent: Double?
var v2OriginalFullCarbs: Double?
var v2UpfrontPercentOverride: Double?
var v2CurveSuggestedPercent: Double?
var v2TauCarb: Double?
var v2FatTotalEquiv: Double?
var v2SafeWindowMinutes: Int?
var showV2AdjustSlider: Bool
var v2PendingOutcome: V2MealOutcome?
```

### CarbsStorage Properties to Remove

```swift
// DELETE:
var v2FullCarbsForEngine: Double?
var v2UpfrontPercentOverride: Double?
var v2LastEngineMealID: String?
var v2SelectedMealsForDelivery: [V2DetectedMeal]?
```

### Settings to Remove

```swift
// DELETE from TrioSettings:
var useV2MacroAbsorption: Bool
var v2SafeWindowMinutesOverride: Int?
var v2MinUpfrontFloor: Decimal
var v2OutcomeLearningEnabled: Bool
var claudeRecalibrationEnabled: Bool
```

---

## 13. What to Keep from V2

### Files to Keep (Unchanged)

| File | Purpose |
|---|---|
| `GarminFirebaseConfig.swift` | Build-time secret placeholders |
| `GarminFirestoreService.swift` | Firebase auth + Firestore queries |
| `GarminContextSnapshot.swift` | ~40-field health data snapshot |
| `GarminSensitivityModel.swift` | 10-metric demand factor (0.70–1.30) |
| `GarminDevice.swift` | Codable IQDevice wrapper |
| `GarminWatchState.swift` | Data sent to Garmin watch face |
| `GarminManager.swift` | ConnectIQ device management + state updates |
| `V2GarminSettingsView.swift` | Garmin settings toggle + info (rename to SmartSenseGarminSettingsView) |
| `GarminFirestoreStatusView.swift` | Connection test + data display |
| `NutritionSnapshot.swift` | Snapshot model + NutritionSnapshotStore (meal detection) |
| `V2DetectedMeal.swift` | Detected meal model |
| `HealthNutrition.swift` | HealthNutritionEntry model |
| `NutritionHealthService.swift` | HealthKit observer + snapshot recording |
| `V2MealCardView.swift` | Meal card UI (rename to SmartSenseMealCardView) |
| `V2ManualMealEntryView.swift` | Manual entry form (rename to SmartSenseManualEntryView) |
| `V2TreatmentView.swift` | Meal feed (simplify: remove dose preview step, rename) |

### State Properties to Keep

```swift
// KEEP in TreatmentsStateModel:
var v2DetectedMeals: [V2DetectedMeal] = []    // rename to detectedMeals
var v2DemandFactor: Double = 1.0               // rename to demandFactor
var v2DemandContributions: [...]               // rename to demandContributions
```

### Methods to Keep

```swift
// KEEP in TreatmentsStateModel:
func loadV2DetectedMeals() async          // rename to loadDetectedMeals()
func addManualV2Meal(...)                  // rename to addManualMeal(...)
func recordCronometerBaseline() async
func inferMealLabel(for:) -> String
```

---

## 14. Implementation Checklist

### Phase 1: Core (Minimum Viable)

- [ ] Remove V2 engine files (MacroAbsorptionEngine, OutcomeLearning, etc.)
- [ ] Remove V2 state properties from TreatmentsStateModel
- [ ] Remove V2 CarbsStorage properties
- [ ] Remove V2-specific settings from TrioSettings
- [ ] Add `smartSenseEnabled` setting
- [ ] Keep meal detection system intact (NutritionSnapshot, HealthKit observer)
- [ ] Keep Garmin files intact (Firebase config, Firestore service, sensitivity model)
- [ ] Modify treatment flow: selected carbs × demandFactor → state.carbs → oref
- [ ] Add demand factor display to treatment UI (show factor + contributions)
- [ ] Wire `recordDoseTimestamp()` into `invokeTreatmentsTask()`
- [ ] Implement isDosed tracking (Option A: dose timestamp matching)

### Phase 2: Enhancement

- [ ] Add meal-mode SMB enhancement (4-gate system)
- [ ] Add `mealSMBMultiplier` and `mealSMBBGFloor` settings
- [ ] Add demand factor dampening for SMB multiplier
- [ ] Add Smart Sense settings page
- [ ] Rename V2 files/classes to Smart Sense naming

### Phase 3: Export & Analysis

- [ ] Implement MealDecisionSnapshot capture at dose time
- [ ] Implement MealDecisionLogger (per MEAL_DECISION_EXPORT_SPEC.md)
- [ ] Add MealDecisionExportView to settings
- [ ] Update AI Health Data Export to include demand factor

### Phase 4: Polish

- [ ] Update watch state to optionally include demand factor
- [ ] Add Smart Sense info/help text in settings
- [ ] Clean up any remaining V2 references in code and UI strings
- [ ] Add unit tests for demand factor × carbs flow

---

## Summary

Smart Sense = **meal detection** + **Garmin sensitivity** + **standard oref dosing**.

The Garmin demand factor (0.70–1.30) multiplies the carbs passed to oref's bolus calculator. No curve engine, no split dosing, no outcome learning. The sensitivity model's 10 health signals (sleep, stress, activity, recovery) provide a physiologically-informed adjustment that makes the standard algorithm smarter without adding complexity to the dosing math.

All the complexity lives in **detection** (HealthKit snapshots → inferred meals) and **sensitivity** (Garmin data → demand factor). The dosing itself is just `carbs × factor → oref`.
