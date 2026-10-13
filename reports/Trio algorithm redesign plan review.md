# Trio algorithm redesign — adversarial review of the implementation plan

Reviewed: `reports/Trio algorithm redesign implementation plan.md` (the "plan") against `reports/Trio algorithm redesign research.md` (the "report"), `research_notes/Trio algorithm redesign research/trio_codebase_algorithm.md` (the "audit"), and the working tree at `fc78241b` (parent `b38a5a41`, `APP_VERSION = 0.8.3`). Every repository claim below was checked directly in the tree; line numbers are from this checkout. Nothing other than this file was written.

The user is one developer dosing insulin into their own body, will not announce meals, and wants the plan battle-tested before code changes. The review is written for that reader: each finding names the plan section, what goes wrong, and the specific change.

---

## Executive summary — what must change before this plan is executed

1. **The supervisor is not subtract-only as specified (Critical, §3.2, §3.6, §3.3).** The "resume at 50% basal after 150 minutes of zero temp" rule and the anti-windup "fall back to profile basal" rule produce `rateOut > rateIn` whenever the core itself proposed a zero temp (its own LGS, `determine-basal.js:1407-1430`). That trips the plan's own stop condition 3 and fails `testNeverIncreasesUnitsOrRate`. Every supervisor output must be written as `rate' = min(rateIn, …)` and `units' = min(unitsIn, …)`; resume/fallback rules may only relax the supervisor's *own* suspensions. The velocity-gate temp formula (§3.3) must likewise be `rate' = min(rateIn, basal + max(0, rateIn − basal)·g(v))` so a low temp is never raised toward basal.

2. **The Kalman filter the plan promotes into dosing is fed wrongly today, and the plan pins that behaviour as "correct" (High, S1.1, S1.3, S1.4, §2.5).** `APSManager.swift:507-520` feeds `signalPipeline.processGlucose(rawBG: determination.bg, at: now, …)` once per 3-minute loop, stamped with the loop time rather than the CGM reading time; with 5-minute CGM cadence the same value is re-fed as a new sample, so velocity is biased toward zero on repeat ticks and spikes when a fresh reading lands. There is no de-duplication (`OrefSignalPipeline.swift:150-158`) and no persistence or history seeding (`AdaptiveKalmanFilter.swift:113 reset()`; `BGSignalProcessor.history` is in-memory), so after any app relaunch the state is unconverged with age 0 — the plan's fallback (§3.2 "Kalman state >7.5 minutes old") never fires in exactly the case it is needed. `KalmanRegressionTests.testFilterOutputMatchesSignalExportFixture` (S1.4) would freeze the flawed feed as the reference. Fix: in S0.3 re-feed the filter from `GlucoseStored` timestamps (one update per distinct reading, seeded from the last 72 on launch), gate all Kalman-dependent rules on `updatesSinceReset ≥ 6` and on reading-timestamp age, and replace the regression fixture with one regenerated from glucose rows.

3. **The CGM-quality, calibration and "no calibration in 30 min" preconditions are inert for plugin CGMs, and one of them guards a lockout relaxation (High, §3.1, S1.4, S0.3).** `PluginSource.swift:245-252` hard-codes `noise: nil, type: "sgv"` for every plugin CGM (G5/G6/G7/Libre), and nothing in the tree ever stores a `"cal"` record. The plan's statement that "Dexcom G6/G7 and xDrip give `noise`" is wrong for the plugin path; only the Nightscout/xDrip JSON path can carry noise. Consequences: `cgmQuality` will be `unknown` on essentially every loop, and S1.4(a)'s relaxation of the `maxDelta` SMB lockout — whose purpose in oref is precisely to block calibration/compression jumps — is gated on the *absence* of a flag that can never be set. Fix: require positive evidence of quality before relaxing any safety lockout (raw-vs-smoothed agreement, Kalman innovation within bounds, ≥3 consecutive consistent readings), treat `unknown` as "no relaxation ever", and drop the `noise`/`isCalibration` rows from the S1.1 gate list until a CGM path that supplies them exists.

4. **The non-inferiority gates are statistically unachievable as written, which guarantees "fail/n/a" verdicts and invites overriding them (High, §1 "Standard safety margins", §4).** With day-level paired differences, a typical SD of daily TBR<70 of 2–4 percentage points and 14 days per arm, the 90% CI half-width is ~1.3 pp; the margins are +0.3 pp (TBR<70), +0.1 pp (TBR<54) and +0.2 LBGI. Showing non-inferiority at +0.3 pp needs on the order of 250 paired days, not 14. Either pre-register wider, honest margins (e.g., +1.0 pp TBR<70, +0.3 pp TBR<54) with a written power statement, or switch the safety co-primaries to event-based rules (count of <54 episodes, count of <70 episodes attributed to a non-baseline stage) evaluated as hard stop conditions, and use the CI only for efficacy endpoints.

5. **Core Data migration (S0.3) makes the "frozen baseline build" un-reinstallable on the phone (High).** `CoreDataStack.swift:44-45` enables lightweight migration, so the forward step works; but once the store is at model v2, no earlier build (including the `baseline-live-2026-10` build) can open it. The plan's rollback ("Core Data fields stay, nullable") and the §6.2 "rollback rehearsed once" step are therefore not true for S0.3 or anything after it. Fix: ship the model change as its own first release, and cherry-pick the v2 model onto the baseline tag so the baseline build remains installable; require an on-device export before installing the migrated build.

6. **Carb-free constraint is violated in four places that affect safety, not just validation (High, S2.1, §2.5, S0.7, S1.x "sushi case").** (a) S2.1 suppresses detection after rescue carbs only via `CarbEntryStored.isRescueCarbs`; this user will not tag rescue carbs, so post-hypo rebounds will be detected as meals and dosed into. Add a glucose-only rule: no detector action for 90 minutes after any reading <70 or any supervisor suspend. (b) The sushi case used as the canonical gate in S1.1, S1.3, S2.1, S2.2 and S2.3 was an **announced** meal (80 g entered, 5.65 U bolus, `docs/TOUGH_MEAL_HANDLING.md:12-20`); its 118→267 rebound shape is a post-bolus artefact that will not exist on an unannounced day, and it is from March 2026, outside the plan's July–October fixture window and the 30-day telemetry retention (`AlgorithmTelemetryManager.swift:1043-1048`). Replace it with ≥5 unannounced episodes from the recorded period. (c) The personal twin (S0.7) is fitted "over the user's detected meal episodes" from "residual-implied grams" computed with the very ISF/CR the twin is meant to estimate; without a meal record, meal size and insulin sensitivity are not jointly identifiable, and a 30-minute RMSE ≤25 mg/dL gate is met by a persistence forecast. Demote twin counterfactuals to consistency checks unless identifiability is demonstrated on held-out isolated corrections and fasting nights. (d) S2.5's ISF estimator needs "isolated corrections" with no other above-basal delivery for 90 minutes; in an SMB system these are rare, so the prior will dominate and ISF will not actually be learned — say so, or design the estimator around SMB trains.

7. **S1.4(a) as written cannot work: the JS reads `maxDelta_bg_threshold` from `profile`, not `preferences` (High).** `determine-basal.js:1369-1372` reads `profile.maxDelta_bg_threshold`; the only `preferences.*` keys the JS reads are `useNewFormula`, `sigmoid`, `adjustmentFactor*`, `curve`, `useCustomPeakTime`. The "derived preference override at `OpenAPS.swift:478-482`" pattern patches the wrong document. The same applies to S2.1's target/ISF override (correctly described as a profile patch) with a side effect the plan misses: lowering `min_bg` lowers the core's `threshold` (`:733-737`) and therefore the LGS/SMB-disable floor and the supervisor's hard floor at the same time. Patch the profile JSON, and pin `threshold_setting` to the pre-override threshold whenever a target override is active.

8. **The TDD used for per-SMB caps and budgets is the 2-hour-extrapolated blend, which inflates during the exact stacking episodes the caps exist to bound (High, S1.3, §3.5).** `weightedAverage` is `0.35 × avg(last 2 h TDD rows) + 0.65 × avg(10 d)` (`OpenAPS.swift:553-590`). Anchor caps and budgets to the 7–10-day TDD only, never a blend containing the current episode.

9. **A crash or exception in the new pipeline must fail to the core proposal, and there is no 3 a.m. runbook or second-person review point (High, §1 conventions, §5, §6).** The plan never states that `DosingPipeline.apply` is wrapped so that any error yields the unmodified core determination (a Swift trap in the pipeline kills the app and opens the loop). Add that invariant and a test. Add a consolidated runbook (open loop, kill switch location and exact effect, verify command, where traces are, pump suspend/pod removal) and a mandatory second-person (endocrinologist or experienced looper) sign-off before S1.3 goes live, which is the first add-insulin path.

10. **Several factual anchors are off and two technical claims are wrong (Medium, §0(b), S0.2, S0.4, §2.6).** Hook lines are `OpenAPS.swift:517/540` not 512/538; the inner JS call (`:908-955`) has no `clock` parameter at all, so the fix threads three sites, not two; `prepare/autosens.js` and `autosens.js:27` also read the wall clock, so "the only JS edit is the five-line clock fix" is not true for a replay that re-runs autosens; there are 123 `@Test` functions, not 99; `Trio/Sources` is not a synchronized group (only two small groups are), so every new app-side file is a `pbxproj` edit, not "one"; `trio-replay` with `JSOrefCore` needs JavaScriptCore and therefore macOS runners (not available on Linux Swift), so the 7-hour nightly cannot run on GitHub-hosted macOS (6-hour job limit, 10× minute multiplier) and must run on the developer's Mac or via a Node runner of the same bundle.

---

## Dimension 1 — Patient safety

| Severity | Plan section | Finding | Recommended fix |
|---|---|---|---|
| Critical | §3.2, §3.6 | "Resume at 50% basal for 30 min after 150 min zero temp" and "anti-windup → profile basal" can emit `rate' > rateIn` when the core proposed a zero temp. Contradicts §3's "can only subtract", stop condition 3, and `testNeverIncreasesUnitsOrRate`. | Define every supervisor output as `min(rateIn, …)`, `min(unitsIn, …)`. Resume rules apply only to supervisor-originated suspensions. Add a test where the core proposes `rate 0` and the supervisor has been suspending for 150 min. |
| High | §3.3 | Temp formula `rate = basal + (rate − basal)·g(v)` raises a low temp toward basal when `g<1` (basal 1.0, core 0.3, v −0.5 → 0.65 U/h). The text says "above-basal temp" but the formula is not guarded. | `rate' = min(rateIn, basal + max(0, rateIn − basal)·g(v))`; include low-temp cases in the property test. |
| High | S1.1, S1.3, S1.4, §3.2 | Kalman state is fed with `determination.bg` at loop time (`APSManager.swift:507-520`), not per CGM reading; repeated readings at 3-min cadence corrupt velocity/acceleration; no persistence; fallback keyed on age not convergence. | Feed per distinct `GlucoseStored` reading; seed from last 72 on launch; gate on `updatesSinceReset ≥ 6`; fallback to least squares over raw readings otherwise. Regenerate the regression fixture. |
| High | §3.1, S1.4(a), S0.3 | `noise`/`isCalibration` never populated for plugin CGMs (`PluginSource.swift:245-252`); "no calibration in 30 min" and `cgmQuality == ok` preconditions are vacuous; S1.4 relaxes the calibration-jump guard on the strength of an inert flag. | Relaxation requires positive quality evidence; `unknown` ⇒ never relax; remove noise/cal rows from S1.1 gates until a CGM path supplies them; document which CGM the user runs and what it provides. |
| High | S1.3, §3.5 | Caps/budgets anchored to `weightedAverage` (contains 2-h extrapolated TDD) → caps grow during SMB trains. | Use 7–10-day TDD for every cap; log both. |
| High | S2.1 | Rescue-carb suppression depends on the user tagging rescue carbs. Post-hypo rebound → "meal" → target/ISF override → second low. | Glucose-only suppression: no positive detector action for 90 min after any reading <70, any supervisor suspend, or any `carbsReq` notification. |
| High | S2.1 | Target override lowers the core's `threshold` (`determine-basal.js:733-737`) and so the LGS floor and §3.8 hard floor during the override. | Pin `threshold_setting` to the pre-override threshold while any derived target override is active. |
| High | §1 conventions, S0.6 | No stated fail-safe for pipeline errors. A Swift trap in a stage = app crash = open loop (hyperglycaemia/DKA path). | `DosingPipeline.apply` must catch and return the core proposal with a trace flag; a test injects a throwing stage. Add stop condition: loop-failure rate increase. |
| High | §1 kill switch, S1.2 | Kill switch leaves the supervisor "in whatever mode it has". If the supervisor is `off`/`shadow` at that moment, the switch reverts to the pre-supervisor fork, which the report forbids. `legacyMealWindow` has inverted semantics (`shadow` = legacy stack active) — a hazard inside a safety toggle. | Kill switch sets supervisor `live` if it has ever been promoted and `legacyMealWindow` to retired; rename the legacy toggle (`legacyStack: enabled|retired`) so "off" means the safe state everywhere. |
| High | S0.3 | Core Data v2 store cannot be opened by the baseline build; "rollback" and "rehearsed rollback" are false after S0.3. | Separate release for the model change; cherry-pick onto the baseline tag; export before migrating. |
| Medium | §3.8 | "Hard floor `units ≤ 3.0 U`" is a ceiling six times the baseline's typical 0.5 U and offers no protection at TDD ≈ 40. | Hard ceiling = `min(3.0, 0.05 × TDD10d)`; keep the `bg < threshold ⇒ 0` floor. |
| Medium | §3.5 | Budget data source unspecified. Counting proposals under-counts failed deliveries; counting pump history (Omnipod reports bolus on completion) lags and permits stacking. | Count proposals immediately, reconcile with pump history, and treat unreconciled proposals as delivered for 30 min. |
| Medium | S1.1 rollback, §3 | Supervisor state "in-memory + small file"; if memory is authoritative, a crash loop clears budgets/hysteresis every relaunch. | File is the source of truth, written before enactment; relaunch restores. |
| Medium | §3.6, S2.2, S2.3 | No under-delivery/site-failure path. Anti-windup cuts SMBs to zero for 60 min during a persistent high; the integrator and absorption estimator push insulin into a failing site. | Add a "no glucose response to delivered insulin" detector: persistent >250 with rising IOB and non-falling glucose for ≥3 h ⇒ suppress positive integrator/absorption effects, raise a site-check alert; anti-windup should notify, not silently withhold. |
| Medium | S2.1 | Compression low during a genuine episode triggers FP rollback + 30-min zero temp while carbs absorb → rebound. | Require two consecutive readings and `cgmQuality != compressionSuspect` (sharp drop with flat trend before) before rollback; log suspected compression. |
| Medium | S2.1 | Report item 6's "debit any later user bolus by corrections already delivered" is missing. The user does bolus sometimes (sushi: 5.65 U). | Manual bolus during Confirmed/Committed ⇒ immediately Recovering; expose detector-delivered insulin to the bolus calculator. |
| Medium | §4 confounders, §2.2 | Time zone/DST: schedule lookups use the JSC process's local time (`profile/basal.js:10`, `iob/history.js:520`); trace stores no TZ; replay on CI will pick the runner's TZ. | Record `TimeZone.identifier` per loop in the trace and fingerprint; `trio-replay` sets TZ per tick. |
| Medium | S1.2 | "Strictly reduce-only" is asserted, not shown; forced UAM and phantom COB alter `minPredBG` blending (`determine-basal.js:1257-1296`) and can move it either way. | Downgrade to "expected reduce-only; monotonicity is a replay gate, not an assertion"; list exceptions if any. |
| Medium | S0.3 Backfill, §2.1 | Telemetry keeps only 30 days locally (`purgeLocal(olderThan: 30)`); profile provenance for most of the 90 days will be `assumed-current`. The user's therapy-profile switching (`ProfileManager`) makes "current profile" wrong for scheduled switches. | Backfill profile from `OrefDetermination.insulinSensitivity/carbRatio/currentTarget/scheduledBasal` per loop (already stored) rather than the current profile. |
| Low | §3.1 | `stale ⇒ rate ≤ basal` is a ceiling, not a value; could be read as "set to basal". | Write `rate' = min(rateIn, basal)`. |
| Low | S0.2 | Claim "no observable difference" from the clock fix is correct in production, but `prepareTrioCustomOrefVariables` (`OpenAPS.swift:562-641`) still uses `Date()` five times; harmless on device, matters for the package's purity contract. | State that custom variables are an *input* document and are never recomputed inside `DosingCore`. |

**Failure modes the supervisor cannot see and the plan does not address:** pump suspend state (enactment is skipped at `APSManager.swift:1695-1698`, so budgets based on proposals drift), duplicated or delayed Omnipod history (affects IOB and budgets), phone reboot mid-loop (Kalman and supervisor state), and app crash loops (open loop). Each needs either a stated fail-safe or a dashboard/stop condition.

**Is "reduce-only first" real at the code level?** S1.3 yes (sizer applied only when `units < unitsCore`). S2.2 yes (negative effects only). S2.5 yes. S2.1 no: in `reduceOnly` the override never fires, so the FP rollback has nothing to roll back, and the only live effect is the Recovering reduction (`upper → lower` for 60 min), which makes the system *less* aggressive than the S1.3 state it is compared against — the arm measures a regression, not the detector. S2.6's "+30 mg/dL target raise counts as reduce-only" is a profile override, not a subtraction on the proposal; it must run through the supervisor's min() to be provably so.

**Would the developer notice if the harness were wrong?** For the core, yes (`verify` ≥99.9% byte-for-byte is a strong self-test). For pipeline stages and the Kalman input, no: the same flawed input feeds both live and replay, and the regression fixture is derived from the flawed output. Add an independent oracle: recompute velocity from raw `GlucoseStored` rows with a finite difference and alert when the Kalman velocity disagrees by >1 mg/dL/min for 3 ticks.

## Dimension 2 — Validation integrity

| Severity | Plan section | Finding | Recommended fix |
|---|---|---|---|
| High | §1 margins, §4 | Non-inferiority at +0.3 pp TBR<70 / +0.1 pp TBR<54 / +0.2 LBGI with 14 paired days per arm is not achievable (CI half-width ≈ 1.3 pp). Every gate row will read fail/n/a. | Pre-register achievable margins with a power statement, or make safety co-primaries event-count stop rules and reserve CIs for efficacy. |
| High | S0.7, §2.2 counterfactual | Twin fitted without meal inputs is not identifiable; the fit RMSE gate is met by persistence; counterfactual TBR/TIR will reflect assumptions. | Demote twin to consistency check; gate on held-out insulin-response windows (isolated corrections, fasting nights); report profile-likelihood identifiability for SI and meal gain. |
| High | S1.1/S1.3/S2.1/S2.2/S2.3 sushi gates | Canonical scenario is an announced, bolused meal from March 2026, outside the fixture window and telemetry retention. | Replace with ≥5 unannounced episodes from recorded traces; keep sushi only as a documented historical reconstruction. |
| Medium | §2.2 divergence scoring | "Dosed more into a later low within 2 h" favours under-dosing candidates; "dosed more into a confirmed rise" rewards aggression regardless of the 3–6 h tail (the slow-meal failure mode). | Score lows over 6 h after the decision; add "insulin delivered in hours 3–6 after an episode onset vs baseline" and report both directions. |
| Medium | §2.5, S2.1 | Detector precision is scored against glucose-rise labels generated by nearly the same signal (circular); dawn, stress, site failure and post-hypo rebounds all count as "episodes". | Name it a disturbance detector; define live FP by outcome (override active and no sustained rise, or <80 within 2 h); keep the labeller for sensitivity/delay only. |
| Medium | S1.3 replay | Scored on "20 recorded window days" (days the user tapped) and "non-meal days"; untapped meal days — the actual target population — are not a named stratum. | Add "untapped labelled episodes" as the primary sizing stratum. |
| Medium | §4 ABAB | Weekly alternation with A = "previous promoted state" means A drifts across steps; learned libraries (S2.3 v2 clustering) and calibrated budgets carry across arms; detector states (≤6 h) are fine. | Freeze learner/library versions per cycle; record the exact A fingerprint; for S2.3 v2, evaluate only after the library is frozen. |
| Medium | S0.4, §2.5 | Episode labeller thresholds (≥35 mg/dL in 60 min, ≥1.5 mg/dL/min for 15 min) and the 30-episode calibration set are invented; agreement ≥90% is against the same developer's eye. | State them as initial values; have the second reviewer label 15 of the 30 blind. |
| Low | S0.5 | 99.5% identity on `rate/duration/units` ignores `insulinReq`, `eventualBG`, `carbsReq`; a Swift core could match deliveries while diverging on predictions. | Add `insulinReq` ±0.05 U and `eventualBG` ±2 to the differential gate. |
| Low | §2.3 metrics | Missing: time in <54 by night vs day, number of SMBs per episode, insulin delivered in first 60 min after onset (the quantity items 3/4 claim to move), and loop/enactment failure rate. | Add them. |

## Dimension 3 — Technical feasibility

| Severity | Plan section | Finding | Recommended fix |
|---|---|---|---|
| High | S1.4(a) | JS reads `profile.maxDelta_bg_threshold` (`determine-basal.js:1369-1372`), not `preferences`; the per-loop *preference* override cannot change the lockout. | Patch the profile JSON per loop (same place as S2.1's override). |
| High | S0.3 Core Data | Lightweight migration works (`CoreDataStack.swift:44-45`), but downgrade is impossible; `isCalibration: Bool` non-optional needs an explicit default. | See exec summary 5; declare defaults. |
| Medium | S0.2, §0(b) | Inner `determineBasal(glucose:…)` (`OpenAPS.swift:908-955`) has no `clock` parameter; `prepare/autosens.js` has no clock input and `autosens.js:27` reads `new Date()` in the non-retrospective path; `profile/index.js` schedule lookups (`targets.js:11`, `basal.js:10`, `isf.js:11`, `carbs.js:6`) use wall clock when generating a profile. In-silico ticks (S0.7) that regenerate a profile per tick therefore need clock injection in more JS than "five lines". | Thread `clock` through all three Swift sites; pass `retrospective: true` + an explicit `now` to autosens; either generate profiles in Swift for replay or add a `now` argument to `prepare/profile.js`. Record each as a JS edit in §0(a). |
| Medium | §0(b), §2.6 | `JSOrefCore` requires JavaScriptCore → macOS only. GitHub-hosted macOS: 6-hour job cap, 10× minute multiplier, free tier 2,000 min/month ⇒ the 7-hour nightly cannot run there and ~25 min/PR ≈ 250 billed minutes. | Run nightly on the developer's Mac (launchd) or add a Node-based runner of the identical bundle for Linux CI with a parity test against JSC. |
| Medium | §0(b) "one pbxproj edit" | Only two `PBXFileSystemSynchronizedRootGroup`s exist; `Trio/Sources` is not synchronized. Every new app-side file (`DosingTraceStore`, `DosingPipelineAdapter`, `MealWindowStore`, export view, model v2) is a `pbxproj` edit and widens the rebase conflict in `MERGE_NOTES.md` section A. | Budget for it; consider one synchronized group `Trio/Sources/APS/AlgorithmLab/` for all new app-side files. |
| Medium | S0.2 | "`dosingCore` resolved via `APSAssembly`" — `OpenAPS` is constructed directly (`APSManager.swift:155`) with a private `jsWorker` (`OpenAPS.swift:7`); not DI-resolved today. | Inject through `OpenAPS.init`; small but it is a signature change. |
| Medium | S0.5 | Upstream Swift sources were not readable (OSS note Q4); the 15–25-day estimate and `DetermineBasalGenerator`/`autoISFStatus` seam are unverified. | Time-box a 2-day spike reading upstream v1.0.2 before committing effort. |
| Medium | S0.7 | PyReplayBG availability/fitness unverified; simglucose "2026 extension" is a paper, not necessarily a pip release; "50–100 ms per JS tick" and "TIR 55–75% envelope" are unmeasured. | Make S0.7 start with a 1-day feasibility spike and record measured numbers before the gate is fixed. |
| Low | §0(d) | `BuildDetails.plist` stores a 7-char abbreviated SHA (`capture-build-details.sh:25`). | Fingerprint on full SHA from the package; map the short SHA to it. |
| Low | S0.3 | The existing `simulation:` path (`OpenAPS.swift:410-417`, skips `storage.save(iob)` and `processDetermination`) is not a replay seam (reads live Core Data). The plan should say why it is not reused. | One sentence in S0.2. |
| Low | §1 effort | Stage 0 totals ~44 dev-days before any dosing change; the week table assumes full-time. | State the availability assumption; at 50% the Stage 1 live date is month 6, not 3. |

**Is "starve the inputs" safe?** Yes: the fork's JS branches all key on `trio_custom_oref_variables.mealWindowActive/toughMealActive/mealWindowAutoPhantomCOBLevel`, and the substring rescue (`OpenAPS.swift:519-536`) only reads output telemetry fields. Two things to add: `toughMealActive` is also set from `toughMealActivationDate` in Swift (not only via the window), and `MealClassifier` writes `mealWindowPhantomCOB = true` permanently into `TrioSettings` (`MealClassifier.swift:270`), so S0.6's store migration must clear it.

## Dimension 4 — Constraint compliance (no carbs, tags, macros)

| Severity | Plan section | Implicit dependency | Fix |
|---|---|---|---|
| High | S2.1 confounders, §2.5 exclusions | Rescue-carb suppression and labeller exclusions require tagged rescue entries. | Glucose-only post-hypo suppression (90 min after <70 or suspend). |
| High | S0.7 twin, §2.2 (2) | Twin fit needs meal inputs or residual-implied grams computed from the profile ISF/CR (circular). | See Dimension 2. |
| High | S1.1 (3), S1.3, S2.1, S2.2, S2.3 replay gates | Sushi case was announced and bolused. | Replace with unannounced episodes. |
| Medium | S2.5 ISF | "Isolated corrections" are rare under SMBs; CR "per cluster" needs ≥40 labelled episodes and a stable library. | Redesign ISF around SMB trains; state the expected learnable set honestly. |
| Medium | S2.2 | COB>40 g suppression never fires without entries; the only protection on fast-absorbing meals is the velocity clamp and Recovering. | Add a glucose-only "fast absorber" suppression: residual slope >2 mg/dL/min for 15 min ⇒ positive effect clamped to ≤20 mg/dL. |
| Medium | S1.3 replay | Window days (tapped) as the comparison population. | Add untapped stratum (above). |
| Low | §4 | "Sick day" flag and S2.6 age for `220 − age` are one-time or optional inputs. | Acceptable; say so. |
| Low | S2.3 | "When a carb entry exists the core still uses it" — fine, but entries that do exist are often partial; a partial entry changes `mealCOB`, `fractionCarbsLeft` and SMB enablement differently from none. | Treat partial entries as a prior with a confidence weight in the class choice only. |

## Dimension 5 — Completeness vs the strategy report

Top-10 coverage: items 1–10 each have a step. Partial: item 2's "insulin-specific onset timing replacing the 90-minute wait" is implemented only as a reduce-only use (S1.3) — acceptable, state as deferred; item 9's 150% ceiling raise and basal scaling ("set `tddAdjBasal` semantics consistently") are deferred/vague; item 6's bolus debit is missing (above).

Personalization-table gaps (no step, no test, no gate):
- **Weekday × time-bucket excursion priors** — absent. Add to S2.5 as a bounded target/ISF prior or state deferred.
- **Insulin action curve (peak, DIA) fitting** — absent; S1.3 uses the configured peak. Add a shadow estimator in S2.5 or state deferred.
- **Pump-site-age multiplier** — only logged/excluded; the report lists it as learnable. State deferred with the "no outcome evidence" reason.
- **SMB-response / meal-probability GBT (Boost)** — absent; the report ranks it evidence-light. State deferred explicitly.
- **Exercise response "fit to the user's own history"** — S2.6 reuses constants; the learning half is missing.

Report's validation plan: the "30-/60-minute RMSE on GlucoBench-style splits for prediction-model changes" is not applied to S2.2 (which changes the prediction the sizer uses). Add it.

Invented numbers (the plan flags margins as "this plan's choices"; these are the ones with no source in report or notes and should be labelled as initial values to be calibrated in S0.4 replay): TBR/LBGI margins; `verify` 99.9%; differential 99.5%; detector `k 0.3`, `h 12`, `p 0.5/0.7`; `targetDropMgdl 20`, `isfFactor 0.8`, 180-min episode cap; `iobCeilingPercent 90`; budgets 8%/15%/20% TDD; `smbCapPercentTDD 0.03`; 150-min max zero temp (oref uses 120; no 780G source given); `accelThreshold 0.02`, brake `a < −0.05`; HR ≥60% of (220−age), steps ≥1,000/15 min, resting+5 sleep rule, +30 mg/dL exercise target; labeller thresholds; in-silico "TBR<70 reduced ≥30%", "TIR 55–75% envelope"; "25–40 KB/loop", "50–100 ms/tick"; "detection by minute ≤90". Grounded: 3 U absolute cap (iLet), −1 mg/dL/min velocity gate and 140–180 band (zone-MPC), predBG30 <80 (report), 420-min anti-windup (780G 7 h), ~6× FP reduction with HR (3.3→0.5/day), twin RMSE 15–25 (report), 20%/run autotune precedent, STRIVE exchange rate, 0.5 FP/day.

## Dimension 6 — Process

| Severity | Plan section | Finding | Fix |
|---|---|---|---|
| High | §6.2, §5 | No clinician or second-person review before the first add-insulin path (S1.3 live) or before S2.1/S2.5. | Add a named reviewer and a sign-off checkbox before any `reduceOnly → live` transition; the reviewer also blind-labels part of the episode set. |
| High | §5, §1 rollback | No consolidated 3 a.m. runbook. Per-step rollbacks assume a working app and a calm developer. | One page: how to open-loop (`closedLoop` off), suspend pump, remove pod, what the kill switch does and does not do, how to confirm with `trio-replay verify`, where traces/logs are, who to call. Test it once. |
| High | §5 stop conditions | Missing: pipeline exception/crash or loop-failure-rate increase; any `verify` mismatch on a loop where insulin was delivered; any supervisor state file corruption; any unexplained >250 for ≥4 h with IOB rising (under-delivery). | Add four stop conditions. |
| Medium | §0(d), S0.3 exporter, §2.6 | 90-day CGM/insulin history committed as `AlgorithmKit/Fixtures/history/` and traces including the full profile pushed to the `telemetry` branch of `zgoettsc/trio` (`TrioSettings.swift:259-260`). If the repo is public, that publishes health data; "de-identified" removes meal names only. | Verify repo visibility; keep fixtures in a private submodule or an encrypted archive referenced by hash; keep `telemetryIncludeDosingTrace` off and document retention/deletion. |
| Medium | §4 pre-registration | Pre-registration exists but is self-authored and self-judged; "iterate" allows re-shadowing 2 weeks indefinitely. | Cap iterations per step at two; a third requires the reviewer's sign-off or reversion. |
| Medium | §6.1 | Shadow periods "overlap with building the next step": the developer is modifying the app while a live arm runs, which the fingerprint-drift stop condition (#4) will trip constantly. | Define that only the stage under test may change during an arm; any other change ends the arm. |
| Low | §6.2 | "Rollback rehearsed once" cannot be done for Core Data changes (above). | Note the exception and the mitigation. |

---

## Claim-verification table

| Plan claim | Verdict | Evidence |
|---|---|---|
| `prepare/determine-basal.js:5` does `var clock = new Date();` discarding the argument | VERIFIED | Line 5 exactly as stated; `generate` signature at line 3 takes `clock = new Date()`. |
| `OpenAPS.swift:945` passes `Date()` rather than `clock` | VERIFIED, incomplete | Line 945 is `Date()`; the inner function (`:908-920`) has no `clock` parameter and the outer call (`:491-504`) does not pass one. Three sites, not one. |
| `determineBasal(currentTemp:shouldSmoothGlucose:clock:)` at `OpenAPS.swift:413` | VERIFIED (signature starts `:410`, `clock` at `:413`); also takes `simulatedCarbsAmount`, `simulatedBolusAmount`, `simulatedCarbsDate`, `simulation`. |
| `meal()` and `iob()` receive the clock | VERIFIED | `:460-473`; prepare wrappers forward `clock_data`. |
| `unit_tests.yml` named `zzz [DO NOT RUN] Automated unit tests`, gated `repository_owner == 'nightscout'` | VERIFIED | Lines 1, 27. |
| 99 test functions in `TrioTests/`, Swift Testing | WRONG | 123 `@Test` functions across 18 `@Suite` files; one file imports XCTest. `CoreDataStack.createForTests()` and `TestAssembly.swift` exist. |
| `logTelemetryLoopSample` at `APSManager.swift:560-800`, gates only on `telemetryEnabled`; stale comment at `:546` | VERIFIED with wrong lines | Function at `:589`, guard at `:591`; stale "iff a meal window" comment at `:537-539`; the doc comment at `:559-566` already says "CONTINUOUSLY". |
| `AlgorithmTelemetryLoopSample` fields | VERIFIED | `AlgorithmTelemetryEvent.swift:56`; carries `bg, iob, cob, eventualBG, minPredBG, insulinReq, smbDelivered, tempBasalRate, reason, velocity, acceleration`, no inputs. |
| Exports: 2,016 Kalman rows; 20 meal records | VERIFIED | `signals` = 2016; `records` = 20. |
| `MERGE_NOTES.md` content | VERIFIED | Unfinished v0.8.3 sync, `pbxproj` from upstream first. |
| `determine-basal.js` hunks 136-234, 268-298, 868-882, 981-983, 1626-1684, 1736-1822; guards at 534-579, 733-737, 1116-1128, 1369-1380, 1407-1430, 1687-1691 | VERIFIED | All headers match. |
| `Preferences.swift:50` 0.35 vs `profile/index.js:77` 0.65 | VERIFIED; effect cosmetic | JS reads `profile.weightPercentage` only in a `< 1` test and logs (`:300, :390`); the actual weighting is Swift's 0.35. S2.4's "make the JS default read from preferences" is moot. |
| Hook: `determination.timestamp = deliverAt` at `:512`, `processDetermination` at `:538` | WRONG lines | `:517` and `:540`. |
| `enactDetermination` at `APSManager.swift:1682-1716` | VERIFIED | `:1682-1714`; pump-suspended skip at `:1695-1698`. |
| `OpenAPS.swift:478-482` is where `preferences` is mutated for dynamic ISF | VERIFIED (`:478-483`) | But JS reads `profile.maxDelta_bg_threshold`, so this site cannot host S1.4's override. |
| `TrioSettings.swift:83-129, 205-222` meal-window/classifier knobs | VERIFIED | `mealWindowActivationDate` at 83; auto-phantom keys 205-222. |
| `SettingsExportProvider.swift` exists; Constants names; `freeaps/freeaps_settings.json`; `settings/therapy_profiles.json` | VERIFIED | `Constants.swift:29-42, 94, 97`. |
| `AlgorithmTelemetryManager.runRetentionCleanup()` at `:1046` | VERIFIED | Purges local telemetry older than 30 days (`:1048`). |
| `APSManager.reportEnacted` at `:1750+` | VERIFIED approx. | `:1743`. |
| `GlucoseStored` lacks `noise/device/isCalibration/sessionStart`; `OrefDetermination` lacks `minGuardBG/minPredBG` | VERIFIED | Model contents; `OrefDetermination` has `threshold`. `Determination` struct already decodes `minGuardBG/minPredBG/threshold` (`Determination.swift:32-34`). |
| `GlucoseStorage.storeGlucose` writes `noise: nil` (`:450-591`) | VERIFIED | Lines 450, 494, 526, 558, 591. |
| `BloodGlucose` CodingKeys `noise`, `type`, `transmitterID` | VERIFIED | `BloodGlucose.swift:72-77`. |
| `PluginSource.swift:222-241` `NewGlucoseSample`; "Dexcom G6/G7 and xDrip give `noise`" | WRONG for plugins | `:245-252` sets `noise: nil, type: "sgv"` for every plugin; `sessionStartDate` is populated. LoopKit submodule not checked out here, so `NewGlucoseSample`'s fields are UNVERIFIABLE in this tree. |
| `AlgorithmGlucose` at `OpenAPS.swift:172-178`; `glucose-get-last.js:27-32`; `determine-basal.js:534-536` | VERIFIED | |
| `AlgorithmTelemetryGitHubClient` pushes JSONL day dirs to the `telemetry` branch; `telemetryAnonymizeMealNames` | VERIFIED | Default repo `zgoettsc/trio`, default `telemetryEnabled: false`. |
| `OpenAPS.swift:908-955` JS invocation order | VERIFIED | |
| `prepareTrioCustomOrefVariables` at `:591-640` (window logic) | VERIFIED (`:553-690`; window at `:608-633`) | Uses `Date()` at 562, 563, 579, 597, 614, 641. |
| `evaluateAutoPhantomCOB` at `:1346-1430`; `MealClassifier.evaluate()` at `:762` | WRONG lines | `:1370`; `:763`. |
| `AnnounceMealIntentRequest.swift:100` | approx. | `func announce(` at `:99`; window activation at `:108`. |
| `OpenAPS.swift:574-587` weightedAverage | VERIFIED | |
| `TDDStorage.hasSufficientTDD` row-count rule `≥0.75 × 7 × 288` at `:623-636` | VERIFIED | `:618-636`. |
| `BGResidualCalculator.swift:81-141` | UNVERIFIABLE as a range | File is 187 lines; the residual logic exists; exact range not confirmed. |
| `HealthMetricsService.swift:59-64, 82, 293` | VERIFIED | HR/steps types requested and read. |
| `GarminContextSnapshot` fields | VERIFIED | `averageHeartRateInBeatsPerMinute`, `steps`, `vigorousIntensityDurationInSeconds`, sleep fields. |
| `createProfiles` `:730-831`, `autotune: RawJSON.null` at 804/817; `AutotuneConfigStateModel.swift:56` calls non-existent `apsManager.autotune()` | VERIFIED | No `func autotune` in `Trio/Sources`. |
| `signalPipeline.latestOutput` at `APSManager.swift:632`; pipeline call at `:509-522` | VERIFIED (`:632`; `:507-520`) | Fed with `determination.bg` at loop time (see finding). |
| `fetchCurrentTempBasal` `:1643-1668` | VERIFIED | |
| `OpenAPS.swift:160-170` manual readings raw; `:186-196` rescue predicate; `:267-408` orphaned resume | VERIFIED | |
| `scripts/capture-build-details.sh`, `BuildDetails.plist`, `scripts/webpack.config.js` | VERIFIED | Short SHA only. |
| `docs/TOUGH_MEAL_HANDLING.md` sushi 01:49 UTC, minutes 140–350, 0.5–0.6 U vs 1.0–3.2 U | VERIFIED | Also: 80 g entered, 5.65 U bolus, March 2026. |
| `Config.loopInterval` 3 min | VERIFIED | `Config.swift:7`. |
| Kalman config `measurementNoise 36`, `qBase*`, `volatilityScale 0.8` | VERIFIED | `AdaptiveKalmanFilter.swift:19-31`. `FilterOutput` has `accelerationUncertainty`; `OrefSignalOutput` does not (only `bgUncertainty`), so S1.4 needs plumbing. |
| `MacroMealModel` 120/210/360, 180/300/480, carb 0.5 g/min; `AdaptiveLearning.Config.minimumObservations 5` | VERIFIED | |
| `Preferences.insulinPeakTime 75`, `curve .rapidActing` | VERIFIED | |
| `PumpSiteAge.hoursSinceLastRewind()`, `readOmnipodActivation`, `monitor/pod-age.json` written by `DeviceDataManager` | VERIFIED | `DeviceDataManager.swift:542`. |
| `CarbEntryStored.isRescueCarbs`, `predicateForOneDayAgoExcludingRescue` | VERIFIED | |
| `APSAssembly` registers `OrefSignalPipeline`; "`JSOrefCore` resolved via `APSAssembly`" | PARTLY WRONG | `OpenAPS` is not DI-registered; constructed at `APSManager.swift:155`. |
| `JavaScriptWorker.swift` trimmed copy feasible (JavaScriptCore on macOS) | VERIFIED | Imports Foundation + JavaScriptCore; uses app `debug/warning` logging only. |
| `docs/EXPORT_JSON_SPEC.md`, `MEAL_DECISION_EXPORT_SPEC.md`, `PHYSIO_TESTING.md`, `TELEMETRY_ANALYSIS_METHODS.md`; `SavedMealOutcomeCalculator` | VERIFIED | |
| `TempBasalStored` duration "via `PumpEventStored`" | WRONG | `TempBasalStored.duration` is on the entity itself (model `:265`). |
| Core Data lightweight migration viable | VERIFIED | `CoreDataStack.swift:44-45`. Single model version today; downgrade impossible. |
| "The one `pbxproj` edit of the plan" | WRONG | `Trio/Sources` is not a synchronized group. |
| `trio_custom_oref_variables` seam, forcing `mealWindowActive/toughMealActive` false retires the stack | VERIFIED | JS branches at 136-142, 191-234, 868-882, 981-983, 1626-1684, 1736-1822 all key on those variables. |
| Core Data retains >90 days (backfill feasibility) | UNVERIFIABLE | No purge of glucose/pump entities found in `Trio/Sources/APS/Storage` or `CoreDataStack`; only UI date filters at 90 days. Assume yes, confirm on device. |
| Upstream v1.0.2 Swift seam (`DetermineBasalGenerator`, `autoISFStatus`) | UNVERIFIABLE | Not in tree; the plan itself says so. |

---

## What the plan does well (do not break these)

- Making the clock fix and a byte-for-byte `verify` gate the first code change is the right first move; the self-test is strong for the core.
- The `DosingCore` protocol with `JSOrefCore`/`SwiftOrefCore` and the rebase as a measured equivalence test rather than a prerequisite is the correct call given `MERGE_NOTES.md`.
- Retiring the multiplicative stack by starving inputs rather than editing JS is safe and verifiably complete (all six fork hunks key on the custom variables).
- `DosingStageMode` with `off` defaults, per-stage toggles persisted in settings decoded with `try?` + defaults (`TrioSettings.swift:311+`), so a missing key cannot flip a stage on; a settings import leaves new keys at `off`.
- Shadow → reduce-only → reduced parameters → defaults, each held, with named telemetry fields per stage and a standing dashboard.
- The supervisor's property test and trace assertion as the single invariant; the explicit "zero `units`/`rate` increases ever observed" shadow gate.
- Honest framing of the decision-divergence vs twin distinction, and refusing to pool them.
- Pre-registration per step, the explicit confounder list (site age, time zone, new sensor, profile switches), and the risk register with per-step one-toggle rollback.
- The tap/no-tap split for the detector and scoring on the no-tap half.
- The dual-hormone track gated behind a no-code feasibility study with its own stop conditions.
