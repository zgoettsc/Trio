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
| `mealWindowActivated` | source, estimatedCarbs, bg, iob, cob, delta5m, durationMinutes |
| `mealWindowCancelled` | source (`shortcut`/`homeBanner`/`liveActivityLink`), minutesSinceActivation, bg, iob |
| `mealWindowExpired` | source (`naturalExpiry`), elapsedMinutes, wasCarbsConfirmed |
| `mealWindowCarbsConfirmed` | carbs, fat, protein, minutesSinceActivation |
| `insulinReqFloorActivated` | bg, delta5m, velocity, iob, floorPriorInsulinReq, floorMagnitude, floorVelocityFactor, insulinReq, smbDelivered, minutesSinceWindowOpen |
| `smbDelivered` | units, isSMB, duringMealWindow (also: bg, iob, insulinReq when from loop) |
| `userBolus` | units, isSMB=false, duringMealWindow |
| `externalBolus` | units, duringMealWindow |
| `carbEntry` | carbs, fat, protein, isFPU, fpuID, enteredBy, note, duringMealWindow |

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

**Recipe:**

```python
# 1) Find every local carb entry
carb_entries = events[events.kind == "carbEntry"].copy()
# explode payload columns
for col in ["carbs", "fat", "protein", "duringMealWindow"]:
    carb_entries[col] = carb_entries.payload.apply(lambda p: p.get(col))

# 2) For each entry, attach the BG curve from t to t+6h
def trajectory(entry_ts, hours=6):
    ts = pd.to_datetime(entry_ts)
    loops["ts"] = pd.to_datetime(loops.timestamp)
    mask = (loops.ts >= ts) & (loops.ts <= ts + pd.Timedelta(hours=hours))
    return loops[mask][["ts", "bg", "iob", "cob", "insulinReq", "smbDelivered"]]

# 3) Compute outcomes per meal
def outcome(traj):
    if traj.empty: return None
    return {
        "peak_bg": traj.bg.max(),
        "time_above_180_min": ((traj.bg > 180).sum() * 5),
        "bg_at_2h": traj.iloc[min(24, len(traj)-1)].bg,  # 24 samples × 5min = 2h
        "smb_total": traj.smbDelivered.sum(),
    }

# 4) Stratify
carb_entries["outcomes"] = carb_entries.timestamp.apply(lambda t: outcome(trajectory(t)))
# Bin by macro ratios — high-carb / mixed / high-fat etc.
carb_entries["macro_class"] = carb_entries.apply(macro_classifier, axis=1)
grouped = carb_entries.groupby("macro_class").outcomes.apply(list)
```

**What to look for:**
- High-fat meals should show delayed peak vs. equivalent-carb pure meals.
- High-carb-no-fat meals reveal whether the user's CR is correctly tuned for
  "naked" carbs.
- Compare time-above-180 across composition classes at matched carb totals.

---

## Analysis 2 — Missed meal detection + insulin prediction

**Goal:** find BG rises that look like meals but weren't logged. Cluster their
early signatures (velocity, acceleration, smoothed-BG shape). For each cluster,
measure what insulin was eventually delivered and what peak BG resulted. Train a
predictor: signature → insulin-required-to-blunt.

**Inputs:** `loop.jsonl` (continuous BG + signal), `events.jsonl` (carb entries
to exclude announced meals).

**Recipe:**

```python
# 1) Find candidate rise-onsets in continuous loop data:
#    delta5m >= 4 for 3 consecutive samples, BG > 110
loops["ts"] = pd.to_datetime(loops.timestamp).dt.tz_localize(None)
loops = loops.sort_values("ts").reset_index(drop=True)
is_rise = (loops.delta5m >= 4).rolling(3).sum() == 3
rise_starts = loops[is_rise.shift(-2).fillna(False)]

# 2) Exclude rises within ±30min of a real carb entry
carb_times = pd.to_datetime(carb_entries.timestamp).dt.tz_localize(None).tolist()
def near_carb(t):
    return any(abs((t - ct).total_seconds()) < 30*60 for ct in carb_times)
missed = rise_starts[~rise_starts.ts.apply(near_carb)]

# 3) Cluster early signatures (first 15 min): velocity profile, acceleration peak
def signature(rise_start_ts):
    window = loops[(loops.ts >= rise_start_ts) &
                   (loops.ts <= rise_start_ts + pd.Timedelta(minutes=15))]
    return {
        "v_max": window.velocity.max(),
        "a_max": window.acceleration.max(),
        "jerk_peak": window.jerk.abs().max(),
        "bg_at_onset": window.iloc[0].bg,
        "smoothed_bg_at_onset": window.iloc[0].smoothedBG,
    }
missed["sig"] = missed.ts.apply(signature)

# 4) Outcome per missed meal: peak BG over next 4h + total SMB
def outcome(rise_ts):
    window = loops[(loops.ts >= rise_ts) &
                   (loops.ts <= rise_ts + pd.Timedelta(hours=4))]
    return {"peak": window.bg.max(), "smb_total": window.smbDelivered.sum()}
missed["outcome"] = missed.ts.apply(outcome)

# 5) Fit predictor (linear regression / random forest):
#    insulin_needed_to_blunt_peak_below_180 = f(v_max, a_max, jerk_peak, bg_at_onset)
```

**What to look for:**
- Are there distinct missed-meal velocity signatures (e.g., breakfast vs lunch)?
- What's the SMB-to-peak relationship? Could a meal-window-style flag have helped?
- Train an early-warning classifier that suggests opening a meal window when the
  signature matches.

---

## Analysis 3 — Quick-action validation (does the floor actually do more?)

**Goal:** verify the meal-window feature actually delivers more insulin than the
loop would have on its own, given comparable starting conditions.

**Inputs:** `loop.jsonl` (with `floorActivated`, `floorPriorInsulinReq`,
`floorMagnitude`), `summary.jsonl` (outcomes per window).

**Direct measurement — what the floor itself contributed:**

```python
floor_rows = loops[loops.floorActivated == True].copy()
floor_rows["delta_insulinReq"] = floor_rows.floorMagnitude - floor_rows.floorPriorInsulinReq
# The floor's direct contribution per loop pass
print(floor_rows.delta_insulinReq.describe())
# Cumulative per window
print(floor_rows.groupby("windowId").delta_insulinReq.sum())
```

Each floor activation has both the pre-floor `insulinReq` (what oref would have
requested without the feature) and the floored value. The difference is exactly
what the feature added.

**Counterfactual — vs. similar meals without active windows:**

```python
# Find loop-windows that LOOK LIKE meals (large positive delta) but
# mealWindowActive == False
nonwindow_meals = loops[(loops.mealWindowActive == False) &
                        (loops.delta5m >= 6) & (loops.bg > 120)]

# For each non-window candidate meal-time, compute outcome over next 4h
# Compare to outcomes from outcome rows where window was used
window_outcomes = outcomes[outcomes.closeReason != "userCancelledShortcut"]
nonwindow_outcomes = nonwindow_meals.groupby(
    nonwindow_meals.ts.dt.floor("4H")
).apply(compute_outcome)  # write your own

# Match by starting BG / time-of-day / IOB bucket, compare:
# - peak BG
# - time-above-180
# - total SMB delivered
```

**What to look for:**
- Floor's per-pass contribution should be 0.1–0.5 U typically (meaningful but
  bounded). If consistently 0, the floor isn't firing.
- Window outcomes should show LOWER peak BG and LESS time-above-180 vs matched
  non-window meals.
- If outcomes are equivalent or worse, the floor coefficients need tuning.

---

## Analysis 4 — Basal / ISF / CR tuning (Claude-o-Tune style)

**Goal:** suggest specific profile adjustments based on observed behavior.

**Inputs:** `loop.jsonl` (continuous BG + insulin), `events.jsonl` (carbs + bolus
events), `settings.json` (current schedule + history).

### Basal tuning

Find "clean basal windows": ≥ 3h stretches with no carbs entered (±2h), no
manual bolus (±2h), no active meal window, no override.

```python
def is_basal_clean(loop_ts):
    # No carb entries within ±2h
    if any(abs((loop_ts - pd.to_datetime(c)).total_seconds()) < 2*3600
           for c in carb_entries.timestamp):
        return False
    # No userBolus events within ±2h
    manual = events[events.kind == "userBolus"]
    if any(abs((loop_ts - pd.to_datetime(b)).total_seconds()) < 2*3600
           for b in manual.timestamp):
        return False
    return True

loops["basal_clean"] = loops.ts.apply(is_basal_clean)
clean = loops[loops.basal_clean]

# Group by hour-of-day → compute mean BG drift
clean["hour"] = clean.ts.dt.hour
drift = clean.groupby("hour").bg.apply(lambda g: g.iloc[-1] - g.iloc[0] if len(g) > 1 else 0)
# Hours with consistent positive drift → basal probably low for that hour
```

### ISF tuning

Find correction events: manual bolus OR SMB with no carbs entered within ±1h
AND starting BG > target + 30. Walk forward 3h, measure BG drop. Effective ISF
= drop / units. Compare to scheduled ISF for that hour.

```python
smb_events = events[events.kind == "smbDelivered"]
correction_candidates = []
for _, row in smb_events.iterrows():
    ts = pd.to_datetime(row.timestamp).tz_localize(None)
    # No carbs near
    if any(abs((ts - pd.to_datetime(c)).total_seconds()) < 60*60
           for c in carb_entries.timestamp):
        continue
    # 3h forward BG trajectory
    traj = loops[(loops.ts >= ts) & (loops.ts <= ts + pd.Timedelta(hours=3))]
    if traj.empty: continue
    bg_drop = traj.iloc[0].bg - traj.bg.min()
    correction_candidates.append({
        "ts": ts, "units": row.payload["units"],
        "starting_bg": traj.iloc[0].bg, "bg_drop": bg_drop,
        "effective_isf": bg_drop / row.payload["units"] if row.payload["units"] > 0 else None,
        "hour": ts.hour,
    })
corrections = pd.DataFrame(correction_candidates)
# Suggested ISF = median effective_isf for each hour
suggested_isf = corrections.groupby("hour").effective_isf.median()
```

### CR tuning

Find clean meal events: single `carbEntry` with carbs > 20, no override, no
other carb entries within ±4h. Walk forward 5h. Total insulin delivered (SMBs
+ manual bolus) within 4h post-meal vs carbs entered. Compare back-calculated
CR to scheduled.

```python
clean_meals = []
for _, c in carb_entries[carb_entries.carbs > 20].iterrows():
    ts = pd.to_datetime(c.timestamp).tz_localize(None)
    # No other carb within ±4h
    nearby = carb_entries[carb_entries.timestamp != c.timestamp]
    if any(abs((ts - pd.to_datetime(n.timestamp)).total_seconds()) < 4*3600
           for _, n in nearby.iterrows()):
        continue
    post = loops[(loops.ts >= ts) & (loops.ts <= ts + pd.Timedelta(hours=4))]
    if post.empty: continue
    total_insulin = post.smbDelivered.sum()
    # Add manual boluses in window
    manual_in_window = events[(events.kind == "userBolus")]
    for _, m in manual_in_window.iterrows():
        mt = pd.to_datetime(m.timestamp).tz_localize(None)
        if ts <= mt <= ts + pd.Timedelta(hours=4):
            total_insulin += m.payload["units"]
    peak = post.bg.max()
    # Adequate-coverage filter: only count if peak stayed below 180
    if peak > 180: continue
    clean_meals.append({
        "carbs": c.carbs, "total_insulin": total_insulin,
        "back_calc_cr": c.carbs / total_insulin if total_insulin > 0 else None,
        "hour": ts.hour,
    })
cm = pd.DataFrame(clean_meals)
suggested_cr = cm.groupby("hour").back_calc_cr.median()
```

### Producing suggestions

Compare suggested vs. current schedule (from `settings.json`), output a diff:

```
Hour 06:00 — basal 0.75 U/h, drift +12 mg/dL over avg 3h clean window
  → suggest basal 0.85 U/h (+13%)
Hour 14:00 — ISF 50 mg/dL/U observed median 38
  → suggest ISF 38 (more aggressive)
Hour 18:00 — CR 12 g/U observed back-calc 10
  → suggest CR 10 (more aggressive)
```

Always present as **suggestions**, never auto-apply. Confidence depends on
sample count per hour — flag hours with <5 events as low-confidence.

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
