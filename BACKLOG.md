# Meal Intelligence — Backlog & Design Notes

Discussion notes from working sessions while observing live meal behavior.
Captures ideas that aren't yet implemented but are worth tracking. The
counterpart on the app branch is `docs/MEAL_INTELLIGENCE_BACKLOG.md` —
keep in sync when either is updated.

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

### (d) NEW SETTING: `mealWindowCOBDecayMultiplier` — shipped
Multiplies oref's per-loop COB decay rate during an active meal window.
0.5 = drain at half speed. Different from phantom-COB (which adds carbs)
— this stretches what's already there. Cleaner mental model than
phantom-COB because it doesn't lie about absorbed-vs-pending: the COB
that exists is real, it just takes longer to "use up."

### (e) Auto-extend window on late-rise detection — already done
When the live classifier upgrades to Complex via the late-re-rise rule,
the window auto-extends to mealClassifierMaxTotalDurationMinutes (600).
Verified during v2 implementation.

### (f) FPU factor tuning (oref-level)
The default fat/protein-unit expansion in Trio is conservative.
Increasing the FPU factor in oref settings ratchets up how much
late-carb-equivalent gets logged automatically. Generic, not per-meal,
so use cautiously — bumping too high will over-correct quick-carb meals.

### Recommended priority order
1. **(a) + (b) for known meals** — most immediate win, no code needed
2. **(c) as instances accumulate** — long-term fix via the estimator
3. ~~(d) as a new tunable~~ — **shipped (v2 spec)**
4. ~~(e) auto-extend on late upgrade~~ — **already in place**
5. **(f) FPU tuning** — last resort, blunt instrument

---

## 2. Live (a priori) carbs estimator — discussion

The post-hoc estimator (shipped in `SavedMealInstanceDetailView`) is easy
because we know peakBG. Live, you have to project. Three reasonable
approaches:

### A. Expectation-deviation method (cheapest) — shipped (v2 spec)
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
SavedMeal has ≥3 history rows). Banner + action sheet shipped in v2;
historical-curve overlay (B) and trajectory classifier (C) still
open follow-ups.

---

## 3. Known bugs / gaps observed in dinner 2026-06-27

- **Duplicate-alert path missed Treatments→Treatments same-flow.** Two
  65g carb entries logged 39 seconds apart, both `enteredBy: "Trio"`.
  Root cause: viewContext staleness. Fixed in v2 by using newTaskContext.
- **Override-during-window has no warning.** The `smbIsOff` warning only
  fires at meal-window activation. Fixed in v2: HomeStateModel observer
  on `.didUpdateOverrideConfiguration` fires a local push + telemetry
  event when an override starts during an active meal window.

---

## 4. Estimator sanity-check from current data

Three meals in 2026-06-27 telemetry calibrate the post-hoc estimator:

| Meal | Entered | Estimated | Delta | Note |
|---|---|---|---|---|
| Dinner — Coconut Chicken | 130g (doubled, intended 65g) | ~190g | +125g vs intended | Doubled entry was closer to reality than 65g; after temp-basal fix |
| Lunch — Indian | 30g | ~95g | +65g | Long late-rise plateau confirmed under-count |
| Previous dinner — Indian | 50g | ~155g | +105g | Backfilled instance, 11h tail, peak at 6.5h |

User's nutrition-label review post-meal confirmed estimator accuracy.
Indian dishes are most consistently under-counted; SavedMeal defaults
should be revised upward.

---

## 5. Meal tags (v3) — lightweight characterization without macros

**Idea:** add a tag system to SavedMeal AND to active meal-window
activation flow. User tags ingredients/attributes (`chicken`, `rice`,
`large`, `fatty`, `fruit`, `pizza`, etc.). Tag combinations seed the
loop without forcing macro entry, and per-user tag stats accumulate
to make personal predictions.

**Hybrid schema (recommended):**
- Structured dimensions for things that drive BG response: Size
  (small/medium/large), FatLevel (low/normal/high), CarbType
  (rice/quinoa/pasta/bread/none), ProteinType (chicken/beef/fish/none)
- Free-form tags for everything else: cuisine, restaurant, social context

The structured dims are what the prediction logic keys off; free-form
tags are for the user's own browsing/filtering.

**On activation without a SavedMeal:**
1. Press Action Button → meal window opens
2. Quick tag picker appears: "What's in this meal? [chicken] [rice] [large] [fatty] [+]"
3. User taps 2-4 tags (~2 seconds)
4. Window seeds with predicted classification (Simple/Medium/Complex
   from tag mix), suggested phantom COB, extended duration
5. User can still enter precise carbs later if they want

**The learning pipeline ties to the carbs estimator we already ship:**
- Each closed instance has tags + outcomes (peakBG, AUC, estimated carbs)
- Group instances by tag-combo; for n≥3 compute median carb-equivalent,
  median peak rise, median absorption shape
- On a new window with the same combo, suggest those medians as the seed
- Per-user model trains from the user's own physiology — no population
  data required

**Bootstrap problem:** new user has no learned data
- Ship structured-tag classification heuristics out of the box
  (rice+large+fatty → Complex; fruit+small → Simple)
- Make carb prediction LEARNED, with "n=2, low confidence" labels
  until enough data accumulates

**Three risks worth flagging:**
1. **Tag fatigue** — users invent 50 tags, never reuse most. Mitigate
   by surfacing "your most-used tags" first; only learn from tags
   used ≥3×.
2. **Prediction over-confidence** — with n=2 behind a combo, predictions
   could be wildly off. Show confidence; never let predictions drive
   auto-bolus.
3. **Replaces SavedMeals?** — tags COMPLEMENT, not replace. SavedMeal
   is "this specific dish I eat repeatedly"; tags are "what's in this
   fresh meal." Could even auto-promote: "you've tagged 'chicken+rice+
   steamed' 5 times — save it as 'Lunch chicken bowl'?"

**Phasing:**

| Phase | What ships | Effort | Value |
|---|---|---|---|
| 1 | Tags field on SavedMeal + edit UI + history filter | ~1 day | Passive: helps users browse their own history |
| 2 | Curated tag library + classification heuristic; picker at activation for fresh meals; seeds classification + extended duration | ~2 days | Active: meals without macros get an informed loop response |
| 3 | Per-user tag aggregation; learned carb-equivalent predictions w/ confidence; "Tap to accept predicted 85g" | ~3 days | Personalized: predictions improve with usage |
| 4 (later) | Voice/text/photo input → auto-tag suggestions | bigger | Friction collapse |

**Key insight:** macros are still the most accurate prediction when
the user has the data. Tags are the "I don't know exactly but I know
what it is" fallback — and a long-tail learning mechanism. The mental
model should be "tags as an informed prior; macros as ground truth
when available."

---

## 6. Inverse calibration (v3) — solve for CR/ISF given KNOWN carbs

**Idea:** flip the post-hoc estimator. Instead of trusting CR/ISF and
inferring carbs, trust carbs (when the user verified them) and infer
the effective CR (or ISF) that the BG response implies. Use this as
a low-friction calibration tool similar to a physio test.

**Math:**

Current estimator (forward direction):
```
carbs_implied = peak_rise × CR/ISF + insulin × CR
```

Solve for CR (assuming ISF is right):
```
CR = carbs / (peak_rise/ISF + insulin)
```

Solve for ISF (assuming CR is right):
```
ISF = peak_rise × CR / (carbs - insulin × CR)
```

**Worked example — Coconut Chicken dinner 2026-06-27 (true carbs ~200g):**
- peak_rise = 217, insulin ≈ 11 U, current CR = 13, current ISF = 58
- Back-calc CR with current ISF: 200 / (217/58 + 11) = **13.6 g/U**
  → suggests current CR ≈ correct
- Back-calc ISF with current CR: 217 × 13 / (200 − 143) = **49.5 mg/dL/U**
  → suggests current ISF (58) may be too high

**Why this is potentially BETTER than the forward estimator:**

The forward estimator's accuracy is bounded by CR/ISF accuracy —
every output inherits their error. Flipping uses the system to
*validate the foundational settings*. Get CR/ISF calibrated to
ground truth (verified carbs), then the forward estimator's
predictions become trustworthy.

**Design:**

1. **Verify-carbs flag on SavedMealInstance**
   - New field: `userVerifiedCarbsAmount: NSDecimalNumber?`
   - UI entry points:
     - Button on instance detail: "I'm confident this meal was exactly N g"
     - At carb-entry time: a "verified" toggle next to the amount
   - Tagged via `enteredBy: "Trio-Verified"` for the calibrator's filter
2. **Per-instance back-calc display**
   - On verified instances, show two new metrics:
     - Back-calculated CR (vs current profile, with Δ)
     - Back-calculated ISF (vs current profile, with Δ)
   - Same exclusion caveats as the estimator: override-affected,
     didn't-return-to-baseline, etc.
3. **Aggregator — new "Calibration" page or section in Saved Meal Detail**
   - Group verified-carbs instances by hour-of-day
   - Median back-calc CR per hour; median back-calc ISF per hour
   - n-count + confidence label
   - Highlight divergences from current profile:
     > "Verified meals 11am-2pm suggest CR=10.8 (current 13.0, −17%).
     >  5 instances over 14 days."
4. **Suggest adjustments, never auto-apply**
   - Match Trio's existing pattern (Autotune-style)
   - User reviews and accepts via the profile editor

**Identifiability — disentangling CR and ISF:**

One observation has one equation and two unknowns — can solve for
either given the other, not both. With many verified instances at
different times of day:
- Morning meals constrain morning CR/ISF
- Smaller meals (insulin term dominates) lean toward ISF info
- Larger meals (rise term dominates) lean toward CR info
- Solve as a constrained optimization across the schedule

For v1, simpler: assume one is fixed (the one the user trusts more,
usually ISF from their physio test) and only adjust the other.

**Tie-ins:**

- **Physio test:** clean bolus-and-observe gives a tight ISF anchor;
  verified meals give CR. Together they cross-validate.
- **Tags (item 5):** verified meals can be tagged. "Back-calc CR for
  high-fat meals is 11; for low-fat is 14" reveals composition-
  dependent absorption a flat CR can't capture. Composition-aware CR
  is a v4 idea.
- **Forward estimator:** once calibration is dialed, forward
  predictions get more trustworthy and could potentially replace
  manual carb entry for known meals.

**Risks:**

1. User claims certainty but isn't actually right → garbage-in
   - Mitigate by reserving the verified flag for label-readable meals
2. Single-meal back-calc is noisy
   - Mitigate by median across n≥3 + confidence labels
3. BG affected by other factors (exercise, stress, sensor noise)
   - Mitigate by excluding override-affected and didn't-return rows
4. Conflict with Autotune
   - Present as "complementary view," let user pick which to trust

**Effort:**
- Small (~1 day): verified-carbs entry + per-instance back-calc display
- Medium (~3 days): aggregator page + hour-of-day breakdown + suggestions
- Bigger if we want auto-apply-with-confirmation

**Verdict:** stronger tool than the forward estimator for serious
users. Forward says "we think the meal was bigger than you logged";
inverse says "we think your settings are off." Inverse is more
actionable because it improves everything downstream.
