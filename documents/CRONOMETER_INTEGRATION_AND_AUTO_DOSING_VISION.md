# Cronometer Integration & Automated Dosing Vision

**Version:** 1.0
**Date:** February 7, 2026
**Status:** Phases 1-5b implemented, Phases 6-8 planned

## Table of Contents

1. [Overview](#overview)
2. [Phase 1: Cronometer Meal Data in AI Prompts](#phase-1-cronometer-meal-data-in-ai-prompts)
3. [Phase 2: Cronometer Button & Recommendation View](#phase-2-cronometer-button--recommendation-view)
4. [Phase 3: Meal Outcome Prediction System](#phase-3-meal-outcome-prediction-system)
5. [Phase 4: Coupled Fat/Protein/Carb Dosing](#phase-4-coupled-fatproteincarb-dosing)
6. [Phase 5: Snapshot Delta Reliability & Log Button](#phase-5-snapshot-delta-reliability--log-button)
7. [Phase 5b: Late Dosing with Meal Picker](#phase-5b-late-dosing-with-meal-picker)
8. [Phase 6: Background Auto-Detection & Notification Dosing](#phase-6-background-auto-detection--notification-dosing)
9. [Phase 7: Garmin/Firestore Context Integration](#phase-7-garminfirestore-context-integration)
10. [Phase 8: Personalized Sensitivity Model](#phase-8-personalized-sensitivity-model)
11. [Architecture Overview](#architecture-overview)
12. [Key Technical Decisions](#key-technical-decisions)
13. [File Reference](#file-reference)

---

## Overview

This document tracks the evolution of Trio's Cronometer integration from a simple "read nutrition from Apple Health" feature into a fully autonomous meal detection, dosing recommendation, and (eventually) automated insulin delivery system.

The core insight driving this work: **Cronometer already knows what you ate. The CGM already knows your glucose. The loop already knows your IOB/COB. The pump can already deliver insulin. The only thing missing is connecting these systems intelligently.**

### Related Documentation

- `NUTRITION_HEALTH_INTEGRATION.md` — Covers the foundational Apple Health nutrition reading, retroactive analysis, and low episode detection (Phases 1A-1E). This document builds on top of that infrastructure.
- `HEALTH_METRICS_AI_ANALYSIS_PLAN.md` — Covers reading activity/sleep/heart rate from Apple Health for AI analysis context.
- `AI_INSIGHTS_IMPLEMENTATION.md` — Covers the Claude AI integration (Phases 1-10) including Quick Analysis, Ask Claude, Weekly Report, etc.
- `AI_INSIGHTS_PHASE_11_12_IMPLEMENTATION.md` — Covers Why High/Low and Photo Carb Estimation features.

---

## Phase 1: Cronometer Meal Data in AI Prompts

**Status: COMPLETE**

### What Was Built

Added Cronometer food data to the "Why Am I High/Low" AI analysis prompt. When the AI analyzes why glucose is out of range, it now has access to what the user actually ate (from Cronometer via Apple Health), not just what they manually entered in Trio.

### Why It Matters

Users often enter simplified carb counts in Trio (e.g., "45g carbs") but log full meals in Cronometer (e.g., "pasta with olive oil and chicken — 45g carbs, 18g fat, 25g protein"). The AI can now see the full picture and explain things like "Your late rise is likely from the 18g fat creating extended glucose impact through FPU."

### Key Files

- `HealthDataExporter.swift` — Updated to include Cronometer nutrition data in AI export
- `ClaudeAPIService.swift` — AI prompts now reference Cronometer meal data when available

---

## Phase 2: Cronometer Button & Recommendation View

**Status: COMPLETE**

### What Was Built

A "Crono" button on the treatment page that:
1. Queries Apple Health for the latest Cronometer meal (via snapshot delta system)
2. Applies a personal adjustment factor to the raw Cronometer macros
3. Shows a detailed recommendation view with:
   - Cronometer values vs recommended entry values
   - FPU (Fat Protein Unit) breakdown and duration
   - oref simulation showing predicted BG impact
   - Glucose chart with prediction curve
   - Outcome tracking statistics
   - Adjustable personal factor slider
4. "Apply" button that populates the treatment fields with recommended values

### The Snapshot Delta System

Cronometer writes **cumulative daily totals** to Apple Health — one entry per macro per day, incrementally updated. There is NOT one entry per food item. So we can't just read "the last entry."

Solution: **Snapshot deltas**

- `NutritionSnapshotStore` saves periodic snapshots of the cumulative totals
- A "meal" is inferred from the delta between consecutive snapshots
- `InferredMealEvent` represents a detected meal with `carbsDelta`, `fatDelta`, `proteinDelta`

The `HKObserverQuery` fires when HealthKit data changes, triggering a new snapshot. The delta between the new snapshot and the previous one represents what was just logged.

### The Personal Adjustment Factor

Raw Cronometer values are rarely what you should enter in Trio for dosing. Reasons:
- Cronometer shows total carbs; you may not need to dose for all of them
- Your carb ratio in the pump may already account for some absorption patterns
- Individual variation in how food affects glucose

The adjustment factor (default 0.5, range 0.2-1.5) scales Cronometer macros to Trio entry values. It's learned from meal outcomes over time (see Phase 3).

### The Recommendation Is Logged for Outcome Tracking

Every time the user taps "Apply," a `CronometerMealRecommendation` is saved with:
- Cronometer values (what was detected)
- Recommended values (after factor adjustment)
- Applied values (what the user actually entered — they can modify)
- BG at meal time, carb ratio, ISF
- Predicted eventual BG and min BG from simulation

This data is used later to evaluate outcomes and refine the adjustment factor.

### Key Files

- `TreatmentsStateModel.swift` — `fetchCronometerMeal()`, `calculateCronometerRecommendation()`, `runCronometerSimulation()`, `applyCronometerRecommendation()`
- `CronometerMealRecommendationView.swift` — The full recommendation UI
- `CronometerRecommendation.swift` — `CronometerMealRecommendation` model and `CronometerRecommendationStore` for persistence/outcome tracking
- `NutritionSnapshot.swift` — `NutritionSnapshotStore`, `NutritionSnapshot`, `InferredMealEvent`
- `TreatmentsRootView.swift` — Crono button in the quick-add button row

---

## Phase 3: Meal Outcome Prediction System

**Status: COMPLETE**

### What Was Built

A system that learns from past meals to predict how a new meal will affect glucose. Uses historical meal outcomes to find similar meals and predict:

- Expected BG at 2h, 4h, 6h, 8h, 10h post-meal
- Suggested effective ICR (carb ratio) based on what actually worked for similar meals
- Suggested carb/fat/protein entry factors
- Confidence level based on number of similar meals found

### How It Works

1. **Build Historical Outcomes** (`MealOutcomePredictionService.buildHistoricalOutcomes()`):
   - Fetches all Cronometer recommendations from the last 30 days
   - For each, looks up actual BG readings at 2h, 4h, 6h, 8h, 10h post-meal
   - Finds the closest Trio carb entry to match what was actually entered
   - Creates `HistoricalMealOutcome` with full context

2. **Find Similar Meals** (`predictOutcome()`):
   - Compares the new meal's macros against historical meals
   - Similarity scoring: weighted combination of carb ratio, fat ratio, protein ratio, calorie similarity, time-of-day similarity
   - Takes top 5 most similar meals

3. **Generate Prediction**:
   - Weighted average of similar meals' BG trajectories
   - Derives suggested entry factors from meals with good BG outcomes
   - Blends prediction with historical stored factor (60% predicted, 40% stored)

### Outcome Backfill

Outcomes aren't available immediately — you need to wait 2-10 hours for the BG trajectory. `CronometerRecommendationStore.backfillOutcomes()` runs periodically to:
- Find recommendations that are old enough for outcome data
- Look up actual BG at checkpoint times
- Update the recommendation record with outcomes
- Recalculate the personal adjustment factor based on outcomes

### "Good Outcome" Definition

A meal outcome is considered good (and used for factor learning) when:
- BG stayed below 180 mg/dL at all checkpoints (no significant spike)
- BG stayed above 70 mg/dL at all checkpoints (no low)

### Key Files

- `MealOutcomePrediction.swift` — `HistoricalMealOutcome`, `MealOutcomePrediction`, `MealOutcomePredictionService`
- `CronometerRecommendation.swift` — Outcome tracking, factor recalculation

---

## Phase 4: Coupled Fat/Protein/Carb Dosing

**Status: COMPLETE**

### The Problem

Fat and protein were just passed through at 100% from Cronometer — no learning, no adjustment. But fat/protein entry directly affects insulin dosing through the FPU (Fat Protein Unit) system, and the three macros are **interdependent**.

### How FPU Works (Warsaw Method)

When you enter fat and protein in Trio:
1. `kcal = protein * 4 + fat * 9`
2. `carbEquivalents = (kcal / 10) * individualAdjustmentFactor` (default 0.5)
3. FPU count = carbEquivalents / 10
4. Duration: <2 FPU → 3h, 2-3 → 4h, 3-4 → 5h, ≥4 → timeCap (default 8h)
5. Delay before absorption starts: 60 minutes

These FPU entries are created as **future-dated `CarbEntryStored` records** with `isFPU=true`. The oref algorithm sees them as future COB and delivers extra insulin via SMBs (Super Micro Boluses) and temp basals over the duration period.

### Why the Three Macros Are Coupled

- **More fat/protein entered → more FPU carb-equivalents → more SMBs from the loop → less upfront carb bolus needed**
- **Less fat/protein entered → fewer FPU → less background insulin → more upfront carb bolus needed**
- The initial bolus calculator does NOT include FPU carb-equivalents — those are handled entirely by the loop later

This means you can't learn carb, fat, and protein factors independently. They form a coupled system.

### What Was Built

**Extended `HistoricalMealOutcome`:**
- Added `trioEnteredFat`, `trioEnteredProtein` (what was actually entered in Trio)
- Added computed entry ratios: `carbEntryRatio`, `fatEntryRatio`, `proteinEntryRatio`
- Added late-phase outcome flags: `hadLateRise` (BG > 180 at 4h/6h/8h), `hadLateLow` (BG < 70 at 4h/6h/8h)

**Extended `MealOutcomePrediction`:**
- Added `suggestedCarbFactor`, `suggestedFatFactor`, `suggestedProteinFactor`
- Added `suggestedCarbEntry`, `suggestedFatEntry`, `suggestedProteinEntry`
- Added `estimatedFPUCarbEquivalents`

**Split Learning (early vs late checkpoints):**
- Early BG checkpoints (2h, 4h) → primarily affected by upfront carb bolus → learn carb factor
- Late BG checkpoints (6h, 8h, 10h) → primarily affected by FPU/SMB delivery → learn fat/protein factors
- `CronometerRecommendationStore` now tracks `personalFatFactor()` and `personalProteinFactor()` separately

**Updated `CarbRecord` and queries:**
- `CarbRecord` now includes fat and protein fields
- `fetchAllCarbEntries()` predicate widened to include fat/protein entries
- `findClosestCarbEntry()` returns a tuple: `(carbs: Double, fat: Double, protein: Double)`

**Updated recommendation calculation:**
- `calculateCronometerRecommendation()` uses prediction-informed fat/protein factors when available
- Falls back to stored personal factors from `CronometerRecommendationStore`
- FPU carb equivalents calculated from RECOMMENDED fat/protein (not raw Cronometer values)

**Updated recommendation view:**
- Shows macro-by-macro breakdown with scaling: "Cronometer: 60g → Recommended: 48g (×0.80)"
- FPU interaction insight explaining how fat/protein → SMBs → less upfront carb bolus
- Total insulin coverage summary (upfront bolus + FPU-driven SMBs)

### Key Files

- `MealOutcomePrediction.swift` — Extended with coupled factor computation
- `CronometerRecommendation.swift` — Fat/protein factor storage and split learning
- `TreatmentsStateModel.swift` — `calculateCronometerRecommendation()` updated for coupled factors
- `CronometerMealRecommendationView.swift` — Updated UI showing all three macros

---

## Phase 5: Snapshot Delta Reliability & Log Button

**Status: COMPLETE**

### Problems Solved

**Problem 1: "No recent Cronometer meal detected"**

The `inferredMealEvents()` method required 2+ snapshots to compute a delta. With only 1 snapshot (e.g., first food of the day), it returned empty. The HKObserverQuery wasn't reliable enough to guarantee snapshots were recorded.

**Solution:** Added `fetchLatestMealDelta()` to `NutritionHealthService` — a LIVE HealthKit query that runs when the Crono button is tapped. It fetches current cumulative totals, saves a fresh snapshot, and computes the delta from the previous snapshot. This works even if the observer never fired.

**Problem 2: Showing whole day's totals instead of last meal**

An initial fix added a midnight baseline (synthetic 0g snapshot at midnight). But since Cronometer daily totals start at zero and accumulate, this turned the entire day's cumulative total into one giant "meal."

**Solution:** Reverted the midnight baseline in `inferredMealEvents()`. The midnight baseline is only used in `recordAndComputeLatestMeal()` when no prior snapshot exists (truly first food of the day). The live query approach handles the common case correctly.

**Problem 3: Undosed meals accumulating into next meal's delta**

When food is logged for a low treatment (e.g., juice) without dosing (user doesn't open Trio), no snapshot is recorded. The next Crono button tap shows the delta from the last snapshot, which includes both the undosed food AND the new meal.

**Solution (two-pronged):**

1. **Observer auto-start at app launch (primary fix):** The `HKObserverQuery` was only started when the HealthKit settings view was opened — NOT at app launch. Fixed by:
   - Resolving `NutritionHealthService` in `TrioApp.loadServices()` so it's created at startup
   - Auto-starting the observer in `BaseNutritionHealthService.init()` when `readNutritionFromHealth` is enabled
   - This ensures snapshots are recorded automatically whenever Cronometer writes to Apple Health, even if the user never visits the HealthKit settings view

2. **"Log" button (secondary fix / UX improvement):** A green "Log" button on the treatment page that:
   - Records a snapshot of current HealthKit nutrition totals (establishing a baseline)
   - Opens the Cronometer app via URL scheme (`cronometer://`)
   - The user trains themselves to always use this button to open Cronometer
   - When they come back and tap "Crono," the delta only includes food logged after the baseline

**The two buttons serve different purposes:**
- **Log** (green, `arrow.up.forward.app` icon) — Open Cronometer to enter food (snapshots first)
- **Crono** (orange, `fork.knife` icon) — Import the food you just logged and get dosing recommendations

### Key Files

- `NutritionHealthService.swift` — `fetchLatestMealDelta()`, observer auto-start in init
- `NutritionSnapshot.swift` — `recordAndComputeLatestMeal()`
- `TreatmentsStateModel.swift` — `recordCronometerBaseline()`, updated `fetchCronometerMeal()`
- `TreatmentsRootView.swift` — Log button, compact button layout
- `TrioApp.swift` — Resolves `NutritionHealthService` in `loadServices()`

---

## Phase 5b: Late Dosing with Meal Picker

**Status: COMPLETE**

### The Problem

User eats lunch at noon, logs it in Cronometer, but gets distracted and forgets to dose. At 12:45 they realize. They tap Crono, but the live delta shows nothing new (no food logged in the last 15 minutes). Previously this showed an error — now the system searches further back and lets them pick which meal to dose for, with a decay-adjusted recommendation.

### The Flow

```
User taps Crono at 12:45
  → fetchLatestMealDelta() → no new delta → nil
  → Search today's grouped meals from snapshot history
  → Found: [Breakfast 8:00 — 45g C, 12g F, 8g P]
           [Lunch 12:02 — 62g C, 18g F, 25g P]
  → Present meal picker: "Select meal to dose for"
  → User selects Lunch (12:02)
  → System calculates: meal is 43 minutes old
  → Apply carb decay model (hybrid: time-based + BG-informed)
  → Show adjusted recommendation:
      "This meal was 43 min ago.
       ~28g carbs remaining of 62g (55% absorbed).
       Fat/protein: unchanged (FPU delay hasn't started yet).
       Current BG: 165↑, IOB: 0.8U"
```

### Carb Decay Model (Hybrid Approach)

**Time-based decay (primary estimate):**

Uses an exponential decay curve calibrated to typical carb absorption:
```
remainingFraction = exp(-0.025 * minutesSinceMeal)
```
- T+0:   100% remaining
- T+15:  ~69% remaining
- T+30:  ~47% remaining
- T+45:  ~32% remaining
- T+60:  ~22% remaining
- T+90:  ~11% remaining
- T+120: ~5% remaining

**BG-informed cross-check:**

The actual BG rise tells us how much has already absorbed:
```
bgRise = currentBG - bgAtMealTime (approximated from glucose history)
estimatedCarbsAbsorbed = bgRise / ISF * CR
bgInformedRemaining = totalCarbs - estimatedCarbsAbsorbed
```

**Hybrid blend:** Take the MINIMUM of the two estimates (more conservative = safer):
```
remainingCarbs = min(timeBasedRemaining, bgInformedRemaining)
```

If BG hasn't risen much (slow-absorbing meal, or insulin already on board), the time-based estimate is used. If BG has risen a lot (fast-absorbing meal), the BG-informed estimate captures that more carbs are already absorbed.

### Fat/Protein Handling for Late Doses

FPU absorption has a built-in 60-minute delay before it starts. This means:
- **0-60 min late:** Fat/protein recommendation is UNCHANGED — the delay hasn't elapsed
- **60-120 min late:** Reduce fat/protein proportionally (FPU absorption has started)
- **>120 min late:** Further reduction, but the loop's SMBs are already handling it

```swift
fpuRemainingFraction:
  minutesSinceMeal < 60:  1.0  (full — delay period hasn't started)
  minutesSinceMeal < 120: 1.0 - ((minutesSinceMeal - 60) / fpuDuration * 60)
  otherwise:              max(0, 1.0 - ((minutesSinceMeal - 60) / (fpuDuration * 60)))
```

### Already-Dosed Detection

The meal picker cross-references each meal against:
1. `CronometerRecommendationStore` — was a recommendation already applied for this meal?
2. Time proximity — is there a `CronometerMealRecommendation` within 30 minutes of the meal?

Meals that were already dosed show a warning badge and are still selectable (in case the user wants to dose again for a different reason), but the UI makes it clear.

### Safety Guardrails

- Meals >3 hours old show a warning: "Most carbs likely absorbed. Late dosing may cause a low."
- Meals >4 hours old are greyed out with: "Too old for carb dosing. The loop has already compensated."
- The decay model never recommends MORE insulin than a fresh dose would — only less.
- The oref simulation runs with the decay-adjusted values, accounting for current BG, IOB, and trend.

### Key Files

- `NutritionSnapshot.swift` — `CarbDecayModel` with hybrid time+BG decay calculation
- `CronometerMealPickerView.swift` — Meal selection UI with age, remaining carbs, already-dosed badges
- `TreatmentsStateModel.swift` — `cronometerAvailableMeals`, `selectCronometerMeal()`, decay-adjusted recommendation
- `CronometerMealRecommendationView.swift` — Late meal banner showing elapsed time and decay info
- `TreatmentsRootView.swift` — Meal picker sheet wiring

---

## Phase 6: Background Auto-Detection & Notification Dosing

**Status: PLANNED — NOT YET IMPLEMENTED**

### Vision

Eliminate the manual steps entirely. The app runs in the background, detects when food is logged in Cronometer, computes the dose, and asks the user to confirm via a push notification on the lock screen.

### The Flow

```
Cronometer write detected via HKObserverQuery
  → Compute meal delta (what was just logged)
  → Apply learned entry factors (personal history)
  → Query current state:
      - Current BG + trend (from CGM)
      - Current IOB (from loop state)
      - Current COB (from loop state)
      - Activity/workout data (from HealthKit or Garmin — see Phase 7)
  → Run oref simulation with the adjusted meal
  → Get insulin recommendation
  → Safety checks (see below)
  → Push notification:
      "Cronometer: 45g carbs, 12g fat, 20g protein
       Recommend 3.2U bolus
       [Deliver] [Adjust] [Skip]"
  → User taps Deliver from lock screen
  → Bolus enacted, carbs/fat/protein logged to loop
```

### Safety Guardrails (Tiered)

**Hard limits (never exceed, non-negotiable):**
- Never auto-dose if BG < 80 mg/dL or trending down fast
- Never exceed the user's configured max bolus
- Never dose if IOB is already above max IOB
- Never dose within 30 minutes of a previous bolus (stacking protection)
- Never auto-dose if CGM data is stale (>15 min old)
- Never dose if the loop hasn't run successfully recently

**Confidence-based behavior:**
- **High confidence** (5+ similar meals with good outcomes, stable BG, moderate IOB): Push notification with "Deliver" as primary action — one tap to dose
- **Medium confidence** (fewer similar meals, or BG slightly elevated, or higher IOB): Push notification but require full app open to confirm
- **Low confidence** (novel meal, volatile BG, high IOB, recent workout): Notification says "Review recommended" — forces app open and shows full recommendation view

### Why This Is Feasible (Not Reckless)

1. **The loop already handles the hard math** — oref accounts for IOB, COB, BG trends, sensitivity. We're just feeding it better inputs.
2. **The user already trusts the Crono recommendation** — this just removes the manual steps of open app → tap Crono → review → apply → enact.
3. **The learning system already exists** — meal prediction, coupled factors, outcome tracking provide the confidence score.
4. **Worst case = the loop corrects it** — if the auto-dose is slightly wrong, the loop's SMBs and temp basals adjust. The loop is already the safety net. Front-loading what the loop would eventually do via SMBs is actually safer (one calculated bolus vs many small corrections chasing a spike).

### The Timing Problem

When the observer fires, the user might be:
- About to eat (ideal — dose now)
- Currently eating (still fine)
- Already ate 30 min ago and is just now logging (dose is late but still helpful)
- Pre-logging food they'll eat later (dangerous to dose now)

The push notification with confirm/skip handles this naturally — the user knows their context. If they don't respond within X minutes, the notification expires and no dose is given.

### Implementation Requirements

1. **Background processing service** — responds to observer, gathers context, runs simulation
2. **Confidence scoring engine** — based on meal similarity, BG stability, IOB headroom, data freshness
3. **Rich push notifications** — iOS `UNNotificationAction` with actionable buttons from lock screen
4. **Dose-from-notification handler** — enact bolus + log carbs from background when user taps "Deliver"
5. **Notification expiry** — auto-dismiss if not acted upon within configurable timeout

### Progression

- **Phase 6a:** Notification-only (no dosing) — "Cronometer detected a meal: 45g carbs. Tap to open Trio."
- **Phase 6b:** Notification with one-tap dosing — "Recommend 3.2U. [Deliver] [Skip]"
- **Phase 6c:** Full auto for high-confidence meals — dose first, notify after: "Dosed 3.2U for detected 45g carb meal. [Undo within 60s]"

---

## Phase 7: Garmin/Firestore Context Integration

**Status: PLANNED — NOT YET IMPLEMENTED**

### The Data Advantage

A Firebase Firestore database already exists with comprehensive Garmin Health API data, written directly via the Garmin Connect API. Every time the watch syncs to Garmin Connect, all health data is pushed to Firestore. Last 30 days are available.

### Why Firestore > HealthKit for Garmin Data

HealthKit gets a watered-down version of Garmin data. Apple Health receives: steps, heart rate samples, workouts, sleep duration. But the Garmin Health API provides the **full picture** — most of which never touches HealthKit:

| Data Point | HealthKit | Garmin API (Firestore) |
|---|---|---|
| Steps | Yes | Yes |
| Heart Rate | Samples only | Continuous + resting + zones |
| Sleep Duration | Yes | Yes |
| Sleep Stages | Basic | Full (deep/light/REM/awake) + quality score |
| Sleep Score | No | Yes |
| Body Battery | No | Yes (continuous throughout day) |
| Stress Level | No | Yes (continuous scoring) |
| HRV | Basic | Full + 7-day baseline + deviation |
| Training Load | No | Yes (acute/chronic, recovery time) |
| Training Status | No | Yes (productive/recovery/overreaching) |
| Respiration Rate | No | Yes (continuous) |
| Pulse Ox (SpO2) | Limited | Full overnight trends |
| VO2 Max | No | Yes + trends |
| Intensity Minutes | No | Yes (moderate vs vigorous) |

### Why These Metrics Matter for Insulin Dosing

Each of these signals affects insulin sensitivity:

- **Poor sleep** = insulin resistance next day (15-30% increase in needs, well-documented)
- **High stress / low Body Battery** = cortisol = insulin resistance
- **More activity** = increased insulin sensitivity (can last 24-48h)
- **Elevated resting HR** = illness/stress/poor recovery = resistance
- **Low HRV** = sympathetic dominance = resistance
- **Overreaching training status** = systemic stress = resistance

### Architecture

```
Garmin Watch
  → Garmin Connect (cloud sync)
    → Garmin Health API webhook
      → Firebase Cloud Function
        → Firestore (structured collections, 30-day rolling window)

At meal detection time in Trio:
  Trio → Firestore query (today's data + last night's sleep)
    → GarminContextSnapshot built
      → Fed into sensitivity model (Phase 8)
        → Adjusted dose recommendation
```

### Configuration in Trio

Minimal setup needed:
- Firebase project configuration (GoogleService-Info.plist or manual config)
- Firestore collection path (where Garmin data lives)
- Read-only access (Trio only queries, never writes)
- Toggle in Settings to enable/disable Garmin context

### Context Snapshot at Meal Time

When a meal is detected, the system queries Firestore and builds a `GarminContextSnapshot`:

```swift
struct GarminContextSnapshot {
    // Sleep (last night)
    let sleepScore: Int?             // 0-100
    let sleepDuration: TimeInterval?
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let averageSpO2: Double?

    // Recovery / Stress (current)
    let bodyBattery: Int?            // 0-100
    let currentStress: Int?          // 0-100
    let averageStressToday: Int?
    let restingHR: Int?
    let restingHRBaseline: Int?      // 7-day avg for comparison
    let hrvStatus: Double?           // vs baseline

    // Activity
    let stepsToday: Int?
    let activeCaloriesToday: Int?
    let intensityMinutesToday: Int?
    let workoutsToday: [WorkoutSummary]?

    // Activity (yesterday, for delayed sensitivity effects)
    let stepsYesterday: Int?
    let activeCaloriesYesterday: Int?
    let workoutsYesterday: [WorkoutSummary]?

    // Training
    let trainingLoad: String?        // "low"/"optimal"/"high"/"very high"
    let trainingStatus: String?      // "productive"/"recovery"/"overreaching"
    let recoveryTimeHours: Int?
}
```

### Immediate Use (Before ML Model)

Even before building the on-device ML model (Phase 8), this data can be:
1. **Passed to Claude AI** in the existing analysis prompts — Claude can reason about how sleep/stress/activity affected glucose and suggest adjustments
2. **Displayed in the recommendation view** — "Note: Sleep score was 58 last night (below your avg of 72). You may need more insulin today."
3. **Used in the Weekly Report** — correlate glucose patterns with Garmin data to surface insights

---

## Phase 8: Personalized Sensitivity Model

**Status: PLANNED — NOT YET IMPLEMENTED**

### The Problem

Currently, the carb/fat/protein adjustment factors treat every day the same. But insulin sensitivity varies massively day-to-day based on sleep, stress, activity, and recovery. The same meal might need 3U one day and 4U the next.

### Why Rules Won't Work

You can't hardcode "bad sleep = multiply dose by 1.15" because:
1. The factors **interact** — bad sleep + high stress + sedentary day compounds non-linearly
2. Effects are **personal** — some people are very sleep-sensitive, others less so
3. **Magnitude varies** — one person might need 20% more insulin after bad sleep, another 10%
4. **Timing of effect** varies — stress hits immediately, poor sleep peaks mid-morning

This is genuinely a machine learning problem.

### Three Possible Approaches

**Approach A: On-device regression model (simpler, fast, private)**
- Features: ~15-20 inputs from Garmin context + meal macros + current BG/IOB/COB + time of day
- Target: effective ICR for this meal (derived from BG outcome)
- Model type: gradient-boosted tree or simple linear model with interaction terms
- Trains on user's data only — fully personalized
- Needs ~50-100 meals with outcomes to start being useful
- Runs on-device via CoreML — millisecond inference, no network needed
- Fully private — no data leaves the device

**Approach B: Claude API contextual adjustment (more powerful, needs network)**
- Send full context to Claude with meal: macros, Garmin data, last 30 similar meals with contexts and outcomes
- Claude reasons about interactions in ways a simple model can't
- More flexible, handles novel situations, can incorporate new signal types without retraining
- But: requires API call, latency, cost per meal

**Approach C: Hybrid (recommended)**
- On-device model does fast prediction: `sensitivityFactor = 0.85` (15% more resistant than baseline)
- This runs instantly when observer fires — no network latency
- Claude API does periodic retrospective analysis (e.g., weekly): "Your model is underweighting sleep quality — here's updated weighting"
- Claude essentially tunes the on-device model's parameters
- Best of both: fast local inference for dosing, smart periodic recalibration

### Model Features

```
Input features for sensitivity prediction:
├── Sleep (last night)
│   ├── Sleep score (0-100)
│   ├── Deep sleep percentage
│   ├── Duration (hours)
│   └── SpO2 average
├── Stress / Recovery (current)
│   ├── Body Battery level
│   ├── Current stress level
│   ├── Average stress today
│   ├── Resting HR delta from 7-day baseline
│   └── HRV delta from baseline
├── Activity
│   ├── Today's active calories vs 14-day average
│   ├── Yesterday's active calories vs 14-day average
│   ├── Today's intensity minutes
│   ├── Yesterday's workout intensity/duration
│   └── Training load status (encoded)
├── Temporal
│   ├── Time of day (encoded, captures dawn phenomenon etc.)
│   └── Day of week (encoded, captures work-week patterns)
├── Meal
│   ├── Carbs, fat, protein
│   └── Meal similarity to known meals
└── Current state
    ├── Current BG
    ├── BG trend (delta)
    ├── Current IOB
    └── Current COB

Target: effective ICR = (BG_rise_attributable_to_carbs) / (insulin_delivered)
```

### What the Model Would Discover

Over time, the model finds patterns no human would notice:
- "Insulin needs spike on days after < 6h sleep, but only if stress is also above 50"
- "Monday mornings need 25% more insulin — dawn phenomenon + work stress resuming"
- "After a strength training day, dinner needs 30% less insulin but next breakfast needs 15% more"
- "When Body Battery drops below 20 by lunch, afternoon carb ratio needs to be more aggressive"
- "Post-cardio sensitivity lasts 18 hours for this person but only 8 hours for anaerobic exercise"

### Implementation Steps

1. **Garmin data pipeline** (Phase 7 prerequisite) — Firestore query → structured context
2. **Feature engineering layer** — transform raw data into model features (rolling averages, deltas from baseline, encoding)
3. **Outcome labeling** — for each meal, compute effective ICR from BG trajectory vs insulin (meal outcome tracking already exists from Phase 3)
4. **On-device model training** — CoreML supports on-device training for simple models via Create ML
5. **Context snapshot service** — gathers all signals into one `SensitivityContext` at meal detection time
6. **Sensitivity factor integration** — model output feeds into existing dose calculation as a multiplier
7. **Claude periodic recalibration** — weekly analysis of model accuracy, parameter tuning suggestions

---

## Architecture Overview

### Current Data Flow (Phases 1-5b, implemented)

```
Cronometer App
  → Apple Health (cumulative daily totals)
    → HKObserverQuery fires in Trio (auto-started at app launch)
      → NutritionSnapshotStore saves snapshot
        → Consecutive snapshots within 15 min grouped as one meal

User taps "Log" button:
  → Snapshot baseline recorded → Cronometer app opens via URL scheme

User taps "Crono" button:
  → fetchLatestMealDelta() [live HealthKit query]
    → Recent meal found? → Apply learned carb/fat/protein factors
      → Run oref simulation
        → Show recommendation view
          → User taps Apply
            → Treatment fields populated
              → User adjusts bolus and taps Enact
                → Insulin delivered + carbs/fat/protein logged
                  → Outcome tracked over next 2-10 hours
                    → Factors recalibrated from outcomes
    → No recent meal found? → Search today's grouped meals
      → Present CronometerMealPickerView
        → User selects a meal
          → Apply carb decay model (time-based + BG-informed hybrid)
          → Apply FPU decay with 60-min delay awareness
            → Show recommendation with late-meal banner
              → (continues as above)
```

### Future Data Flow (Phases 6-8, planned)

```
Cronometer App
  → Apple Health
    → HKObserverQuery fires in Trio (background)
      → Meal delta computed
      → Garmin context fetched from Firestore
      → Sensitivity model runs (CoreML, on-device)
      → oref simulation with context-adjusted meal
      → Safety checks pass
      → Rich push notification sent
        → User taps "Deliver" from lock screen
          → Bolus enacted + meal logged (background)
            → Outcome tracked
              → Model retrained periodically
                → Claude reviews model weekly
```

### Key Services and Their Roles

| Service | Role | Status |
|---|---|---|
| `NutritionHealthService` | HealthKit queries, observer, snapshot management | Implemented |
| `NutritionSnapshotStore` | Snapshot persistence, delta computation | Implemented |
| `MealOutcomePredictionService` | Historical outcome analysis, meal similarity | Implemented |
| `CronometerRecommendationStore` | Recommendation persistence, factor learning | Implemented |
| `GarminContextService` | Firestore queries for Garmin health data | Planned (Phase 7) |
| `SensitivityModelService` | On-device ML model for daily sensitivity | Planned (Phase 8) |
| `BackgroundMealDosing` | Auto-detection → notification → dosing | Planned (Phase 6) |

---

## Key Technical Decisions

### 1. Snapshot Deltas vs Individual Entry Detection

**Decision:** Snapshot deltas (cumulative total diffs between checkpoints)

**Reason:** Cronometer writes cumulative daily totals to Apple Health, not individual food entries. There's only one timestamp per macro per day, incrementally updated. We can't distinguish individual meals from the raw data — we can only detect changes in the cumulative total.

### 2. Observer Auto-Start at App Launch

**Decision:** Resolve `NutritionHealthService` in `loadServices()` and auto-start observer in init

**Reason:** The observer was only started when the HealthKit settings view was opened. If the app restarted (common), no snapshots were recorded until the user visited settings. This caused meal deltas to accumulate across multiple food entries.

### 3. Coupled Macro Factors (Not Independent)

**Decision:** Learn carb, fat, and protein entry factors as a coupled system

**Reason:** FPU entries create future carb-equivalents that the loop handles via SMBs. Entering more fat/protein → more background insulin → less upfront carb bolus needed. The three macros are interdependent, not independent dials.

### 4. Split Learning: Early vs Late Checkpoints

**Decision:** Early BG checkpoints (2h/4h) → carb factor; Late checkpoints (6h/8h/10h) → fat/protein factors

**Reason:** Upfront carb bolus dominates early glucose response. FPU-driven SMBs dominate late glucose response. Using the right checkpoints for the right factors prevents cross-contamination.

### 5. Hybrid Model (On-Device + Claude)

**Decision:** Fast on-device model for real-time dosing, Claude for periodic recalibration

**Reason:** Dosing decisions need millisecond latency (especially for auto-dose notifications). Can't wait for an API call. But Claude excels at finding subtle patterns, explaining them, and suggesting model adjustments — tasks that can happen asynchronously.

### 6. 15-Minute Meal Grouping Window

**Decision:** Group consecutive snapshots within 15 minutes as a single meal

**Reason:** Cronometer writes one HealthKit update per food item. A meal with 4 items (bread, almond butter, blueberries, honey) produces 4 separate observer fires and 4 snapshots. Without grouping, the Crono button only showed the last item's delta. The grouping algorithm walks backwards through snapshots, accumulating any within 15 minutes into a single meal cluster, then computes the delta from the pre-cluster baseline.

### 7. Hybrid Carb Decay Model (Time-Based + BG-Informed)

**Decision:** Take the minimum of time-based exponential decay and BG-informed absorption estimate

**Reason:** For late dosing, we need to estimate how many carbs remain unabsorbed. Time-based decay (`exp(-0.025 * minutes)`) gives a reasonable estimate but can't account for individual meal composition or current insulin action. BG-informed estimation (`bgRise * CR / ISF`) uses actual glucose rise to infer absorption. Taking the minimum of the two is more conservative (safer) — it prevents overdosing in cases where either model is inaccurate.

### 8. Firestore for Garmin Data (Not HealthKit)

**Decision:** Read Garmin data from existing Firestore database via Garmin Health API

**Reason:** HealthKit only gets a subset of Garmin data. The most important signals for insulin sensitivity (Body Battery, stress scores, training load, detailed sleep stages) are Garmin-proprietary and never reach HealthKit. The Firestore database already has all of this, structured and queryable.

---

## File Reference

### Implemented Files

| File | Purpose |
|---|---|
| `Trio/Sources/Models/NutritionSnapshot.swift` | `NutritionSnapshot`, `NutritionSnapshotStore`, `InferredMealEvent` (with `minutesAgo`, `timeAgoString`), `CarbDecayModel` (hybrid time+BG decay, FPU decay, warning levels), 15-minute meal grouping in `recordAndComputeLatestMeal()` and `inferredMealEvents()` |
| `Trio/Sources/Models/MealOutcomePrediction.swift` | `HistoricalMealOutcome`, `MealOutcomePrediction`, `MealOutcomePredictionService`, `CarbRecord` |
| `Trio/Sources/Models/CronometerRecommendation.swift` | `CronometerMealRecommendation`, `CronometerRecommendationStore`, factor learning, outcome backfill |
| `Trio/Sources/Services/HealthKit/NutritionHealthService.swift` | HealthKit nutrition queries, observer, `fetchLatestMealDelta()`, auto-start |
| `Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift` | `fetchCronometerMeal()` (with meal picker fallback), `selectCronometerMeal()` (late dosing with decay), `approximateBGAtTime()`, `calculateCronometerRecommendation()`, `runCronometerSimulation()`, `applyCronometerRecommendation()`, `recordCronometerBaseline()` |
| `Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift` | Crono button, Log button, compact button layout, meal picker sheet |
| `Trio/Sources/Modules/Treatments/View/CronometerMealRecommendationView.swift` | Full recommendation UI with macros, FPU, simulation, prediction, late-meal banner |
| `Trio/Sources/Modules/Treatments/View/CronometerMealPickerView.swift` | Meal selection UI for late dosing — shows today's grouped meals with age, remaining carbs, already-dosed badges, decay warnings |
| `Trio/Sources/Application/TrioApp.swift` | `NutritionHealthService` resolved at startup in `loadServices()` |

### Planned Files (Phase 6+)

| File | Purpose |
|---|---|
| `Trio/Sources/Services/Garmin/GarminContextService.swift` | Firestore queries for Garmin health data |
| `Trio/Sources/Models/GarminContextSnapshot.swift` | Structured Garmin data at meal time |
| `Trio/Sources/Services/BackgroundMealDosingService.swift` | Observer → context → simulate → notify → dose |
| `Trio/Sources/Models/SensitivityModel.swift` | On-device ML model for daily sensitivity factor |
| `Trio/Sources/Services/NotificationDosingService.swift` | Rich push notifications with actionable dose buttons |

---

## Commit History

| Commit | Description |
|---|---|
| 1 | Feed Cronometer food data into AI "Why High/Low" prompt |
| 2 | Add Cronometer button to treatment page with recommendation view |
| 3 | Build meal outcome prediction system |
| 4 | Fat/protein recommendations coupled with carbs |
| 5 | Fix "no recent meal" — add midnight baseline (later partially reverted) |
| 6 | Fix whole-day totals — live HealthKit query, `recordAndComputeLatestMeal()` |
| 7 | Start nutrition observer at app launch + add Log Food button |
| 8 | Make quick-add buttons fit on one line |
| 9 | Fix meal grouping — group snapshots within 15 minutes as single meal |
| 10 | Late dosing with meal picker, carb decay model, FPU decay, BG-informed hybrid |
| 11 | Fix Decimal→Double conversion for individualAdjustmentFactor |
