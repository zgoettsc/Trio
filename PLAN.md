# Eating Mode Aggression Plan — Items 1-6

Living plan for upgrading the meal-window from "polite safety net" to "trust
the user's signal and treat any rise as a meal." Updated as decisions land.

**Status:** approved 2026-06-26. Implementation in progress.

---

## Background

The Action Button's design intent is: **user presses → system gets aggressive
and treats any rise as meal-driven, without further user intervention.**

The first round (commits `cac363e18` through `1c673557f`) implemented a
conservative safety net: a floor on `insulinReq` that activated only when
oref's own math collapsed to zero, with several guards (BG ≥ 120, rising,
IOB headroom, ≤ half-IOB-headroom magnitude). The 2026-06-26 data round 2
(see `FINDINGS.md` F-5, F-6, F-7) showed this implementation was too humble:

- The floor almost never fired because oref's `insReq` rarely collapses
  when a meal is well-bolused (or even partially bolused).
- The real failure mode was *late or under-bolused meals*, where oref's
  `insReq` was healthy but the default `smb_delivery_ratio = 0.5` halved
  every SMB, leaving the loop unable to keep up with a +10 mg/dL/5min rise.
  This produced a 215 mg/dL peak from a 40g snack that should have been
  manageable.

The six items below tighten the aggression knob along independent axes,
all guarded by existing safeties (maxIOB, minGuardBG, BG≥120 floor) and
expressed as toggleable settings so we can tune without rebuilds.

---

## The six items

### Item 1 — Bump `smb_delivery_ratio` to 0.8 whenever the window is active

**Current:** ratio bumps to 0.8 only when the floor was actively rescuing
`insReq`. Otherwise stays at profile default (0.5).

**Change:** ratio bumps to a user-configurable value (default 0.8) whenever
`mealWindowActive=true`, regardless of floor state.

**Math from round 2 data:** during the 19:46–20:11 climb, total SMBs would
have been ~2.37U instead of the actual 1.40U. The extra ~1U over 25 min
likely shaves significant peak.

**Status: SHIP**, default-on, value 0.8.

---

### Item 2 — Drop the floor's `delta > 0` rising guard

**Current:** floor only activates when `glucose_status.delta > 0 OR
short_avgdelta > 0`. With delta near zero (e.g., -1, 0, +1) during real
meal physiology where insulin and carbs are racing, the floor stays
dormant exactly when it might be useful.

**Change:** relax to `delta > -2`. The button-press is the meal signal; we
trust it and allow brief flat/slight-drop moments during absorption.

**Status: SHIP**, default-on. Toggleable so we can A/B if needed.

---

### Item 3 — Make the floor *additive* instead of replacement

**Current:** `insReq = max(insReq, floorAmount)`. Only helps when
`floor > insReq` — which round 2 data showed almost never happens.

**Change:** when `mealWindowActive` AND toggle on, `insReq = insReq +
floorAdder` where `floorAdder` is scaled by BG-above-target and velocity,
capped at half the IOB headroom. So if oref says insReq=0.6 and the
window-adder is 0.3, total becomes 0.9.

**Risk:** medium. This is meaningfully more aggressive. Existing 75% cap
+ maxIOB still bound the result, but we'd want to watch outcomes carefully.

**Status: SHIP, default-OFF** (opt-in). Ship the plumbing so we can flip
on after items 1, 2, 4, 6 are validated.

---

### Item 4 — Force `enableUAM = true` inside the window

**Current:** UAM (un-announced meal) treatment respects the user's
`profile.enableUAM` toggle. If turned off, oref ignores rise signals as
potential meals.

**Change:** when `mealWindowActive` AND toggle on, force `enableUAM=true`
regardless of profile setting. The user's button-press is exactly the
"announced meal" — UAM is the right regime.

**Status: SHIP**, default-on.

---

### Item 5 — Synthesize "phantom COB" inside the window

**Current:** oref's `mealCOB` only reflects actually-logged carbs.
Round 2 data showed a ~30 min lag between the user entering 40g and
oref's `mealCOB` reflecting it (F-7). During that window, eventualBG
mis-predicts a drop and `insReq` goes negative.

**Change:** when `mealWindowActive` AND toggle on AND `mealCOB < 15g`
AND BG rising, inject a virtual 20g (configurable) into `mealCOB`. Keeps
eventualBG honest. The injected COB drains naturally over the meal
duration; nothing gets written to CoreData.

**Risk:** high. We're lying to oref. If BG was actually about to crash,
the synthetic COB could mask the falling signal and lead to overdosing.
minGuardBG and IOB headroom partially mitigate but this needs heavy
real-world watching before turning on.

**Status: SHIP, default-OFF** (opt-in). Code is in place; flag-gated.
Wait for several weeks of data with items 1+2+4+6 active before
considering turning this on.

---

### Item 6 — Bump `maxSMBBasalMinutes` to 2× the user setting inside the window

**Current:** SMB size is capped at `basal_rate × maxSMBBasalMinutes / 60`
units. User has this at 45 (so ~75% of basal worth per SMB).

**Change:** when `mealWindowActive`, multiply this cap by a configurable
multiplier (default 2.0 = 90 min worth). Lets individual SMBs be roughly
twice as large when conditions allow.

**Status: SHIP**, default 2.0.

---

### Bonus — Configurable 75% tough-meal cap

Discovered while reviewing the math: the existing `toughMealSMBActive`
mode caps `microBolus ≤ insulinReq × 0.75`. Even with item 1's bumped
SMB delivery ratio of 0.8, this cap clips the practical effect early.

**Change:** expose the cap percentage as a setting (default 75 unchanged,
range 50–100). Allows raising to e.g. 90% inside meal windows to let
item 1 actually do its job.

**Status: SHIP**, default 75 (no behavior change initially), exposed so we
can tune from the UI.

---

## What's shipping vs. deferred

| Item | Default | Plumbing shipped | Default behavior change |
|---|---|---|---|
| 1 — SMB ratio boost | **on** | ✓ | yes — 0.5 → 0.8 in window |
| 2 — Relax rising guard | **on** | ✓ | yes — delta>-2 in window |
| 3 — Additive floor | **off** | ✓ | no — opt-in via setting |
| 4 — Force UAM | **on** | ✓ | yes — UAM forced in window |
| 5 — Phantom COB | **off** | ✓ | no — opt-in via setting |
| 6 — maxSMB minutes 2× | **on** | ✓ | yes — 45 → 90 in window |
| 75% cap | **unchanged** (75%) | ✓ | no — exposed for tuning |

Default-off items are fully implemented and toggleable — flipping the
setting needs no rebuild.

---

## Settings

New screen: **AI Insights → Eating Mode Tuning**

Eight toggles + four sliders (`mealWindowSMBRatioValue`, `mealWindowPhantomCOBGrams`,
`mealWindowSMBMinutesMultiplier`, `mealWindowToughMealCapPercent`). Each
control includes an inline trade-off note ("more aggressive — trades hypo
risk if button pressed without actually eating").

Storage: TrioSettings (persisted JSON, encrypted-at-rest like other settings).

---

## Telemetry — what we log so we can analyze

### Daily settings.json snapshot (existing file)

Adds: every new tuning field above. Written once per day; reflects current
configuration at snapshot time.

### Per-loop sample (loop.jsonl)

New columns per loop pass, capturing what was *actually applied* at that
moment (not just what the user set, since aggression only applies when
the window is active):

- `effectiveSmbDeliveryRatio` — the ratio oref ultimately used
- `effectiveMaxSMBBasalMinutes` — including any window multiplier
- `effectiveToughMealCapPercent` — the cap that bounded microBolus
- `floorBehavior` — `"off"` / `"replacement"` / `"additive"`
- `forcedUAM` — Bool, whether UAM was forced on this pass
- `phantomCOBGrams` — non-zero when phantom was injected this pass
- `relaxedRisingGuard` — Bool

### Tuning-change events (events.jsonl)

New event kind: `mealWindowTuningChanged`. Fired whenever any of the nine
settings changes value, with `{field, oldValue, newValue, timestamp}`.
Lets analysis correlate "did changing X improve outcomes?" without having
to scrape git history of settings snapshots.

---

## Implementation order

1. PLAN.md (this document) — done.
2. TrioSettings + TrioCustomOrefVariables additions.
3. determine-basal.js — all 6 items + configurable cap.
4. Eating Mode Tuning settings screen.
5. Telemetry: per-loop effective values + tuning-change event + settings snapshot fields.
6. Update README.md and ANALYSIS_METHODS.md.
7. Add findings entry recording the ship.

---

## Risk + rollback

- All six items respect existing oref safeties: maxIOB enforcement,
  minGuardBG predictive hypo block, BG≥120 floor on activation, the
  toughMeal cap (just configurable now).
- Each item is independently toggleable. If outcomes degrade, flip the
  offending setting off — no rebuild needed.
- The two highest-risk items (3, 5) ship default-off.
- Telemetry captures every applied value per loop, so post-hoc analysis
  can attribute any bad outcome to a specific setting combination.

If a serious problem emerges: the user can disable the entire meal
window via the existing AI Insights → Telemetry → Enable toggle (which
turns off the whole feature), or set every tuning toggle off (which
makes the window behave like the prior round-1 conservative version
with floor-only-when-insReq-collapses behavior).
