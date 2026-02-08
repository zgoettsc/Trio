# V2 Outcome Learning System — How It Works

This document explains the complete V2 outcome learning pipeline: what gets recorded when you apply a Cronometer meal, how BG checkpoints are backfilled, how the system learns from your results, and how those learned parameters feed back into future meal calculations.

---

## Overview

The learning system is a closed loop:

```
Apply Meal → Record Outcome → Wait for BG Data → Backfill Checkpoints
    ↑                                                       ↓
    ↑                                               Attribute Errors
    ↑                                               to Curve Phases
    ↑                                                       ↓
    └──── Updated Parameters ←── Recalculate Parameters ←───┘
```

Each step is described below.

---

## Step 1: Recording a Meal Outcome

**When:** You tap "Apply to Bolus Calculator" on the Cronometer recommendation page with V2 enabled and "Record Meal Outcomes" on.

**What gets recorded** (a `V2MealOutcome` struct):

| Field | What It Is | Why It Matters |
|-------|-----------|----------------|
| `carbs`, `fat`, `protein` | The macros you applied | Inputs to the three-curve model |
| `tauCarb` | Fat-modified carb time constant used | Tells the learning system what absorption speed was assumed |
| `proteinFactor` | The protein conversion factor used (0–0.80) | What fraction of protein was modeled as glucose |
| `fatTotalEquiv` | Total fat carb-equivalent calculated | How much delayed insulin was scheduled for fat |
| `upfrontPercent` | How much you bolused upfront (0–100%) | Whether you used the curve suggestion or overrode it |
| `curveSuggestedPercent` | What the gamma CDF recommended | The model's suggestion before any user override |
| `insulinDemandFactor` | Garmin sensitivity factor (1.0 = normal) | Whether insulin resistance adjustment was applied |
| `safeWindowMinutes` | Safe window used for the split | 30 min (ultra-rapid) or 45 min (rapid-acting) or custom |
| `garminSnapshot` | Full Garmin health context at meal time | Sleep, stress, body battery, HR, HRV, activity — for pattern analysis |
| `bgAtMeal` | Your BG when you applied the meal | Starting point for outcome evaluation |
| `carbRatioAtMeal` | Your active carb ratio (ICR) | Used to filter outcomes by similar pump settings |
| `isfAtMeal` | Your active insulin sensitivity factor | Context for understanding BG response magnitude |
| `mealSMBMultiplier` | SMB multiplier setting in effect | How aggressively SMBs were enhanced |
| `mealModeWasActive` | Whether meal-mode SMB was active | Dosing context |
| `checkpoints` | 6 BG checkpoints (all nil initially) | The slots that get backfilled with actual BG |
| `hasConfoundingMeal` | Whether a subsequent meal was detected | Marks outcome as unreliable if another meal interfered |

### The 6 Checkpoints

Each outcome starts with 6 empty BG checkpoints, each tagged with which absorption curve dominates at that time:

| Checkpoint | Time After Meal | Curve Phase | What It Tests |
|------------|----------------|-------------|---------------|
| 1h | +1 hour | `carb` | Was the upfront bolus right? Did carbs absorb as predicted? |
| 2h | +2 hours | `carb` | Tail end of carb absorption — was tau correct? |
| 3h | +3 hours | `protein` | Protein gluconeogenesis onset — is protein factor right? |
| 4h | +4 hours | `overlap` | Multiple curves active — shared attribution |
| 6h | +6 hours | `fat` | Peak of fat insulin resistance — is fat coefficient right? |
| 8h | +8 hours | `fat` | Tail of fat effect — was the fat curve duration correct? |

---

## Step 2: Backfilling BG Checkpoints

**When backfill runs:**
- Every time you open a Cronometer meal recommendation (fetching a new meal or selecting from the picker)
- Every time you open the Outcome Accuracy page (Settings → V2 Macro Dosing → Meal Outcome Accuracy)

**How it works:**

For each recorded meal outcome, the system iterates through its 6 checkpoints:

1. Skip any checkpoint that already has a BG value (already backfilled)
2. Calculate the target time: `meal date + checkpoint hours`
3. Only attempt backfill if at least 30 minutes have passed after the target time (to ensure CGM data exists)
4. Query Core Data (`GlucoseStored`) for the closest glucose reading within a ±30 minute window of the target time
5. If found, write the BG value into the checkpoint and persist

**Example timeline for a meal at 12:00 PM:**

| Checkpoint | Target Time | Earliest Backfill | Looks For CGM Data Between |
|------------|------------|-------------------|---------------------------|
| 1h | 1:00 PM | 1:30 PM | 12:30 PM – 1:30 PM |
| 2h | 2:00 PM | 2:30 PM | 1:30 PM – 2:30 PM |
| 3h | 3:00 PM | 3:30 PM | 2:30 PM – 3:30 PM |
| 4h | 4:00 PM | 4:30 PM | 3:30 PM – 4:30 PM |
| 6h | 6:00 PM | 6:30 PM | 5:30 PM – 6:30 PM |
| 8h | 8:00 PM | 8:30 PM | 7:30 PM – 8:30 PM |

**Why checkpoints might stay empty (`--`):**
- Not enough time has passed yet (meal is too recent)
- CGM gap — no glucose reading within the ±30 min window (sensor warmup, compression low, sensor change)
- The backfill hasn't been triggered yet — it only runs when you interact with the Cronometer recommendation flow or open the accuracy page

---

## Step 3: The Accuracy Page (What You See)

**Location:** Settings → V2 Macro Dosing → Analysis → Meal Outcome Accuracy

### Section 1: Overall Accuracy

| Row | What It Shows | How It's Calculated |
|-----|--------------|-------------------|
| Total Recorded Meals | Count of all V2MealOutcome records | All meals in the last 90 days |
| With BG Checkpoints | How many have at least one non-nil checkpoint | Meals where backfill found CGM data |
| In Range at 2h | Count where BG at the 2h checkpoint was 70–180 mg/dL | Primary quality metric — were carbs dosed correctly? |
| Avg BG Error at 2h | Average deviation from 110 mg/dL at 2h | Positive = running high (under-dosed), negative = running low (over-dosed). Green if <30, orange otherwise |
| Avg BG Error at 4h | Same for 4h checkpoint | Tests protein/overlap phase accuracy |
| Garmin-Adjusted Meals | Meals where Garmin context was available | How many meals had sensitivity adjustment |
| Avg Demand Factor | Average Garmin insulin demand factor | >1.0 means on average you needed more insulin than baseline |

### Section 2: Curve Phase Accuracy

Breaks down accuracy by which absorption curve was dominant:

| Phase | Checkpoints Used | What It Reveals |
|-------|-----------------|----------------|
| Carb Phase (0-2h) | 1h, 2h checkpoints | Is your carb tau correct? Consistently high → tau too high (absorption faster than modeled). Consistently low → tau too low |
| Protein Phase (2-5h) | 3h checkpoint | Is your protein factor correct? High at 3h → protein effect stronger than modeled. Low → weaker |
| Fat Phase (4-8h) | 6h, 8h checkpoints | Is your fat coefficient correct? High at 6-8h → fat coefficient too low. Low → too high |

For each phase, the page shows:
- **Avg BG**: average glucose across all clean checkpoints in that phase (colored red/orange/green)
- **IR%**: in-range percentage (70–180 mg/dL) for that phase

### Section 3: Recent Meals

Shows the last 20 recorded meals, each with:

| Element | Description |
|---------|-------------|
| Date and time | When the meal was recorded |
| Watch icon (blue) | Garmin context was available |
| Warning triangle (orange) | A confounding meal was detected (another meal eaten before checkpoints completed) |
| Macros | C/F/P in grams |
| BG at meal | Starting glucose |
| Demand factor | Garmin sensitivity multiplier (1.00 = normal) |
| Upfront % | How much was bolused upfront vs. delayed via SMBs |
| Checkpoint row | BG values at 1h/2h/3h/4h/6h/8h — colored red (<70), green (70–180), orange (>180), or `--` if not yet backfilled |
| Exclamation circle | Appears under a checkpoint if it's marked not clean (confounded) |

---

## Step 4: How the System Learns (Curve Parameter Recalibration)

The learning system adjusts the five curve parameters based on BG errors at each checkpoint. There are two learning pathways:

### Pathway A: Automatic Rule-Based Learning (`recalculateCurveParameters`)

**Currently triggered by:** The Claude AI Recalibration toggle (when enabled, this can be invoked by the recalibration service).

**Algorithm:**

1. **Filter outcomes**: Only use meals that are not confounded (`hasConfoundingMeal == false`) and have at least one BG checkpoint filled
2. **ICR matching**: If a current carb ratio is provided, only use outcomes where the carb ratio at meal time was within ±10% of the current ratio. This prevents learning from meals dosed under very different pump settings
3. **Recency weighting**: Recent meals count more. Weight = `max(0.1, 1.0 - (age in days / 90))`. A meal from today has weight ~1.0; a meal from 45 days ago has weight ~0.5; a meal from 90 days ago has weight 0.1
4. **Error calculation**: For each checkpoint with a BG value:
   - If BG > 180: error = `+(BG - 180) / 100` (positive = under-dosed)
   - If BG < 70: error = `-(70 - BG) / 100` (negative = over-dosed)
   - If BG 70–180: error = 0 (in range, no adjustment)
5. **Phase attribution**: The error is attributed to the curve that dominates at that checkpoint's time:

| Curve Phase | Error Direction | Parameter Adjustment |
|-------------|----------------|---------------------|
| `carb` | High BG → carbs absorbed faster than predicted | Decrease tau (e.g., -2 min per 100 mg/dL error) |
| `carb` | Low BG → carbs absorbed slower | Increase tau |
| `protein` | High BG → protein gluconeogenesis stronger | Increase protein factor (+0.02 per 100 mg/dL) |
| `protein` | Low BG → protein weaker | Decrease protein factor |
| `fat` | High BG → fat resistance stronger | Increase fat coefficient (+0.05 per 100 mg/dL) |
| `fat` | Low BG → fat resistance weaker | Decrease fat coefficient |
| `overlap` | Error distributed across all three curves at 30% weight | Smaller adjustments to each |

6. **Averaging and clamping**: The weighted-average adjustment is applied to the current parameter value, then clamped to safe limits:

| Parameter | Minimum | Maximum |
|-----------|---------|---------|
| Carb Tau | 20 min | 60 min |
| Protein Factor | 0.10 | 0.60 |
| Fat Coefficient | 0.30 | 1.20 |

7. **Save**: Updated parameters are persisted to UserDefaults via `V2OutcomeLearningStore.saveParameters()`

### Pathway B: Claude AI Recalibration (`SensitivityRecalibrationService`)

**When enabled:** The "Claude AI Recalibration" toggle in V2 settings.

**How it works:**

1. Exports the last 7 days of V2MealOutcome records plus current parameters as structured JSON
2. Sends the data to the Claude API with a specialized system prompt
3. Claude analyzes patterns across meals: time-of-day effects, specific food combinations, systematic over/under-prediction, Garmin sensitivity correlations
4. Claude returns recommended parameter changes with confidence levels (high/medium/low) and rationale
5. Only high-confidence recommendations are applied; medium-confidence are logged; low-confidence are discarded
6. Updated parameters are saved back to the store

The Claude pathway can detect patterns that the rule-based system cannot:
- "You consistently spike after lunch but not dinner — consider time-of-day carb sensitivity"
- "High-fat meals with >40g fat show 2x the predicted rise — fat coefficient too low for large fat loads"
- "Your protein response only appears when protein > 25g — threshold may be too low at 15g"

---

## Step 5: How Learned Parameters Feed Back Into Meals

The learned parameters are stored in `V2PersonalCurveParameters` (UserDefaults key: `V2PersonalCurveParameters`). Every time the V2 engine runs — either for the live Cronometer recommendation preview or for the actual carb entry storage — it loads these parameters:

```
V2OutcomeLearningStore.shared.loadParameters()
    → V2PersonalCurveParameters {
        carbTau: 38,           // learned: slightly slower than default 35
        proteinFactor: 0.42,   // learned: stronger protein response
        fatTotalCoeff: 0.85,   // learned: more fat resistance
        proteinThreshold: 15,  // still at default
        proteinPlateau: 40     // still at default
    }
```

These are passed to `MacroAbsorptionEngine.generateEntries(curveParameters:)`, which uses them for:

| Parameter | Where It's Used in the Engine |
|-----------|------------------------------|
| `effectiveCarbTau` | Base tau for `carbTau(baseTau:fatGrams:)` — affects upfront/delayed carb split and absorption duration |
| `effectiveProteinFactor` | Max conversion in `proteinGlucoFactor()` — how many grams of glucose-equivalent per gram of protein |
| `effectiveProteinThreshold` | Below this protein amount, gluconeogenesis effect is zero |
| `effectiveProteinPlateau` | Above this protein amount, conversion rate plateaus at max |
| `effectiveFatTotalCoeff` | Multiplied by fat grams to get total fat carb-equivalent |

If no learning has occurred (all values nil), defaults are used: tau=35, proteinFactor=0.35, threshold=15g, plateau=40g, fatCoeff=0.69.

### Manual Override via Sliders

The V2 settings page (Settings → V2 Macro Dosing) provides sliders for all five parameters. These write to the same `V2PersonalCurveParameters` store. The relationship between manual and learned values:

- Manual slider change → immediately saved → used for the next meal
- Outcome learning runs → adjusts from the current value (which may have been manually set) → saves the new value
- The slider on the settings page reflects whatever value is currently stored, whether it came from manual adjustment or learning
- "Reset Curve Parameters to Defaults" sets all values to nil (use hardcoded defaults)

---

## Data Lifecycle

### Retention

Outcomes older than **90 days** are automatically pruned on every `loadAll()` call. This means:
- The learning system only considers the last 3 months of data
- Older patterns that no longer apply (seasonal changes, medication changes) gradually age out
- The recency weighting further reduces the influence of older meals within the 90-day window

### Storage

| Data | Storage Location | Key |
|------|-----------------|-----|
| Meal outcomes | UserDefaults | `V2MealOutcomes` |
| Curve parameters | UserDefaults | `V2PersonalCurveParameters` |
| BG readings (for backfill) | Core Data | `GlucoseStored` entity |

### What Prevents Bad Learning

Several safeguards prevent the system from learning incorrect patterns:

1. **Confounding meal detection**: If you eat another meal before all checkpoints are recorded, `hasConfoundingMeal` is set and the outcome is excluded from learning
2. **Clean checkpoint flag**: Individual checkpoints can be marked `isClean = false` if a confounding event affects only later checkpoints
3. **ICR matching**: Outcomes from very different pump settings (>10% carb ratio change) are excluded, preventing learning across profile switches
4. **Recency weighting**: Old data has minimal influence (weight 0.1 at 90 days vs 1.0 today)
5. **Parameter clamping**: Values cannot go outside physiologically reasonable ranges (e.g., carb tau stays between 20–60 min)
6. **In-range exclusion**: Checkpoints where BG was 70–180 contribute zero error — the system only adjusts when something went wrong
7. **Overlap dampening**: Checkpoints in the overlap phase (4h) attribute error at 30% weight to each curve, preventing over-correction when multiple curves are active

---

## Worked Example

**Meal:** 60g carbs, 25g fat, 40g protein at 12:00 PM. Starting BG: 120 mg/dL.

**Parameters used:** carbTau=35, proteinFactor=0.35, fatCoeff=0.69

**Checkpoints after backfill:**

| Time | BG | Phase | Error |
|------|-----|-------|-------|
| 1h (1:00 PM) | 165 | carb | In range → 0 |
| 2h (2:00 PM) | 195 | carb | (195-180)/100 = +0.15 (under-dosed) |
| 3h (3:00 PM) | 210 | protein | (210-180)/100 = +0.30 (under-dosed) |
| 4h (4:00 PM) | 185 | overlap | (185-180)/100 = +0.05 (under-dosed) |
| 6h (6:00 PM) | 190 | fat | (190-180)/100 = +0.10 (under-dosed) |
| 8h (8:00 PM) | 140 | fat | In range → 0 |

**Learning adjustments** (assuming recency weight = 1.0 for a recent meal):

- **Carb tau**: -0.15 * 2.0 = -0.30 → tau goes from 35 to 34.7 (slightly faster absorption)
- **Protein factor**: +0.30 * 0.02 = +0.006 → factor goes from 0.35 to 0.356 (slightly more protein effect)
- **Fat coefficient**: +0.10 * 0.05 = +0.005 → coeff goes from 0.69 to 0.695 (slightly more fat effect)
- **Overlap at 4h**: +0.05 distributed at 30% to each curve (small additional nudge)

After many meals with similar patterns, these small adjustments compound into meaningful parameter shifts. A user who consistently runs high at 3h would see their protein factor gradually increase from 0.35 toward 0.42–0.50 over weeks.

---

## Troubleshooting

**All checkpoints show `--`:**
The backfill wasn't running (this was a bug, now fixed). Open the Outcome Accuracy page — it triggers backfill on appear. If checkpoints still show `--`, the meal may be too recent (checkpoints need meal time + hours + 30 min buffer) or there's a CGM data gap.

**"With BG Checkpoints" shows 0:**
Same cause as above. Open the accuracy page to trigger backfill. Also check that your CGM is connected and storing glucose to Core Data.

**Parameters don't seem to change:**
The learning system only adjusts when BG is out of range (>180 or <70). If your outcomes are mostly in range, no adjustment is needed — the current parameters are working well.

**A meal shows the warning triangle:**
A subsequent meal was detected before all checkpoints completed. This outcome is excluded from learning to prevent incorrect parameter attribution.

**Slider values change on their own:**
The outcome learning system and the Claude recalibration service both write to the same parameter store. If you set a value manually and then learning runs, the value may shift. To lock a manual value, disable "Record Meal Outcomes" or "Claude AI Recalibration" in settings.
