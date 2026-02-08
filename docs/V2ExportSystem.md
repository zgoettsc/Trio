# V2 Meal Data Export System

## Purpose

The V2 export system produces a comprehensive JSON snapshot of every meal the V2 Three-Curve Macro Absorption Engine has processed. It captures the full dosing feedback loop: what the system knew at meal time, what it decided, what it wrote to Core Data for oref, and what actually happened to BG over the following hours.

The export is designed for offline analysis — paste the JSON into a conversation with Claude (or any analysis tool) to identify parameter drift, compare predicted vs actual BG responses, and make evidence-based tuning decisions.

---

## Background: The Scheduled Entries Problem

### What We Had (Initial Implementation)

The first export implementation captured meal outcomes, BG traces, and V2 engine inputs but showed **zero scheduled entries** for every meal. The `scheduledEntries` array was always empty even though the V2 engine was writing future carb/protein/fat entries to Core Data.

### Root Cause: Disconnected mealIDs

The V2 system has two separate save paths that run at different times:

1. **Outcome save** — `applyCronometerRecommendation()` created a `V2MealOutcome` with `mealID: UUID().uuidString` — a fresh random ID.
2. **Entry save** — `CarbsStorage.saveCarbEquivalents()` called `MacroAbsorptionEngine.generateEntries()`, which created its own `mealID = UUID().uuidString` and stamped that as the `fpuID` on every future entry written to Core Data.

These were two completely separate UUIDs. The export's `fetchScheduledEntries()` searched Core Data for `fpuID == outcome.mealID`, but they never matched.

### The Fix

Three changes, across three files:

**1. CarbsStorage now exposes the engine's mealID**

After `MacroAbsorptionEngine.generateEntries()` runs in the V2 path, `CarbsStorage` captures `result.mealID` into a new `v2LastEngineMealID` property. This is the actual fpuID that all future entries in Core Data carry.

**2. Outcome save is deferred to after saveMeal()**

Previously, the outcome was saved immediately in `applyCronometerRecommendation()` (when the user taps "Apply" on the Cronometer sheet). Now it creates a `v2PendingOutcome` with a placeholder mealID. The actual save happens later in `invokeTreatmentsTask()`, after `saveMeal()` has run the engine and set `v2LastEngineMealID`.

**3. Pending outcome is finalized with the engine's mealID**

In `invokeTreatmentsTask()`, after `saveMeal()` completes:
- Read `carbsStorage.v2LastEngineMealID`
- Call `pendingOutcome.withMealID(engineMealID)` to link the outcome to the correct Core Data entries
- Fetch Garmin snapshot (cached) and attach via `withGarminSnapshot(snapshot)`
- Save to `V2OutcomeLearningStore`

### Timing Sequence

```
User taps "Apply" on Cronometer sheet
  └─ applyCronometerRecommendation()
       ├─ Sets self.carbs / fat / protein (for bolus calculator)
       ├─ Threads v2FullCarbsForEngine to CarbsStorage
       ├─ Saves CronometerMealRecommendation (for Cronometer learning)
       └─ Creates v2PendingOutcome with mealID="pending"

User taps "Log Meal" / "Enact Bolus"
  └─ invokeTreatmentsTask()
       ├─ saveMeal()
       │    └─ carbsStorage.storeCarbs()
       │         └─ saveCarbEquivalents() — V2 path
       │              ├─ MacroAbsorptionEngine.generateEntries()
       │              │    └─ Creates mealID = UUID(), stamps on all entries
       │              ├─ v2LastEngineMealID = result.mealID  ← captured here
       │              └─ saveFPUToCoreDataAsBatchInsert() — entries use this fpuID
       │
       ├─ Read v2PendingOutcome
       ├─ pendingOutcome.withMealID(carbsStorage.v2LastEngineMealID)
       ├─ pendingOutcome.withGarminSnapshot(...)
       ├─ V2OutcomeLearningStore.shared.save(pendingOutcome)
       └─ Clear v2PendingOutcome
```

---

## Current Architecture

### Files Involved

| File | Role |
|------|------|
| `V2CurveOutcomeLearning.swift` | Export structs, `buildComprehensiveExport()`, BG/entry fetchers, copy helpers |
| `V2OutcomeAnalysisView.swift` | Export button UI, JSON encoding, share sheet |
| `CarbsStorage.swift` | Exposes `v2LastEngineMealID` from engine |
| `TreatmentsStateModel.swift` | `v2PendingOutcome` lifecycle, deferred save |
| `MacroAbsorptionEngine.swift` | Generates `mealID` used as `fpuID` in Core Data |

### Data Flow

```
V2OutcomeAnalysisView
  │  "Export All Meal Data" button
  │
  ▼
V2OutcomeLearningStore.buildComprehensiveExport(context:)
  │
  ├─ loadAll()                    → [V2MealOutcome] from UserDefaults (90-day retention)
  ├─ loadParameters()             → V2PersonalCurveParameters (learned curve params)
  ├─ BaseFileStorage.retrieve()   → TrioSettings + Preferences (user settings snapshot)
  │
  └─ For each outcome:
       ├─ fetchGlucoseTrace(meal-2h .. meal)      → [V2BGReading]  pre-meal
       ├─ fetchGlucoseTrace(meal .. meal+8h)       → [V2BGReading]  post-meal
       ├─ fetchScheduledEntries(mealID)            → [V2ScheduledEntry] from Core Data
       ├─ GarminSensitivityModel.computeDemandFactor(from: snapshot)
       │    └─ Re-derive contributions             → [V2GarminContribution]
       └─ Compute dosing summary                   → V2DosingSummary
  │
  ▼
V2ComprehensiveExport (JSON)
  │
  ▼
iOS Share Sheet (Mail, Files, AirDrop, etc.)
```

---

## Export JSON Structure

### Top Level: `V2ComprehensiveExport`

| Field | Type | Description |
|-------|------|-------------|
| `exportDate` | ISO 8601 | When the export was generated |
| `appVersion` | String | Trio version (e.g. "0.6.0") |
| `totalMeals` | Int | Number of meals in the export |
| `currentParameters` | Object | Currently learned V2 curve parameters |
| `userSettings` | Object | Full settings snapshot at export time |
| `meals` | Array | One record per meal |

### Per Meal: `V2MealExportRecord`

| Field | Type | Description |
|-------|------|-------------|
| `outcome` | Object | Full `V2MealOutcome` — macros, params, Garmin, checkpoints |
| `preMealBGTrace` | Array | Every CGM reading from meal-2h to meal time |
| `postMealBGTrace` | Array | Every CGM reading from meal to meal+8h (or now) |
| `scheduledEntries` | Array | All V2 dosing entries in Core Data for this meal |
| `garminContributions` | Array | Garmin sensitivity breakdown by metric |
| `dosingSummary` | Object | Computed insulin/carb summary |

### V2MealOutcome Fields

**Macros:**
- `carbs`, `fat`, `protein`, `fiber` — grams eaten

**V2 Engine Parameters (at meal time):**
- `tauCarb` — carb absorption time constant (minutes, fat/fiber-adjusted)
- `proteinFactor` — protein-to-carb gluconeogenesis multiplier (0–0.80)
- `fatTotalEquiv` — fat carb-equivalent from nonlinear ramp (grams)
- `upfrontPercent` — fraction of carbs dosed as upfront bolus (0–1)
- `curveSuggestedPercent` — what the gamma CDF calculated before any override
- `insulinDemandFactor` — Garmin sensitivity multiplier (< 1 = more resistant)
- `safeWindowMinutes` — split dosing window (45 for rapid, 30 for ultra-rapid)

**Dosing Context:**
- `bgAtMeal` — BG at meal time (mg/dL)
- `carbRatioAtMeal` — ICR at meal time
- `isfAtMeal` — ISF at meal time

**SMB Enhancement:**
- `mealSMBMultiplier` — meal-mode SMB boost factor
- `mealModeWasActive` — whether all 5 gates passed

**Garmin:**
- `garminSnapshot` — raw Garmin health data (sleep, stress, HRV, activity, etc.)

**BG Outcomes (backfilled over time):**
- `checkpoints` — BG values at 1h, 2h, 3h, 4h, 5h, 6h, 8h with:
  - `bgValue` — actual BG reading (null until backfilled)
  - `isClean` — true if no confounding meals in window
  - `curvePhase` — which curve is dominant: `carb`, `protein`, `fat`, `overlap`, or `skip`

**Adaptive Adjustments:**
- `adaptiveAdjustments` — BG-adaptive scaling events during absorption

**Meal Overlap:**
- `hasConfoundingMeal` — whether a subsequent meal was detected

### V2ScheduledEntry Fields

| Field | Type | Description |
|-------|------|-------------|
| `date` | ISO 8601 | When this entry is scheduled for absorption |
| `carbEquivalent` | Double | Grams of carb-equivalent |
| `entryType` | String | `"carb"`, `"protein-gluco"`, `"fat-resistance"`, or `"unknown"` |
| `isAbsorbed` | Bool | True if date is in the past |
| `isFPU` | Bool | True for V2 curve entries (always true for scheduled) |

### V2GarminContribution Fields

| Field | Type | Description |
|-------|------|-------------|
| `metric` | String | e.g. "Sleep Score", "Body Battery", "Stress", "Today Activity" |
| `value` | String | e.g. "90/100", "245 cal" |
| `impact` | Double | Sensitivity shift (positive = more sensitive, negative = more resistant) |
| `description` | String | Human-readable explanation |

### V2DosingSummary Fields

| Field | Type | Description |
|-------|------|-------------|
| `upfrontCarbsForBolus` | Double | carbs * upfrontPercent * demandFactor |
| `upfrontInsulin` | Double | upfrontCarbs / carbRatio (units) |
| `proteinGlucoEquivalent` | Double | protein * proteinFactor (carb-equiv grams) |
| `fatCarbEquivalent` | Double | From nonlinear ramp (carb-equiv grams) |
| `totalEffectiveCarbs` | Double | Upfront + all scheduled entries |
| `totalScheduledEntries` | Int | Count of entries in Core Data |
| `pendingEntries` | Int | Entries still in the future |
| `absorbedEntries` | Int | Entries already past |

### V2UserSettingsSnapshot Fields

**V2 Engine Settings:**
- `useV2MacroAbsorption` — V2 engine enabled
- `insulinType` — `"rapidActing"` or `"ultraRapid"`
- `v2SafeWindowMinutesOverride` — user override for split window (null = use default)
- `mealModeSMBMultiplier` — meal-mode SMB boost factor
- `mealModeBGFloor` — BG floor for meal-mode gates (mg/dL)
- `garminEnabled` — Garmin integration on/off
- `v2OutcomeLearningEnabled` — outcome learning on/off
- `claudeRecalibrationEnabled` — AI recalibration on/off

**OpenAPS/oref Settings:**
- `maxIOB` — max IOB limit
- `maxSMBBasalMinutes` — max SMB size in basal-minutes
- `maxUAMSMBBasalMinutes` — max UAM SMB size
- `smbDeliveryRatio` — fraction of needed insulin per SMB
- `smbInterval` — minutes between SMBs
- `insulinCurve` — `"rapid-acting"`, `"ultra-rapid"`, or `"bilinear"`
- `insulinPeakTime` — insulin activity peak (minutes)
- `useCustomPeakTime` — whether custom peak is active
- `maxCOB` — max carbs on board for safety
- `enableSMBAlways`, `enableSMBWithCOB`, `enableSMBAfterCarbs`, `enableUAM` — SMB enable flags
- `autosensMax`, `autosensMin` — autosens bounds

---

## Storage and Retention

| Data | Storage | Retention |
|------|---------|-----------|
| V2MealOutcome records | UserDefaults (`V2MealOutcomes` key) | 90 days, pruned on `loadAll()` |
| V2PersonalCurveParameters | UserDefaults (`V2CurveParameters` key) | Indefinite |
| Scheduled entries (fpuID) | Core Data (`CarbEntryStored`) | Managed by Core Data lifecycle |
| Glucose readings | Core Data (`GlucoseStored`) | Managed by Core Data lifecycle |
| User settings | JSON files via `BaseFileStorage` | Live settings, not historical |

**Note:** The user settings snapshot captures settings at **export time**, not at meal time. The per-meal `carbRatioAtMeal`, `isfAtMeal`, and engine parameters in each outcome reflect the values that were active when that specific meal was dosed.

---

## How to Use the Export

### Generating an Export

1. Open Trio Settings > V2 Macro Dosing > Outcome Analysis
2. Tap **"Export All Meal Data"**
3. Wait for the spinner (fetches BG data from Core Data)
4. Share via the iOS share sheet — AirDrop, Files, Mail, etc.

### Output File

- **Format:** JSON with ISO 8601 dates, pretty-printed, sorted keys
- **Filename:** `v2-meal-export-{ISO8601_TIMESTAMP}.json`
- **Example:** `v2-meal-export-2026-02-08T19-49-05Z.json`

### Analysis Checklist

When reviewing an export, check:

1. **scheduledEntries** — Are they populated? If zero for a meal logged after the mealID fix, investigate.
2. **checkpoints** — Look for `bgValue` at each hour. Missing values mean BG data wasn't available at backfill time. `isClean: false` means a confounding meal overlapped.
3. **curvePhase** — Does attribution make sense for the macros? A 9g-carb / 30g-protein meal should show `skip` for fat phases.
4. **garminContributions** — Which metrics shifted demand? Large negative impacts (more resistant) on high-spike meals may indicate the Garmin model needs weight tuning.
5. **dosingSummary.upfrontInsulin** — Compare to the BG spike. Too little → spike. Too much → crash.
6. **preMealBGTrace** — Was BG stable before the meal, or was there a low recovery / active correction? Unstable pre-meal BG makes outcome attribution unreliable.
7. **userSettings** — Check for mismatches (e.g. `insulinType: "rapidActing"` but `insulinCurve: "ultra-rapid"`).

### Known Limitations

- **Old meals have empty scheduledEntries.** Meals logged before the mealID linkage fix (commit `b76b71e`) will always show zero entries because the outcome's mealID doesn't match any fpuID in Core Data.
- **Settings snapshot is current, not historical.** If you changed your ICR from 1:8 to 1:20 after logging old meals, the `userSettings` block reflects 1:20 but those old meals used 1:8 (captured in each outcome's `carbRatioAtMeal`).
- **Garmin contributions are re-derived.** They're computed from the stored `garminSnapshot` at export time using the current Garmin model weights. If weights change, contribution breakdowns may differ from what was calculated at meal time (though the stored `insulinDemandFactor` is the original value).
- **Post-meal BG trace is capped at "now".** If you export 30 minutes after a meal, you'll only see 30 minutes of post-meal data. Export later for more complete traces.
- **Fiber data** is recorded but currently always `0` because the Cronometer integration doesn't expose fiber separately. Future work: parse fiber from Cronometer nutrition data.
