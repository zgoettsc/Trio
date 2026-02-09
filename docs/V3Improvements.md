# V3 Improvements — Safety, Logic, and UX/UI Redesign

**Date:** February 9, 2026
**Sources:** Code review of V2 implementation, whitepaper comparison, UX audit of current treatment flow
**Scope:** Insulin safety fixes, logic corrections, complete treatment UX redesign, settings consolidation

---

## Table of Contents

- [Part 1: Insulin Safety Improvements](#part-1-insulin-safety-improvements)
- [Part 2: Logic Corrections](#part-2-logic-corrections)
- [Part 3: UX/UI Redesign — Treatment Flow](#part-3-uxui-redesign--treatment-flow)
- [Part 4: UX/UI Redesign — Settings Consolidation](#part-4-uxui-redesign--settings-consolidation)
- [Part 5: Implementation Plan](#part-5-implementation-plan)

---

## Part 1: Insulin Safety Improvements

### S1. Meal-Attributed IOB Must Model Insulin Decay

**Priority: HIGH**
**Risk: Over-delivery of insulin in the 6-8h window for high-fat meals**

**Current state:**
`MacroAdaptiveService.recordMealInsulin()` (`MacroAdaptiveService.swift:313-315`) is a pure accumulator. It adds every unit of insulin delivered for a meal but never subtracts for insulin that has decayed. For an 8-hour pizza meal, the 3U upfront bolus given at t=0 has mostly decayed by t=6h (DIA is typically 4-6h), but `mealAttributedIOB` still reports the full 3U.

**How this causes harm:**
The BG-adaptive prediction formula (`MacroAdaptiveService.swift:269`) is:
```
predictedBGImpact = (absorbedCarbs / cr) × ISF − mealIOB × ISF
```
When `mealIOB` is overstated (because it doesn't model decay), `predictedBGImpact` becomes more negative than reality. This makes `error = actualBGDelta − predictedBGImpact` more positive. A positive error means "BG is higher than predicted" which causes the adaptive service to scale UP remaining entries. The system delivers more insulin in the 6-8h window than needed.

The cumulative clamp (2.0x) and BG floor (80 mg/dL) limit damage, but this is a systematic bias toward over-delivery for exactly the meals where V2 matters most — long, high-fat meals.

**Fix:**
Apply an exponential decay curve to recorded insulin using the user's DIA setting. When `getMealAttributedIOB(mealID:)` is called, iterate through recorded insulin events and discount each by its age:

```swift
struct MealInsulinRecord {
    let units: Double
    let timestamp: Date
}

private var mealInsulinRecords: [String: [MealInsulinRecord]] = [:]

func recordMealInsulin(mealID: String, units: Double) {
    var records = mealInsulinRecords[mealID] ?? []
    records.append(MealInsulinRecord(units: units, timestamp: Date()))
    mealInsulinRecords[mealID] = records
}

func getMealAttributedIOB(mealID: String, dia: TimeInterval) -> Double {
    guard let records = mealInsulinRecords[mealID] else { return 0 }
    let now = Date()
    return records.reduce(0.0) { total, record in
        let age = now.timeIntervalSince(record.timestamp)
        let fractionRemaining = max(0, 1.0 - age / dia)
        return total + record.units * fractionRemaining
    }
}
```

**Where DIA comes from:** The user's `insulin_action_curve` setting, already available in the profile via `storage.retrieve(OpenAPS.Settings.settings)`. Pass it into `runAdaptiveCycle()` alongside `isf` and `cr`.

**Persistence:** The `MealInsulinRecord` array should be persisted alongside cumulative scaling in UserDefaults (same pattern as #9) so it survives app restarts. Records older than DIA + 1 hour can be pruned on load.

**Testing:**
- Unit test: Record 3U at t=0, check IOB at t=0 (should be 3U), at t=DIA/2 (should be ~1.5U), at t=DIA (should be ~0U)
- Integration test: Verify that for an 8h meal, the adaptive service does NOT scale up late entries when early insulin has decayed

---

### S2. Add Composite Ceiling Check for Compounding Multipliers

**Priority: HIGH**
**Risk: Theoretical insulin delivery up to 3.34x original amount at 3x delivery rate**

**Current state:**
Three independent multipliers can compound without any cross-check:
- Garmin demand factor: up to 1.67x (from `GarminSensitivityModel`, applied in `MacroAbsorptionEngine.generateEntries()`)
- BG-adaptive cumulative scaling: up to 2.0x (from `MacroAdaptiveService.scaleFutureEntries()`)
- Meal-mode SMB multiplier: up to 3.0x delivery rate (from `MealModeState.evaluate()`)

In a worst case, entries could be 1.67 × 2.0 = **3.34x their original carb-equivalent**, delivered at 3.0x the normal SMB rate. oref's `maxIOB` is the hard ceiling, but within that limit, the system can push significantly more insulin than V1 for the same meal.

**Fix:**
Add a composite demand ceiling that caps the product of demand factor × adaptive scaling:

```swift
// In MacroAdaptiveService.scaleFutureEntries(), after computing effectiveFactor:
let compositeDemand = (cumulativeScaling[mealID] ?? 1.0) * originalDemandFactor
let maxCompositeDemand = 2.5 // Never deliver more than 2.5x the base engine calculation
if compositeDemand > maxCompositeDemand {
    // Reduce the scaling to stay within ceiling
    let allowedCumulative = maxCompositeDemand / originalDemandFactor
    cumulativeScaling[mealID] = allowedCumulative
}
```

The `originalDemandFactor` (from Garmin) needs to be stored per meal — it's already in `MacroAbsorptionResult.insulinDemandFactor` and recorded in `V2MealOutcome.insulinDemandFactor`, so the adaptive service can look it up.

A ceiling of 2.5x means: even with terrible sleep (1.67x demand) AND the adaptive service scaling up by 50%, the total stays at 2.5x. The adaptive service can still scale down to 0.0x (cancel entries) — the ceiling only limits the upside.

**Where to implement:** `MacroAdaptiveService.scaleFutureEntries()`, after the cumulative scaling update on line 381. The demand factor per meal should be passed into `runAdaptiveCycle()` or looked up from the stored outcome.

**Make it configurable:** Add a `maxCompositeDemandMultiplier` to the V2 settings (range 1.5–3.5, default 2.5) so experienced users can widen or narrow the ceiling.

---

### S3. Cap the Fat Coefficient Slider to Match Learning Clamp

**Priority: MEDIUM**
**Risk: User accidentally sets fat coefficient to 2.0, generating 80g carb-equivalent for a 40g fat meal**

**Current state:**
The fat coefficient slider in `V2MacroDosingSettingsView.swift:119` allows values up to 2.00. But the outcome learning system clamps at 1.20 (`V2CurveOutcomeLearning.swift`). At 2.00, a 40g fat meal generates `fatCarbEquivalent(40, maxCoeff: 2.0)` = 40 × 2.0 = 80g carb-equivalent in fat entries alone — an enormous insulin commitment over 2-9 hours.

**Fix:**
Reduce the slider upper bound from 2.00 to 1.20 to match the learning clamp:

```swift
// V2MacroDosingSettingsView.swift:119
Slider(value: $fatCoefficient, in: 0.30 ... 1.20, step: 0.01)
```

**Rationale:** If the learning system considers 1.20 the safe maximum, the manual slider should not exceed it. A user who genuinely needs more than 1.20 has an unusual physiology that the system should learn toward rather than jump to. The Wolpert (2013) study found 0.55 as the mean coefficient — 1.20 is already 2.2x that.

---

### S4. Validate proteinPlateau > proteinThreshold in UI

**Priority: MEDIUM**
**Risk: Setting threshold=30 and plateau=20 breaks the smooth ramp, creates a hard cutoff**

**Current state:**
The protein threshold slider (`V2MacroDosingSettingsView.swift:154`) allows 5-30g. The protein plateau slider (line 170) allows 20-80g. A user can set threshold=30 and plateau=20. The `proteinGlucoFactor` function doesn't crash — it degrades to: return 0 for anything ≤ 30g, return maxFactor for anything ≥ 20g (which is checked second). For protein between 20-30g, the first guard (`proteinGrams <= threshold`) catches it and returns 0. For protein > 30g, it returns maxFactor immediately via the plateau check. The intended smooth ramp disappears entirely.

**Fix:**
Add a validation constraint in the slider onChange:

```swift
// In proteinThreshold slider onChange:
.onChange(of: proteinThreshold) { _, newValue in
    if newValue >= proteinPlateau {
        proteinPlateau = newValue + 5 // Push plateau ahead
    }
    saveCurveParameter { $0.proteinThreshold = newValue }
}

// In proteinPlateau slider onChange:
.onChange(of: proteinPlateau) { _, newValue in
    if newValue <= proteinThreshold {
        proteinThreshold = newValue - 5 // Push threshold back
    }
    saveCurveParameter { $0.proteinPlateau = newValue }
}
```

Also add a visual warning if the values are within 5g of each other: "Threshold and plateau are very close — the protein ramp will be steep."

---

### S5. Add IOB Decay to Gate 5 for Accuracy

**Priority: LOW**
**Risk: Gate 5 is overly restrictive when IOB is high but mostly decayed**

**Current state:**
Gate 5 (`MacroAdaptiveService.swift:69-71`) compares `currentIOB` (total system IOB) against `remainingInsulinNeed`. This is total system IOB from oref, which already accounts for decay. But the "remaining insulin need" calculation uses raw remaining carbs without considering that some of those carbs are hours away and the insulin for them doesn't need to be on board yet.

**Fix:**
Weight the remaining carbs by temporal proximity:

```swift
// Instead of: remainingInsulinNeed = remainingCarbs / carbRatio
// Use a time-weighted version:
let timeWeightedRemainingCarbs = computeTimeWeightedRemaining(mealIDs: activeMealIDs, context: context)
let remainingInsulinNeed = timeWeightedRemainingCarbs / carbRatio
```

Where entries scheduled for 6 hours from now contribute less to "remaining need" than entries scheduled for 30 minutes from now. A simple linear discount: `weight = max(0.2, 1.0 - hoursUntilEntry / 8.0)` prevents Gate 5 from being too permissive for distant entries while still relaxing it for IOB that covers near-term need.

This is low priority because the current behavior errs on the side of safety (over-restrictive = less insulin = safer).

---

## Part 2: Logic Corrections

### L1. Fix Absorbed Carbs Timing in Adaptive Service

**Priority: MEDIUM**

**Current state:**
`fetchAbsorbedAndRemainingCarbs()` (`MacroAdaptiveService.swift:348-351`) classifies entries as "absorbed" if `entryDate <= now`. But oref processes entries on a ~5-minute cycle. An entry with a timestamp 30 seconds in the past may not have driven any SMB yet, but it's counted as "absorbed." This systematically inflates `absorbedCarbs`, making the predicted BG impact larger than reality.

**Fix:**
Add a buffer to the absorbed/remaining boundary:

```swift
let absorptionBuffer: TimeInterval = 5 * 60 // 5 minutes — one oref cycle
let effectiveNow = now.addingTimeInterval(-absorptionBuffer)

if entryDate <= effectiveNow {
    absorbed += entry.carbs
} else {
    remaining += entry.carbs
}
```

This ensures entries are only counted as "absorbed" after oref has had at least one cycle to act on them.

---

### L2. Thread-Safety for Gate 3 Hysteresis Static Flag

**Priority: LOW**

**Current state:**
`MealModeState.gate3FailedLastCycle` (`MacroAdaptiveService.swift:21`) is a `static var` on a struct. Static mutable state is not thread-safe. If `evaluate()` is called from multiple threads (unlikely in practice since it's called from the oref loop, but possible during testing or if the architecture changes), the flag could be read/written concurrently.

**Fix:**
Use an actor or a lock:

```swift
private static let gate3Lock = NSLock()
private static var _gate3FailedLastCycle = false

private static var gate3FailedLastCycle: Bool {
    get { gate3Lock.lock(); defer { gate3Lock.unlock() }; return _gate3FailedLastCycle }
    set { gate3Lock.lock(); defer { gate3Lock.unlock() }; _gate3FailedLastCycle = newValue }
}
```

Or convert `MealModeState` evaluation to use an actor. This is low priority — the current code works in practice because the oref loop is single-threaded.

---

### L3. SMB Attribution Should Be Proportional to Remaining Carbs, Not Equal Split

**Priority: MEDIUM**

**Current state:**
`performBolus()` (`APSManager.swift:811-814`) splits SMB insulin equally across active meals:
```swift
let perMeal = smbUnits / Double(activeMealIDs.count)
```

If meal A has 50g remaining carbs and meal B has 5g remaining, they each get half the SMB. This mis-attributes insulin, causing the adaptive service to under-count IOB for meal A and over-count for meal B.

**Fix:**
Split proportionally by remaining carbs:

```swift
// Compute remaining carbs per meal
var remainingPerMeal: [String: Double] = [:]
var totalRemaining = 0.0
for mealID in activeMealIDs {
    let info = await macroAdaptiveService.fetchAbsorbedAndRemainingCarbs(mealID: mealID, context: privateContext)
    remainingPerMeal[mealID] = info.remaining
    totalRemaining += info.remaining
}

// Attribute proportionally
if totalRemaining > 0 {
    for mealID in activeMealIDs {
        let proportion = (remainingPerMeal[mealID] ?? 0) / totalRemaining
        let attributed = smbUnits * proportion
        macroAdaptiveService.recordMealInsulin(mealID: mealID, units: attributed)
    }
}
```

This requires making `fetchAbsorbedAndRemainingCarbs` accessible from `APSManager` (currently private on `MacroAdaptiveService`). Change its access to `internal` or add a public wrapper.

---

## Part 3: UX/UI Redesign — Treatment Flow

### Overview

The current treatment experience mixes V1 and V2 concerns into a single screen. V2 sections conditionally appear within V1's layout, creating visual clutter and a confusing flow. The redesign separates them into two clean, independent paths with a toggle to switch between them.

### Design Principle

The treatment page should answer one question: **"What should I do about this meal?"** Everything that isn't directly answering that question — analysis, learning history, similar meal statistics, curve parameter tuning — belongs in settings or analysis pages, not in the treatment flow.

---

### T1. V1/V2 Mode Toggle on the Treatment Page

**What:** A segmented control at the top of the treatment page that switches between V1 and V2 mode.

**Behavior:**
- Default is determined by the V2 toggle in Settings (`useV2MacroAbsorption`). If V2 is enabled in settings, the treatment page opens in V2 mode. If disabled, it opens in V1 mode.
- The user can override the default at any time by tapping the toggle. This override is per-session only — it does not change the setting.
- The toggle is always visible and always functional, so a user who enabled V2 but wants to do a quick manual bolus can switch to V1 without going to settings.

**Implementation:**

```swift
// In TreatmentsRootView
@State private var treatmentMode: TreatmentMode

enum TreatmentMode {
    case v1
    case v2
}

init(resolver: Resolver) {
    self.resolver = resolver
    // Default from settings
    let useV2 = settingsManager.settings.useV2MacroAbsorption
    _treatmentMode = State(initialValue: useV2 ? .v2 : .v1)
}

var body: some View {
    VStack(spacing: 0) {
        // Mode toggle — always visible at top
        Picker("Treatment Mode", selection: $treatmentMode) {
            Text("Standard").tag(TreatmentMode.v1)
            Text("V2 Macro").tag(TreatmentMode.v2)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)

        // Render the appropriate treatment flow
        switch treatmentMode {
        case .v1:
            V1TreatmentView(state: state, ...)
        case .v2:
            V2TreatmentView(state: state, ...)
        }
    }
}
```

**V1TreatmentView** is the current `TreatmentsRootView` body content — forecast chart, carb/protein/fat fields, quick-add buttons, Photo/Log/Crono buttons, correction factors, bolus field, submit button — **minus** the `MacroDecayChartView` and any V2-conditional sections. It is exactly the app as it existed before V2 changes.

**V2TreatmentView** is a new view described in detail below.

**Files affected:**
- `TreatmentsRootView.swift` — refactor body into `V1TreatmentView` and `V2TreatmentView`
- New file: `V2TreatmentView.swift`
- New file: `V1TreatmentView.swift` (extracted from current `TreatmentsRootView`)

---

### T2. Remove MacroDecayChartView from the Treatment Screen

**What:** Delete the macro absorption chart (COB/POB/FOB stacked area chart) from the treatment page entirely.

**Why:**
- It shows raw absorption math (grams on board over time) that doesn't connect to what the user cares about (their BG trajectory)
- The BG forecast chart already incorporates this information in terms the user understands
- It takes up significant vertical space for low informational value
- It uses engineer-facing terminology (COB/POB/FOB) that most users don't understand

**Implementation:**
- Remove the `MacroDecayChartView` section from `TreatmentsRootView` (lines 335-343)
- Keep `MacroDecayChartView.swift` and `MacroOnBoardCalculator.swift` — they may be useful in the analysis page where context makes them meaningful
- Remove the `@FetchRequest` for `fpuEntries` from `TreatmentsRootView` if it was only used for this chart

**Files affected:**
- `TreatmentsRootView.swift` — remove the chart section
- `MacroDecayChartView.swift` — keep file, may reuse in analysis view

---

### T3. V2 Treatment Flow — Step 1: Meal Feed

**What:** When the treatment page opens in V2 mode, the first thing the user sees is a **meal feed** — a list of recent nutrition events detected by the HealthKit observer.

**What it shows:**

```
┌─────────────────────────────────────────┐
│  [Standard]  [V2 Macro]                 │   ← segmented toggle
├─────────────────────────────────────────┤
│                                         │
│  Recent Meals & Nutrition               │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ ☐  Lunch — 12:34 PM            │    │
│  │    C: 65g  F: 28g  P: 35g      │    │
│  │    via Cronometer • 8 min ago   │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ ☐  Snack — 12:12 PM            │    │
│  │    C: 22g  F: 3g  P: 2g        │    │
│  │    via Cronometer • 30 min ago  │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  ✓ Breakfast — 8:15 AM (dosed) │    │
│  │    C: 45g  F: 12g  P: 18g      │    │
│  │    via Cronometer • 4h ago      │    │
│  └─────────────────────────────────┘    │
│                                         │
│  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐   │
│  │  + Enter meal manually          │   │
│  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘   │
│                                         │
│  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐   │
│  │  📱 Log in Cronometer           │   │
│  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘   │
│                                         │
│            [Continue →]                 │   ← enabled when ≥1 item selected
│                                         │
└─────────────────────────────────────────┘
```

**Details:**

Each meal card shows:
- **Checkbox** for selection (multi-select enabled)
- **Meal name/time** — from the HealthKit observer data or Cronometer meal label
- **Macro summary** — C/F/P in grams, with fiber if available
- **Source** — "via Cronometer", "via Apple Health", "manual entry"
- **Time ago** — relative time since the meal
- **Dosed indicator** — green checkmark if this meal was already processed through V2. Already-dosed meals are shown but dimmed, and selecting one shows a warning: "This meal was already dosed. Selecting it will add additional insulin coverage."

**"Enter meal manually"** opens a simple macro entry form (carbs, fat, protein, fiber fields) that creates an item in the meal feed. This is for users who don't use Cronometer or need to add something not in HealthKit.

**"Log in Cronometer"** records the HealthKit baseline snapshot, opens Cronometer via URL scheme, and when the user returns, the observer picks up the new data and the meal feed refreshes. This is the existing "Log" button behavior, relocated.

**"Continue"** button is enabled when at least one undosed item is selected. Tapping it proceeds to Step 2.

**Data source:** The meal feed reads from the HealthKit observer's detected meals (the same data source currently used by `CronometerMealPickerView` and the Cronometer recommendation flow). Meals from the last 8 hours are shown. Already-dosed meals are identified by matching against `V2MealOutcome` records.

**When there are no meals:** Show an empty state: "No recent meals detected. Log a meal in Cronometer or enter one manually." with the two action buttons.

**Combining items:** When multiple items are selected (e.g., a granola bar from 20 min ago + the current meal), their macros are summed for the V2 engine. The meal time used is the most recent selected item's time. This is simpler than running parallel absorption curves for two meal times. The combined totals are shown in a summary bar above the Continue button as the user selects items.

**Files to create:**
- `V2MealFeedView.swift` — the meal feed list
- `V2MealCardView.swift` — individual meal card component
- `V2ManualMealEntryView.swift` — manual macro entry form

**Data needed:**
- `HealthKitManager` or `CronometerViewModel` — already fetches recent meals from HealthKit
- `V2OutcomeLearningStore` — already tracks which meals have been dosed (via `V2MealOutcome.mealID`)

---

### T4. V2 Treatment Flow — Step 2: Adjustment & Preview

**What:** After selecting meals, the user sees their dosing preview with a live BG forecast chart. This is the core decision-making screen.

**What it shows:**

```
┌─────────────────────────────────────────┐
│  [← Back]    Dose Preview    [Standard] │
├─────────────────────────────────────────┤
│                                         │
│  Lunch + Snack                          │
│  C: 87g  F: 31g  P: 37g  Fiber: 8g     │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │                                 │    │
│  │    BG Forecast Chart            │    │
│  │                                 │    │
│  │  ── Current trajectory (gray)   │    │
│  │  ── With treatment (blue)       │    │
│  │  ▓▓ Target range (green band)   │    │
│  │                                 │    │
│  │  [2h history ╎ 6h forecast]     │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Treatment Plan                         │
│  ┌─────────────────────────────────┐    │
│  │  Bolus now:     3.2 U (17.1g)  │    │
│  │  Via SMBs:      70.0g / ~5.2h  │    │
│  │  Protein:       +9.8g / 1.5-8h │    │
│  │  Fat:           +14.2g / 2-9h  │    │
│  │  ─────────────────────────────  │    │
│  │  Total coverage: 111.1g equiv  │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Garmin: 1.2x demand (fair sleep)       │   ← only if Garmin is active
│                                         │
│  Adjustments (optional)          [Show] │   ← collapsed by default
│  ┌─────────────────────────────────┐    │
│  │  Upfront bolus: [====|===] 17%  │    │   ← slider with gamma CDF mark
│  │  Demand override: [===|====]    │    │   ← slider, pre-set from Garmin
│  │  Approach: [Conservative ▼]     │    │   ← picker (see below)
│  └─────────────────────────────────┘    │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  Bolus: [3.2] U    [Use Rec.]  │    │   ← editable, with recommendation
│  │  ☐ External insulin             │    │
│  └─────────────────────────────────┘    │
│                                         │
│        [ Confirm & Deliver ]            │   ← primary action button
│                                         │
└─────────────────────────────────────────┘
```

**Details:**

**Meal summary bar** — shows the combined macros from all selected items. Non-editable here (go back to change selection).

**BG Forecast Chart — Two-Line Design:**
This replaces the current multi-line ForecastChart with a simpler, more focused chart:
- **Gray line (dashed):** Current trajectory — where BG is heading with NO additional intervention. This is computed by running oref's prediction without the proposed carbs/bolus.
- **Blue line (solid):** With-treatment trajectory — where BG will go if the user accepts the proposed dosing. This is computed by running oref's prediction WITH the proposed upfront bolus and scheduled entries.
- **Green band:** Target range (70-180 mg/dL or user's configured range).
- **Time range:** 2 hours of history (solid dots, colored by range) + 6 hours of forecast (lines). 6 hours because V2 meals have effects lasting that long.
- **Key markers:** Current BG (large dot), eventual BG with treatment (diamond).
- The chart updates in real-time as the user adjusts sliders.

Implementation: Create a new `V2ForecastChart` component. It calls `simulateDetermineBasal()` twice — once with no carbs/bolus (gray line) and once with the proposed treatment (blue line). The existing `ForecastChart` uses IOB/COB/UAM/ZT prediction arrays; the V2 version only needs the COB or UAM prediction (whichever is higher) for each scenario.

**Treatment plan summary** — shows what V2 computed:
- Upfront bolus in units and gram-equivalents
- Future carb entries summarized by curve (carb SMBs over Xh, protein entries over Y range, fat entries over Z range)
- Total effective carbs
- If Garmin is active, shows the demand factor with a human-readable reason ("fair sleep", "very active yesterday", etc.) derived from the top contribution in `GarminSensitivityModel.SensitivityResult.contributions`

**Adjustments section** — collapsed by default. Most users should NOT need to touch this. The V2 engine computes good defaults; sliders are an escape hatch, not the primary interaction.

When expanded:
- **Upfront bolus slider** — 0-100%, with a reference mark showing the gamma CDF suggestion. Dragging updates the chart in real-time.
- **Demand override slider** — pre-populated from Garmin (or 1.0x if no Garmin). Allows manual override if the user knows something Garmin doesn't (e.g., "I'm about to go for a run").
- **Approach picker** — a simplified control that shifts multiple parameters at once:
  - **Conservative:** Reduces upfront by 10%, caps adaptive scaling at 1.5x, reduces SMB multiplier by 0.5. For when you're unsure.
  - **Normal:** Uses engine defaults as-is.
  - **Aggressive:** Increases upfront by 10%, allows full adaptive range. For meals you've eaten many times and know you need more insulin.

This replaces exposing individual curve parameters (tau, protein factor, etc.) in the treatment flow. Those belong in settings, not in a moment-of-dosing decision.

**Bolus field** — editable, pre-populated with the recommendation. "Use Rec." button resets it to the calculated value if the user edited it. External insulin toggle preserved.

**Confirm & Deliver** — commits the treatment. Creates V2 entries in Core Data, delivers the bolus, records the V2MealOutcome. Shows the same progress indicator as today.

**Back button** — returns to the meal feed (Step 1). Preserves selections.

**Standard toggle** — in the nav bar, lets the user switch to V1 mid-flow (same as the segmented control, just accessible from this screen too).

**Files to create:**
- `V2TreatmentView.swift` — the main V2 flow container (manages navigation between feed and preview)
- `V2DosePreviewView.swift` — the adjustment & preview screen
- `V2ForecastChart.swift` — the two-line forecast chart
- `V2TreatmentPlanView.swift` — the treatment plan summary component

**Existing files to modify:**
- `TreatmentsStateModel.swift` — add methods for V2 flow state management, dual-simulation for the two-line chart
- `APSManager.swift` — `simulateDetermineBasal()` already exists and can be called twice with different inputs

---

### T5. V2 Treatment Flow — Edge Cases

**Late meals (>1 hour old):**
If the user selects a meal from over 1 hour ago, show a banner on the preview screen:
```
⚠️ This meal is 2.3 hours old. ~45% of carbs may already be absorbed.
The engine has adjusted the treatment plan accordingly.
```
The engine applies the gamma CDF at the elapsed time to estimate already-absorbed carbs and subtracts them from the upfront calculation. Remaining carbs are distributed starting from now rather than from meal time. This is the same logic currently in `CronometerMealRecommendationView` for late dosing — it moves into the V2 engine.

**No Cronometer / no HealthKit:**
The meal feed is empty. The user sees:
```
No recent meals detected.
[Enter meal manually]  [Log in Cronometer]
```
Manual entry creates a meal card in the feed that the user can then select and proceed with.

**Correction bolus (no meal):**
If the user opens the treatment page but doesn't want to dose for a meal — just a correction — they should use V1 mode. V2 mode is explicitly for meal dosing. The segmented toggle makes switching instant. Alternatively, a "Correction only" option at the bottom of the meal feed could bypass the meal selection and go straight to a simple bolus field with the current forecast.

**Multiple overlapping meals:**
If a user selects a meal from 2 hours ago that was already partially dosed AND a new meal, the combined summary should make this clear:
```
Previously dosed meal: Lunch (2h ago, partial coverage active)
New meal: Dinner
Combined: C: 130g  F: 45g  P: 55g
Note: Existing scheduled entries from Lunch are still active.
```

Gate 5 in the meal-mode evaluation will automatically limit enhanced SMBs if the IOB from the previous meal already covers much of the remaining need.

---

### T6. Retire CronometerMealRecommendationView and CronometerMealPickerView

**What:** The current Cronometer sheet (`CronometerMealRecommendationView.swift`) and meal picker (`CronometerMealPickerView.swift`) are replaced by the V2 treatment flow (Steps 1 and 2 above).

**What happens to their features:**

| Current Feature | Where It Goes |
|----------------|---------------|
| Cronometer meal detection | V2 meal feed (T3) — reads from same HealthKit observer |
| Meal picker (today's meals) | V2 meal feed (T3) — shows all recent meals, not just after a button tap |
| BG prediction chart | V2 forecast chart (T4) — simplified two-line version |
| Factor adjustment slider | Removed from treatment flow — factor is a settings/analysis concern |
| Similar meal insights | Moved to analysis page (Part 4) |
| Learning history stats | Moved to analysis page (Part 4) |
| V2 split dosing slider | V2 adjustment section (T4) — upfront bolus slider |
| Late meal warnings | V2 late meal banner (T5) |
| Late dose decay adjustment | V2 engine handles automatically (T5) |
| "Apply to Bolus Calculator" | Replaced by integrated flow — V2 preview IS the bolus calculator |
| Factor lock toggle | Moved to settings — doesn't belong in treatment moment |

**Files to deprecate (not delete immediately, mark as legacy):**
- `CronometerMealRecommendationView.swift` — complex sheet with 44 parameters in its init
- `CronometerMealPickerView.swift` — replaced by V2 meal feed

These views remain functional for V1 mode (the Crono button on the V1 treatment page still works). They are only retired from the V2 path.

---

## Part 4: UX/UI Redesign — Settings Consolidation

### U1. Create a V2 Hub Page in Settings

**What:** Replace the current `V2MacroDosingSettingsView` navigation destination with a hub page that has multiple sections/tabs, consolidating all V2-related configuration and analysis in one place.

**Current fragmentation:**
- V2 engine settings → Settings > V2 Macro Dosing
- Nutrition read/write toggles → Settings > Apple Health
- Daily nutrition preview → Settings > Apple Health
- Nutrition analysis → Settings > Apple Health > Nutrition Analysis
- Outcome analysis → Settings > V2 Macro Dosing > Outcome Analysis
- Meal data export → Settings > V2 Macro Dosing > Outcome Analysis
- Garmin data → Settings > V2 Macro Dosing > Garmin Health Data

**Proposed V2 Hub structure:**

```
Settings > V2 Macro Engine
├── Nutrition                    ← NEW section
│   ├── Read from Apple Health toggle
│   ├── Write to Apple Health toggle
│   ├── Daily nutrition preview (last 7 days)
│   └── Log in Cronometer shortcut
│
├── Engine Settings              ← existing V2MacroDosingSettingsView content
│   ├── Enable/Disable toggle
│   ├── Insulin type
│   ├── Safe window
│   ├── Meal-mode SMB multiplier
│   ├── BG floor
│   ├── Curve parameters (fat, protein, carb, fiber)
│   ├── Example calculation
│   └── Reset to defaults
│
├── Garmin Sensitivity           ← existing, extracted into its own section
│   ├── Enable/Disable toggle
│   ├── Firebase status
│   └── Garmin Health Data link
│
├── Analysis                     ← consolidated
│   ├── Meal Outcome Accuracy (existing V2OutcomeAnalysisView)
│   ├── Nutrition Analysis (moved from Apple Health)
│   ├── Similar Meal Insights (moved from Cronometer sheet)
│   └── Learning History (moved from Cronometer sheet)
│
├── AI Calibration               ← existing
│   ├── Claude AI Recalibration toggle
│   └── AI Insights link
│
└── Export                       ← existing
    └── Export Meal Data
```

**Implementation approach:**
Use a `List` with sections, or a tab-style layout with a `Picker` at the top:

```swift
struct V2MacroHubView: BaseView {
    @State private var selectedTab: V2HubTab = .engine

    enum V2HubTab: String, CaseIterable {
        case nutrition = "Nutrition"
        case engine = "Engine"
        case garmin = "Garmin"
        case analysis = "Analysis"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(V2HubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch selectedTab {
            case .nutrition:
                V2NutritionSettingsView(...)
            case .engine:
                V2EngineSettingsView(...)  // current V2MacroDosingSettingsView content
            case .garmin:
                V2GarminSettingsView(...)
            case .analysis:
                V2AnalysisHubView(...)
            }
        }
    }
}
```

**What stays in Apple Health settings:**
- The Apple Health permissions toggle ("Connect to Apple Health")
- The setup instructions for iOS permissions
- The Health Metrics for AI Analysis toggles (activity, sleep, HR, workouts)

These are Apple Health platform concerns, not V2 nutrition concerns. The V2 hub pulls in only the nutrition read/write toggles and the daily nutrition preview.

**Files to create:**
- `V2MacroHubView.swift` — the hub container with tab picker
- `V2NutritionSettingsView.swift` — nutrition toggles and daily preview (extracted from `AppleHealthKitRootView`)
- `V2AnalysisHubView.swift` — links to outcome analysis, nutrition analysis, similar meals, learning history

**Files to modify:**
- `AppleHealthKitRootView.swift` — remove the nutrition data section and nutrition analysis link (keep permissions and health metrics)
- Navigation routing — update the settings navigation to point to `V2MacroHubView` instead of `V2MacroDosingSettingsView`

---

### U2. Move Similar Meal Insights and Learning History to Analysis

**What:** The similar meal insights section and learning history stats currently shown in `CronometerMealRecommendationView` move to the V2 Analysis hub.

**Why:** These are retrospective analysis tools. Showing them in the treatment flow (where the user is trying to make a dosing decision in real-time) adds cognitive load without aiding the immediate decision. The V2 engine already incorporates similar meal data into its calculations — the user doesn't need to see the raw stats to benefit from them.

**What the analysis page shows:**
- **Similar Meal Insights:** For any selected meal outcome, show:
  - Top 3 matching historical meals (by macro similarity)
  - Expected BG trajectory based on similar meals
  - Confidence level
  - Suggested ICR adjustment
- **Learning History:**
  - Meals tracked / completed count
  - In-range percentage over time (chart)
  - Average peak BG trend (chart)
  - How curve parameters have changed over time (sparklines for tau, protein factor, fat coefficient)
  - Factor auto-adjustment history

This is the "see how V2 is performing for you" page, separate from the "decide what to do right now" treatment flow.

---

### U3. Factor Adjustment Belongs in Settings, Not Treatment

**What:** The Cronometer adjustment factor slider (currently in `CronometerMealRecommendationView`) and the factor lock toggle move to the V2 Engine Settings section.

**Why:** The adjustment factor is a personal calibration parameter, like carb ratio or ISF. You set it based on your history, not in the moment of dosing. The V2 outcome learning system adjusts it automatically. Putting it in the treatment flow tempts users to fiddle with it per-meal, which defeats the learning system.

**Exception:** The "Approach" picker in the V2 dose preview (T4) serves a similar purpose but in a much more constrained way — it shifts the overall aggressiveness without exposing the raw factor. This is a moment-of-dosing affordance that's appropriate because it's expressed in terms the user understands ("conservative" vs "aggressive") rather than a numeric factor.

---

## Part 5: Implementation Plan

### Phase 1: Safety Fixes (Do First)

These can be implemented independently without touching the UI.

| Item | Files | Effort | Risk if Skipped |
|------|-------|--------|-----------------|
| S1: IOB decay modeling | `MacroAdaptiveService.swift` | Medium | Over-delivery for long meals |
| S2: Composite ceiling | `MacroAdaptiveService.swift` | Small | Theoretical extreme stacking |
| S3: Fat slider cap | `V2MacroDosingSettingsView.swift` | Trivial | User error → excess insulin |
| S4: Plateau > threshold | `V2MacroDosingSettingsView.swift` | Small | Broken protein ramp |
| L1: Absorbed carbs buffer | `MacroAdaptiveService.swift` | Small | Systematic prediction bias |
| L3: Proportional SMB split | `APSManager.swift`, `MacroAdaptiveService.swift` | Small | IOB mis-attribution |

**Test:** Run the existing `V2MacroEngineTests` suite after each change. Add new tests for S1 (decay) and S2 (ceiling).

### Phase 2: Treatment Flow Restructure

This is the largest change. Do it as a series of PRs:

**PR 1: Extract V1 treatment view**
- Move current `TreatmentsRootView` body into `V1TreatmentView`
- Remove `MacroDecayChartView` section (T2)
- Add the V1/V2 segmented toggle to `TreatmentsRootView` (T1)
- V2 mode shows a placeholder ("V2 treatment flow coming soon")
- **Result:** V1 works exactly as before. V2 toggle exists but is non-functional.

**PR 2: V2 meal feed**
- Implement `V2MealFeedView` (T3)
- Implement `V2MealCardView` with selection
- Implement `V2ManualMealEntryView`
- Wire up HealthKit observer data
- "Continue" button shows a placeholder preview
- **Result:** V2 mode shows the meal feed. Selection works. Preview is placeholder.

**PR 3: V2 dose preview**
- Implement `V2DosePreviewView` (T4)
- Implement `V2ForecastChart` (two-line chart)
- Implement `V2TreatmentPlanView`
- Wire up `MacroAbsorptionEngine.generateEntries()` for the selected meals
- Wire up `simulateDetermineBasal()` for dual-line chart
- Implement the adjustment sliders (upfront %, demand override, approach picker)
- Implement confirm & deliver (reuse existing `invokeTreatmentsTask()`)
- **Result:** Full V2 treatment flow is functional end-to-end.

**PR 4: Edge cases and polish**
- Late meal handling (T5)
- Multiple meal combination logic
- Already-dosed meal warnings
- Correction-only shortcut
- Low BG warnings (port from V1)
- Progress indicators
- Error handling

### Phase 3: Settings Consolidation

**PR 5: V2 Hub page**
- Create `V2MacroHubView` with tabbed sections (U1)
- Extract nutrition settings from `AppleHealthKitRootView` into `V2NutritionSettingsView`
- Move analysis links into `V2AnalysisHubView`
- Update navigation routing

**PR 6: Retire Cronometer sheet from V2 path**
- Remove Crono button and sheet from V2 treatment flow (T6)
- Move similar meal insights to analysis (U2)
- Move factor slider to settings (U3)
- Keep Crono button functional in V1 mode

### Phase 4: Cleanup

**PR 7: Final cleanup**
- Remove dead V2 conditional branches from V1 views
- Remove unused imports and state variables
- Update V2DosingStrategy.md to reflect new UX flow
- Update V2ChangesNeeded.md with V3 completion status

---

## Summary

| # | Item | Type | Priority |
|---|------|------|----------|
| S1 | IOB decay modeling | Safety | HIGH |
| S2 | Composite demand ceiling | Safety | HIGH |
| S3 | Fat slider cap 2.00 → 1.20 | Safety | MEDIUM |
| S4 | Validate plateau > threshold | Safety | MEDIUM |
| S5 | Time-weighted Gate 5 | Safety | LOW |
| L1 | Absorbed carbs timing buffer | Logic | MEDIUM |
| L2 | Gate 3 thread safety | Logic | LOW |
| L3 | Proportional SMB attribution | Logic | MEDIUM |
| T1 | V1/V2 treatment toggle | UX | HIGH |
| T2 | Remove MacroDecayChartView | UX | HIGH |
| T3 | V2 meal feed | UX | HIGH |
| T4 | V2 dose preview + two-line chart | UX | HIGH |
| T5 | Edge cases (late meals, multi-meal) | UX | MEDIUM |
| T6 | Retire Cronometer sheet from V2 | UX | MEDIUM |
| U1 | V2 Hub settings page | UX | MEDIUM |
| U2 | Analysis consolidation | UX | LOW |
| U3 | Factor slider to settings | UX | LOW |

---

*This document describes planned improvements to the V2 Macro Absorption Engine in the Trio open-source automated insulin delivery system. The system is for research and personal use. It is not FDA-approved and should not be used as the sole basis for insulin dosing decisions without clinical oversight.*
