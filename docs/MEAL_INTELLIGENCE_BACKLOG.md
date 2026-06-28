# Meal Intelligence — Backlog & Design Notes

Discussion notes from working sessions while observing live meal behavior.
Captures ideas that aren't yet implemented but are worth tracking. The
counterpart on the `telemetry` branch is the same document — keep in sync
when either is updated.

---

## 1. COB dissolving too fast — strategies

Oref's COB model decays once `min_5m_carbimpact` worth of BG rise is
"absorbed" each loop. Fat-protein meals routinely outlast the model.
Observed pattern in dinner 2026-06-27 (Coconut Chicken) and Indian
2026-06-26 (last night's dinner): COB drains to 0 well before BG actually
peaks, leaving a long un-covered climb during the late phase. Floor
activations fire sparsely in this window because oref's eventualBG hits
the 39 mg/dL minimum-floor sentinel and stops requesting insulin.

Levers in order of usefulness:

### (a) `extendedDurationMinutes` on the SavedMeal — already supported
Trio keeps meal-window aggression alive past oref's natural absorption
window — floor still fires after COB hits 0. Set Indian / Coconut
Chicken to 8h. Underused today.

### (b) Phantom COB at activation — already supported
Injects ~20-30g of fake carbs at activation for known fat-heavy meals.
Keeps oref in "still digesting" mode and prevents the floor-only dead
zone (observed at 22:50-23:27 on dinner 2026-06-27).

### (c) Bump SavedMeal default carbs to reality
The new in-app per-instance carbs estimator is exactly the feedback loop
for this. After 3-5 instances, look at the per-meal `median_delta` and
nudge defaults up. Concrete from current data:
- Indian: 30-50g default → recommend 80-120g
- Coconut Chicken: 65g default → recommend 130g

### (d) NEW SETTING: `mealWindowCOBDecayMultiplier`
Multiplies oref's per-loop COB decay rate during an active meal window.
0.5 = drain at half speed. Different from phantom-COB (which adds carbs)
— this stretches what's already there. Cleaner mental model than
phantom-COB because it doesn't lie about absorbed-vs-pending: the COB
that exists is real, it just takes longer to "use up."

Wire: add to `TrioSettings`, pass through `TrioCustomOrefVariables`, and
multiply the relevant decay factor in `determine-basal.js` when
`mealWindowActive == true`.

### (e) Auto-extend window on late-rise detection
When the live classifier upgrades to Complex via the late-re-rise rule,
also auto-extend the window by 2h. Right now classification upgrades
change SMB aggression but not duration. The Indian meal at 2026-06-27
01:27 upgraded to Complex at t=178 min but the window only ran the
standard duration — the slow-rise tail kept going for another 4 hours
with no aggression backing it.

### (f) FPU factor tuning (oref-level)
The default fat/protein-unit expansion in Trio is conservative.
Increasing the FPU factor in oref settings ratchets up how much
late-carb-equivalent gets logged automatically. Generic, not per-meal,
so use cautiously — bumping too high will over-correct quick-carb meals.

### Recommended priority order
1. **(a) + (b) for known meals** — most immediate win, no code needed
2. **(c) as instances accumulate** — long-term fix via the estimator
3. **(d) as a new tunable** — clean new lever worth building
4. **(e) auto-extend on late upgrade** — small, high-leverage change
5. **(f) FPU tuning** — last resort, blunt instrument

---

## 2. Live (a priori) carbs estimator — discussion

The post-hoc estimator (shipped in `SavedMealInstanceDetailView`) is easy
because we know peakBG. Live, you have to project. Three reasonable
approaches:

### A. Expectation-deviation method (cheapest)
Each loop, compute what BG *should be* given activation BG +
COB-absorbed-so-far × ISF/CR − insulin-delivered × ISF. If actual exceeds
expected by more than ~30 mg/dL, the missing rise implies extra carbs
you didn't log:

```
implied_extra_carbs = (actual_BG - expected_BG) × CR / ISF
```

At 30-min in, if oref says you "have 40g COB left covering 100 mg/dL of
future rise," but BG already passed that prediction by +50 mg/dL, you've
got ~11 extra grams unaccounted. Surfaces early. Wide confidence early,
narrows with time.

### B. Compare to historical curve for this saved meal
With even 3-5 prior instances of "Indian," you have a median BG
trajectory. At minute T of the current window, if BG is above the
historical 90th percentile, flag. Then ratio:

```
implied_carbs = actual_rise_at_T / median_rise_at_T × historical_estimated_carbs
```

Calibrates against the user's actual physiology, not a generic model.

### C. Trajectory shape classifier
Distinguish "still accelerating at 45 min" (huge meal) from "rolling
over at 45 min" (matched correctly). The Simple → Medium → Complex
classifier we already have does some of this; an extension could attach
a carb-magnitude estimate to each phase transition.

### Recommended combo
Live use of (A) (general-purpose, works for any meal) + (B) (when a
SavedMeal has ≥3 history rows). Show as a banner in the home view's
meal-window pill:

> ⚠ This meal looks ~30g bigger than entered (110g vs 65g).
> [Add 45g] [Dismiss]

Trigger when implied-extra > max(20g, 30% of entered) for 3 consecutive
loops. Three-loop confirmation cuts down on noise from sensor spikes.
The "Add 45g" action would inject a delayed carb entry (or bump phantom
COB) immediately.

### Caveats to surface in UI
- First 30 min the signal is noisy because absorption hasn't begun. Don't
  fire suggestions in that window.
- An override changes the math — suppress suggestions during
  override-affected windows.
- ISF / CR uncertainty bleeds into the estimate. Show a range, not a
  single number.
- "Massively bigger" is more actionable than "slightly bigger" — set the
  trigger conservatively so it only fires on real misses.

### Three-tier feedback loop the pieces form together
1. **Live (A+B)** — mid-meal nudge to correct in real time
2. **Post-hoc (shipped)** — instance-detail audit after the meal closes
3. **Aggregated** — per-meal `median_delta` across months suggests
   baseline corrections to SavedMeal defaults (and the `Analysis 6`
   recipe in `ANALYSIS_METHODS.md` is the offline version of this)

---

## 3. Known bugs / gaps observed in dinner 2026-06-27

- **Duplicate-alert path missed Treatments→Treatments same-flow.** Two
  65g carb entries logged 39 seconds apart, both `enteredBy: "Trio"`.
  The duplicate-alert gate doesn't fire on this exact flow. Investigate.
- **Override-during-window has no warning.** The `smbIsOff` warning only
  fires at meal-window activation. If an override starts AFTER the
  window opens (Running override fired at 22:33, 16 min into the
  window), the user gets no alert that aggression was just neutered.
  Fix: add an observer on override state-changes while a meal window is
  active.

---

## 4. Estimator sanity-check from current data

Two meals in 2026-06-27 telemetry calibrate the post-hoc estimator:

| Meal | Entered | Estimated | Delta | Note |
|---|---|---|---|---|
| Dinner — Coconut Chicken | 130g (doubled, intended 65g) | ~153g | +88g vs intended | Doubled entry was closer to reality than 65g |
| Lunch — Indian | 30g | ~95g | +65g | Long late-rise plateau confirmed under-count |
| Previous dinner — Indian | 50g | ~155g | +105g | Backfilled instance, 11h tail, peak at 6.5h |

User's nutrition-label review post-meal confirmed estimator accuracy.
Indian dishes are most consistently under-counted; SavedMeal defaults
should be revised upward.
