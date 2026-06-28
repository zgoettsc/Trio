# Trio Telemetry — Analysis Methods

A runbook for getting insights out of the telemetry stream. Four analyses are
designed-for, plus caveats and snippets.

## File reference

All timestamps are ISO-8601 in UTC. All BG values in mg/dL. All insulin in units.

### `events.jsonl`

One JSON object per line. Common fields: `kind`, `timestamp`, `windowId`,
`payload`. The payload schema varies by `kind`:

| kind | payload fields |
|---|---|
| `mealWindowActivated` | source, estimatedCarbs, bg, iob, cob, delta5m, bgTrend30m, autosensRatio, smartSenseRatio, effectiveISF, carbRatio, durationMinutes |
| `mealWindowCancelled` | source (`shortcut`/`homeBanner`/`liveActivityLink`), minutesSinceActivation, bg, iob |
| `mealWindowExpired` | source (`naturalExpiry`), elapsedMinutes, wasCarbsConfirmed |
| `mealWindowCarbsConfirmed` | carbs, fat, protein, minutesSinceActivation |
| `insulinReqFloorActivated` | bg, delta5m, velocity, iob, floorPriorInsulinReq, floorMagnitude, floorVelocityFactor, insulinReq, smbDelivered, minutesSinceWindowOpen |
| `smbDelivered` | units, isSMB, duringMealWindow (also: bg, iob, insulinReq when from loop) |
| `userBolus` | units, isSMB=false, duringMealWindow |
| `externalBolus` | units, duringMealWindow |
| `carbEntry` | carbs, fat, protein, isFPU, fpuID, enteredBy, note, duringMealWindow |
| `overrideStarted` | overrideId, name, percentage, targetMgdL, durationMinutes |
| `overrideCancelled` | overrideId |
| `tempTargetStarted` | tempTargetId, name, targetMgdL, durationMinutes |
| `tempTargetCancelled` | tempTargetId |
| `mealWindowTuningChanged` | field, oldValue, newValue — emitted per-field when any of the 9 PLAN.md tuning settings change |
| `podChanged` | source (`pumpRewind`) — pod swap (Omnipod) or cartridge change (Medtronic) |
| `overrideStartedDuringMealWindow` | overrideId, overrideName, smbIsOff, percentage, target — fires when an override starts WHILE a meal window is already active. Separate from regular `overrideStarted` so the new warning path can be filtered |
| `mealWindowAutoExtended` | oldDurationMinutes, newDurationMinutes, trigger — fires when the classifier upgrades to Complex and the window duration is auto-extended (the `mealWindowClassifierUpgraded` event's `newExtendedDurationMinutes` payload carries the same info today) |
| `liveCarbsEstimateTriggered` | enteredCarbs, impliedSoFar, extra, suggestedAdd, minutesSinceOpen, bg, bgAtActivation, isf, cr — fires when the mid-meal estimator detects entered carbs were too low. 3-consecutive-loop threshold, 30-min re-fire cooldown |
| `liveCarbsEstimateAccepted` | added — user tapped "Add Ng" on the suggestion (UI follow-up; event reserved) |
| `liveCarbsEstimateDismissed` | (no payload) — user dismissed the suggestion (UI follow-up; event reserved) |

### `loop.jsonl`

One row per `determineBasal` pass. Always written (continuous), with
`mealWindowActive` indicating context. Fields you'll use most:

- **Time/context:** `timestamp`, `windowId`, `minutesSinceWindowOpen`,
  `mealWindowActive`, `mealWindowMinutesRemaining`, `mealWindowCarbsConfirmed`,
  `mealWindowEstimatedCarbs`
- **BG signal:** `bg`, `smoothedBG`, `velocity` (mg/dL/min), `acceleration`,
  `jerk`, `delta5m`, `mealDetection` (`none`/`possible`/`likely`/`confirmed`)
- **Loop math:** `iob`, `cob`, `eventualBG`, `minPredBG`, `insulinReq`,
  `smbDelivered`, `tempBasalRate`, `sensitivityRatio`
- **Floor diagnostics:** `floorActivated`, `floorPriorInsulinReq`,
  `floorMagnitude`, `floorVelocityFactor`
- **Eating-mode tuning, applied this pass** (nil when window inactive):
  `effectiveSmbDeliveryRatio`, `effectiveMaxSMBBasalMinutes`,
  `effectiveMaxUAMSMBBasalMinutes`, `effectiveToughMealCapPercent`,
  `floorBehavior` (`"off"`/`"replacement"`/`"additive"`), `forcedUAM`,
  `phantomCOBGrams` (0 if not injected), `relaxedRisingGuard`,
  `effectiveCOBDecayMultiplier` (1.0 = normal, <1.0 = oref's per-loop COB
  consumption was slowed; nil outside meal windows)
- **Profile-at-this-loop:** `target`, `isf`, `carbRatio`, `maxIOB`
- **Full oref reason:** `reason` (string — invaluable for understanding why)

### `summary.jsonl`

Two rows per window, joined by `windowId`:

- **Close-time row** (written at window close): metadata only. `peakBG` etc are
  nil. Use to see when/how the window closed.
- **Outcome row** (written +6h after close, on next app foreground): same
  `windowId`, with `peakBG`, `peakBGMinutesAfterActivation`, `nadirBG`, `bgAt2hr`,
  `bgAt4hr`, `bgAt6hr`, `minutesAbove180`, `minutesAbove250`, `minutesBelow70`,
  `totalSMBInsulin`, `totalManualBolusInsulin`, `floorActivationCount` populated.

Filter for outcome rows with `select(.peakBG != null)`.

### `meals.jsonl` (and per-meal `history/<mealId>.jsonl`)

One row per closed `SavedMealInstance`. Same row written to both:
the daily roll-up (`telemetry/<YYYY-MM>/<DD>/meals.jsonl`) and the
per-meal history file (`telemetry/meals/history/<mealId>.jsonl`).

Stable fields you'll filter on every analysis:

- `instanceId`, `savedMealId`, `savedMealName` (nil if anonymized),
  `windowId`, `startedAt`, `closedAt`, `deviceTimeZone`
- `macros.carbs`, `macros.fat`, `macros.protein` (all optional)
- `carbBucket` — `"small"` <40g, `"medium"` 40–80g, `"large"` ≥80g
- `initialClassification`, `finalClassification` —
  `simple`/`medium`/`complex`
- `bgCurveJSON` — array of `{t, bg}` where `t` is minutes-from-activation
- `smbsJSON` — array of `{t, units}`
- `floorActivationsJSON` — array of `{t, prior, floored, factor}`
- `classifierUpgradesJSON` — array of upgrade events
- `outcomeScore` — 0–100
- `metrics.{peakBG, timeInRangeMinutes, timeAboveRangeMinutes,
  timeBelowRangeMinutes, lowsCount, timeToBaselineMinutes,
  totalInsulinDeliveredU, smbCount, floorActivationCount}`

**Activation context (added schema v10)** — one-shot snapshot taken
at the moment the eating-mode window opened:

- `context.bgAtActivation` — BG (mg/dL) at activation
- `context.bgTrendAtActivation` — Δ BG over prior 30 min (mg/dL,
  positive = rising into the meal)
- `context.autosensRatioAtActivation` — oref Autosens (1.0 neutral,
  >1 resistant, <1 sensitive)
- `context.smartSenseRatioAtActivation` — Smart-Sense blended final
  ratio (post-Autosens + post-Garmin)
- `context.effectiveISFAtActivation` — ISF (mg/dL per U) oref was
  actually using at activation, already adjusted by Autosens
- `context.carbRatioAtActivation` — CR (g/U) at activation. Combined
  with ISF, lets you back-calculate `carbs ↔ mg/dL` (1g carbs raises
  BG by ISF/CR mg/dL) — basis for the in-app per-instance estimated-
  carbs panel and Analysis 6 below.

All six `context` fields are individually optional — nil when the
source value wasn't available (fresh install, sensor outage,
Smart-Sense disabled, <30 min of glucose history). Pre-v10 rows
have no `context` block at all.

### `settings.json`

One JSON object per day. Profile schedules (`basalSchedule`, `isfSchedule`,
`carbRatioSchedule`, `bgTargetSchedule`) are arrays of
`{startMinutes, value}` (or `{startMinutes, low, high}` for targets), where
`startMinutes` is minutes-from-midnight. To find the value active at time T,
pick the entry with the largest `startMinutes` ≤ T-minutes-into-day.

## Setup

```bash
git clone --branch telemetry --single-branch git@github.com:zgoettsc/trio.git trio-telemetry
cd trio-telemetry

# quick look at today's events
cat telemetry/$(date -u +%Y-%m)/$(date -u +%d)/events.jsonl | jq .

# all floor activations across all time
find telemetry -name events.jsonl | xargs -I{} cat {} \
  | jq -c 'select(.kind == "insulinReqFloorActivated")'
```

```python
import pandas as pd, glob, json
from pathlib import Path

def load_jsonl(pattern):
    rows = []
    for p in sorted(glob.glob(pattern)):
        with open(p) as f:
            rows.extend(json.loads(line) for line in f)
    return pd.DataFrame(rows)

events  = load_jsonl("telemetry/*/*/events.jsonl")
loops   = load_jsonl("telemetry/*/*/loop.jsonl")
sums    = load_jsonl("telemetry/*/*/summary.jsonl")
# Outcome rows only
outcomes = sums[sums.peakBG.notna()].copy()
```

---

## Analysis 1 — Meal composition (macros) → BG effects under current settings

**Goal:** stratify meals by macro composition; see how peak BG, time-above-180,
BG-at-2h compare; relate to the user's current carb ratio and ISF.

**Inputs:** `events.jsonl` (carbEntry rows), `loop.jsonl` (BG trajectory after
each entry), `settings.json` (active CR/ISF at meal time).

(See git history for prior recipe — unchanged from v1 doc.)

---

## Analysis 2 — Missed meal detection + insulin prediction

(See git history for prior recipe — unchanged.)

---

## Analysis 3a — Did changing tuning Z affect outcomes?

(See git history for prior recipe — unchanged.)

---

## Analysis 3 — Quick-action validation (does the floor actually do more?)

(See git history for prior recipe — unchanged.)

---

## Analysis 4 — Basal / ISF / CR tuning (Claude-o-Tune style)

(See git history for prior recipes — unchanged.)

---

## Analysis 5 — Insulin-sensitivity readings vs per-meal excursion

(See git history for prior recipe — unchanged.)

---

## Analysis 6 — Carb-counting feedback (estimated carbs from BG response)

(See git history for prior recipe — unchanged.)

---

## Analysis 7 — Did the COB decay multiplier help? (v2 spec Feature 1)

**Goal:** verify that lowering `mealWindowCOBDecayMultiplier` (e.g.
from 1.0 → 0.5) actually changes per-loop behavior — and whether the
change reduces peak BG / time-above-range on fat/protein meals.

**Recipe:**

```python
loops["effectiveCOBDecayMultiplier"] = loops.get(
    "effectiveCOBDecayMultiplier", 1.0
)
# 1) Verify the setting reached oref
multiplier_in_window = loops[loops.mealWindowActive == True].effectiveCOBDecayMultiplier
print(multiplier_in_window.value_counts())

# 2) Pair meals at different multiplier values for the SAME SavedMeal.
# Requires the per-meal aggregation from Analysis 5 + 6.
# Match on: same savedMealId, similar enteredCarbs (±20%), similar
# autosensRatioAtActivation (±0.05), different multiplier-bucket
# (e.g. 1.0 vs ≤0.6). Compare peakBG and timeAboveRangeMinutes.
```

**What to look for:**
- Multiplier value appearing in `loops` rows during meal windows
  matches the setting in `settings.json` — proves the wire is intact.
- Peak BG should be EQUAL OR LOWER on the same meal with a lower
  multiplier (assuming carb count matches actual). If equal, the
  signal isn't strong enough at the chosen multiplier — try 0.4.
- Time-above-180 should drop modestly. If unchanged, the COB-dissolve
  problem may not be the main coverage gap for that meal.
- WATCH FOR HYPOS: lower multiplier = more sustained dosing past the
  natural absorption window. If `timeBelowRangeMinutes` rises, dial
  the multiplier back UP.

---

## Cross-cutting: `mealWindowActivated` event payload (schema update)

The event payload on `mealWindowActivated` now also carries the same
activation context: `bgTrend30m`, `autosensRatio`, `smartSenseRatio`,
`effectiveISF`, `carbRatio`. Useful when you want the context but
don't care which saved meal (or no saved meal was attached). The
`meals.jsonl` row is the canonical source if a SavedMeal *was* used —
it stays consistent across instance updates while events are
append-only.

---

## Caveats

- **Loop cadence isn't perfectly 5 min** — gaps happen during pump
  disconnects, app suspension, etc. Anything that depends on
  `samples × 5 min = elapsed time` will be slightly off; use actual
  timestamps when precision matters.
- **Trailing 6h not always present** — outcome rows are written only on
  app foreground after the +6h has elapsed. If the user never opens the
  app, the outcome stays in `pending_outcomes.json` until they do.
- **External boluses** carry units but no BG context — they were
  administered outside Trio. Treat their effective-ISF results with
  caution if you don't know exactly when they peaked.
- **`mealDetection` is a noisy classifier** — don't use as ground truth.
  Cross-reference with `carbEntry` events.
- **`carbEntry` for FPU expansion** — fat/protein get re-expanded as
  delayed carb-equivalent entries with `isFPU = true`. The original
  meal entry has `isFPU = false`. Filter to one or the other depending
  on whether you want to model the meal as the user logged it or as
  the algorithm sees it.
- **Time zones** — all timestamps are UTC in the JSONL. Convert before
  grouping by hour-of-day.
