# V2: Macro Absorption Engine & Garmin Sensitivity Model

**Version:** 2.1
**Date:** February 7, 2026
**Status:** Design complete, implementation not started
**Prerequisite:** V1 Cronometer Integration (Phases 1-5b, implemented)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Why V1 Is Insufficient](#why-v1-is-insufficient)
3. [Research Foundation](#research-foundation)
   - 3.1 [Carbohydrate Absorption Physiology](#31-carbohydrate-absorption-physiology)
   - 3.2 [Fat's Dual Mechanism](#32-fats-dual-mechanism)
   - 3.3 [Protein's Glucagon-Driven Effect](#33-proteins-glucagon-driven-effect)
   - 3.4 [Mixed Meal Dynamics](#34-mixed-meal-dynamics)
   - 3.5 [The Pizza Effect Explained](#35-the-pizza-effect-explained)
   - 3.6 [Warsaw Method / FPU Limitations](#36-warsaw-method--fpu-limitations)
   - 3.7 [Key Research Papers](#37-key-research-papers)
4. [Architecture Overview](#architecture-overview)
   - 4.1 [Three-Layer System](#41-three-layer-system)
   - 4.2 [Data Flow](#42-data-flow)
   - 4.3 [How It Integrates With oref](#43-how-it-integrates-with-oref)
   - 4.4 [Curve-Driven Split Dosing](#44-curve-driven-split-dosing)
   - 4.5 [Meal-Mode SMB Enhancement](#45-meal-mode-smb-enhancement)
5. [Layer 1: Three-Curve Macro Absorption Engine](#layer-1-three-curve-macro-absorption-engine)
   - 5.1 [Curve 1 — Carbohydrate Absorption](#51-curve-1--carbohydrate-absorption)
   - 5.2 [Curve 2 — Protein Gluconeogenesis](#52-curve-2--protein-gluconeogenesis)
   - 5.3 [Curve 3 — Fat Insulin Resistance](#53-curve-3--fat-insulin-resistance)
   - 5.4 [Composite Insulin Need Calculation](#54-composite-insulin-need-calculation)
   - 5.5 [Replacing the FPU Entry Distribution](#55-replacing-the-fpu-entry-distribution)
   - 5.6 [Split Dosing Strategy](#56-split-dosing-strategy)
   - 5.7 [Sensitivity-Adjusted Entries](#57-sensitivity-adjusted-entries)
6. [Layer 2: BG-Adaptive Real-Time Correction](#layer-2-bg-adaptive-real-time-correction)
   - 6.1 [Predicted vs Actual BG Comparison](#61-predicted-vs-actual-bg-comparison)
   - 6.2 [Curve Adjustment Algorithm](#62-curve-adjustment-algorithm)
   - 6.3 [Integration With the Loop Cycle](#63-integration-with-the-loop-cycle)
   - 6.4 [Meal-Mode SMB Enhancement](#64-meal-mode-smb-enhancement)
   - 6.5 [Safety Constraints](#65-safety-constraints)
7. [Layer 3: Garmin Sensitivity Model](#layer-3-garmin-sensitivity-model)
   - 7.1 [Firestore Database Structure](#71-firestore-database-structure)
   - 7.2 [GarminContextSnapshot](#72-garmincontextsnapshot)
   - 7.3 [Sensitivity Factor Calculation](#73-sensitivity-factor-calculation)
   - 7.4 [How Each Metric Affects Insulin Sensitivity](#74-how-each-metric-affects-insulin-sensitivity)
   - 7.5 [Rule-Based Model (V1)](#75-rule-based-model-v1)
   - 7.6 [ML Model (V2, Future)](#76-ml-model-v2-future)
   - 7.7 [Claude Periodic Recalibration](#77-claude-periodic-recalibration)
8. [Macros On Board (MOB) Tracking System](#macros-on-board-mob-tracking-system)
   - 8.1 [Observer-Driven Automatic Detection](#81-observer-driven-automatic-detection)
   - 8.2 [MOB State Machine](#82-mob-state-machine)
   - 8.3 [Recommendation Trigger Logic](#83-recommendation-trigger-logic)
   - 8.4 [In-App Recommendation Banner](#84-in-app-recommendation-banner)
   - 8.5 [Double-Dose Protection](#85-double-dose-protection)
   - 8.6 [User Controls: Upfront Bolus Slider](#86-user-controls-upfront-bolus-slider)
9. [Outcome Learning & Calibration](#outcome-learning--calibration)
   - 9.1 [Per-Meal Curve Parameter Learning](#91-per-meal-curve-parameter-learning)
   - 9.2 [Garmin Weight Calibration](#92-garmin-weight-calibration)
   - 9.3 [ICR-Tagged Outcome Filtering](#93-icr-tagged-outcome-filtering)
10. [Implementation Plan](#implementation-plan)
    - 10.1 [Phase A: Three-Curve Absorption Engine](#101-phase-a-three-curve-absorption-engine)
    - 10.2 [Phase B: BG-Adaptive Loop Integration + Meal-Mode SMBs](#102-phase-b-bg-adaptive-loop-integration--meal-mode-smbs)
    - 10.3 [Phase C: Garmin Firestore Integration](#103-phase-c-garmin-firestore-integration)
    - 10.4 [Phase D: Sensitivity Model](#104-phase-d-sensitivity-model)
    - 10.5 [Phase E: MOB Tracking & Auto-Recommendation](#105-phase-e-mob-tracking--auto-recommendation)
    - 10.6 [Phase F: Outcome Learning & Calibration](#106-phase-f-outcome-learning--calibration)
    - 10.7 [Phase G: Claude Recalibration Service](#107-phase-g-claude-recalibration-service)
11. [File Reference](#file-reference)
12. [Key Technical Decisions](#key-technical-decisions)
13. [Safety Philosophy](#safety-philosophy)
14. [Relationship to V1](#relationship-to-v1)

---

## Executive Summary

V1 of the Cronometer integration (documented in `CRONOMETER_INTEGRATION_AND_AUTO_DOSING_VISION.md`) built the foundation: reading Cronometer meals from Apple Health via snapshot deltas, recommending doses with personal adjustment factors, tracking outcomes, and learning from them.

V2 replaces the core absorption model with something physiologically accurate, adds real-time BG-adaptive correction, integrates Garmin health data for daily sensitivity adjustment, and introduces **curve-driven split dosing** to eliminate the mixed-meal hypoglycemia problem.

**The three layers:**

| Layer | What It Does | When It Runs |
|-------|-------------|--------------|
| **Garmin Sensitivity** | Adjusts baseline ISF/CR based on sleep, stress, activity | Pre-meal (once per meal detection) |
| **Three-Curve Absorption** | Models carbs, protein gluconeogenesis, and fat insulin resistance as separate curves; distributes ALL entries along physiological curves with split dosing | At meal time (generates all carb entries) |
| **BG-Adaptive Correction** | Compares predicted vs actual BG, adjusts remaining entries, enables meal-mode SMB enhancement | Every loop cycle (5 minutes) |

**Key design principles:**

1. **Curve-driven split dosing:** The gamma absorption curve determines the safe upfront bolus amount. Only carbs expected to absorb in the near term are bolused immediately; remaining carbs become curve-shaped future entries that oref covers via SMBs as absorption actually occurs.

2. **Meal-mode SMB enhancement:** During active meal absorption, the maxSMB ceiling is temporarily raised (configurable multiplier, default 2.0x) with strict safety gates, so SMBs can keep pace with the curve-predicted absorption.

3. **Sensitivity-adjusted entries:** The Garmin sensitivity factor scales ALL entry amounts (carbs + fat + protein). COB displays "insulin-equivalent carbs" with a UI annotation showing both eaten and effective amounts.

4. **Zero double-dosing:** Every meal entry is tagged with a unique mealID. The system tracks dosing state per meal and warns the user if they attempt to dose the same meal twice. Entries are never duplicated.

**The goal:** Replace manual carb entry with automatic, Cronometer-driven, physiologically-accurate insulin delivery that adapts in real-time to what the CGM actually sees — and accounts for the user's daily condition via Garmin data. Deliver insulin safely by splitting doses so that insulin and carb absorption are temporally aligned.

---

## Why V1 Is Insufficient

### The Current FPU Model Is Wrong

The V1 system (and Trio's built-in FPU system) uses the Warsaw Method to convert fat and protein to "carb equivalents":

```
Current implementation (CarbsStorage.swift, lines 143-205):
  kcal = protein x 4 + fat x 9
  carbEquivalents = (kcal / 10) x individualAdjustmentFactor
  -> Split into equal-sized entries every N minutes
  -> Starting after a fixed 60-minute delay
  -> Duration: <2 FPU->3h, 2-3->4h, 3-4->5h, >=4->8h
```

**Problems:**

1. **Fixed 60-minute delay is wrong.** Fat's gastric emptying delay is dose-dependent and continuous. 10g fat delays differently than 40g fat. The delay isn't binary (off then on) — it's a gradual reshaping of the absorption curve.

2. **Linear distribution is wrong.** Equal-sized carb entries create a flat rectangle of absorption. Real absorption follows a gamma-distribution curve (gradual rise -> peak -> exponential tail).

3. **"Carb equivalents" can't model insulin resistance.** Fat's primary late effect (2-6h) is making insulin LESS EFFECTIVE, not adding glucose. This is a multiplier on insulin needs, not an additive term. You can't represent a sensitivity change as future carbs.

4. **Protein's mechanism is completely different from carbs.** Protein -> glucagon -> gluconeogenesis creates glucose through a different pathway with a different time course (onset ~100min, peak ~300min). Treating it as delayed carb absorption misses the physiology.

5. **No adaptation to reality.** Once the FPU entries are created, they're fixed. If the BG trajectory doesn't match the prediction, the entries don't adjust.

6. **No sensitivity context.** The same meal gets the same treatment whether the user slept 4 hours or 8 hours, whether they ran 10km or sat at a desk all day.

### The Mixed-Meal Hypoglycemia Problem

The current system has a dangerous failure mode for high-fat mixed meals:

**The problem:** When carbs are eaten with fat and protein, fat slows gastric emptying and delays carb absorption significantly. But the current system boluses for the full carb amount upfront. The insulin acts well before the carbs absorb, causing a low BG window before the carbs take effect.

**Example — 2 slices of pizza (65g carbs, 28g fat):**

| Time Window | What Insulin Is Doing | What Carbs Are Doing |
|-------------|----------------------|---------------------|
| 0-30 min | Rapid insulin peaking | Fat-delayed carbs barely absorbing (~15% absorbed) |
| 30-90 min | Insulin at full effect | Carbs slowly absorbing (~36% absorbed at 60 min) |
| 90-180 min | Insulin waning | Remaining ~45g still absorbing |
| 180-480 min | Insulin expired | Fat resistance + protein gluconeogenesis + remaining carbs |

With a full 6.5U bolus upfront (65g / CR 10), the insulin-carb mismatch at 30-90 min creates a dangerous hypoglycemia window. Then when the remaining carbs + fat resistance + protein arrive at 3-8h, there's no insulin left — causing the "pizza effect" rebound high.

**Quantified fat-dependent absorption delay:**

| Fat Content | Carbs absorbed by 60 min | Carbs still absorbing |
|-------------|-------------------------|----------------------|
| No fat (tau=35) | ~56% (36g of 65g) | 29g |
| 15g fat (tau=47) | ~44% (29g) | 36g |
| 28g fat (tau=57) | ~36% (23g) | 42g |
| 50g fat (tau=75) | ~27% (18g) | 47g |

**V2's solution:** The gamma absorption curve tells us exactly how much to front-load. The engine calculates how much absorption is expected in the "safe window" (configurable, default 45 min) where insulin and carb absorption overlap, boluses only for that amount, and distributes the rest as future entries along the curve. oref delivers SMBs for the remaining carbs as they actually absorb, guided by the BG-adaptive layer.

### What oref Sees

Critical architectural fact: **oref has no concept of FPUs.** The FPU system is entirely a front-end carb distribution mechanism in `CarbsStorage.swift`. oref receives all entries (FPU and regular) as simple carb entries and applies its deviation-based COB model identically to both.

From `trio-oref/lib/meal/total.js` (lines 64-77):
```javascript
if (treatment.carbs >= 1) {
    carbs += parseFloat(treatment.carbs);
    // ... only carbs and timestamp are used
    // isFPU flag is completely ignored
}
```

From `trio-oref/lib/determine-basal/cob.js` (lines 184-189):
```javascript
var ci = Math.max(deviation, currentDeviation/2, profile.min_5m_carbimpact);
var absorbed = ci * profile.carb_ratio / sens;
carbsAbsorbed += absorbed;
```

This means we can improve the front-end distribution without touching oref's algorithm — oref will handle whatever carb entries we give it, and its deviation-based model provides a self-correcting safety net.

---

## Research Foundation

### 3.1 Carbohydrate Absorption Physiology

#### Glucose Rate of Appearance

Carbohydrate absorption follows a gamma-distribution-like curve, NOT a step function or exponential decay. Tracer studies using stable isotope dilution reveal distinct profiles by carb type.

**Time to key absorption milestones (from tracer studies, Diabetologia 2013):**

| Carb Type | 25% Absorbed | 50% Absorbed | 75% Absorbed | Peak Rate |
|-----------|-------------|-------------|-------------|-----------|
| High-GI (glucose, white bread) | ~56 min | ~100 min | ~153 min | 30-45 min |
| Low-GI (whole grains, legumes) | ~88 min | ~175 min | ~270 min | 60-120 min |

**Peak glucose impact times:**

| Carbohydrate Type | Peak BG Impact | Duration of Effect |
|-------------------|---------------|-------------------|
| Simple sugar (glucose, sucrose) | 30-45 min | ~2 hours |
| High-GI starch (white bread, rice) | 45-60 min | ~2-3 hours |
| Low-GI starch (whole grains) | 60-90 min | ~3-4 hours |
| High-fiber / legumes | ~120 min | 4+ hours |

#### Gastric Emptying: The Rate-Limiting Step

Gastric emptying is the primary determinant of glucose appearance rate:

- **Liquids** empty exponentially: `V(t) = V_0 x e^(-kt)`
- **Solids** empty biphasically: an initial lag phase (grinding/trituration) then approximately linear emptying
- The stomach regulates caloric delivery to the duodenum at roughly **2-3 kcal/min** for mixed meals
- Higher caloric density -> proportionally greater delay
- Best mathematical fit: **modified power exponential** `y = 100 x [1 - (1 - e^(-kt))^b]` where `b` captures the lag phase

#### The Dalla Man / UVA-Padova Gut Model (FDA-Accepted)

The gold-standard mathematical model (Dalla Man, Rizza, Cobelli, 2007) uses a 3-compartment structure:

```
Compartment 1: Q_sto1(t) -- solid phase stomach
Compartment 2: Q_sto2(t) -- liquid/triturated stomach
Compartment 3: Q_gut(t)  -- intestinal glucose

dQ_sto1/dt = -k_gri x Q_sto1 + D x delta(t)
dQ_sto2/dt = -k_empt(Q_sto) x Q_sto2 + k_gri x Q_sto1
dQ_gut/dt  = -k_abs x Q_gut + k_empt(Q_sto) x Q_sto2
Ra(t)      = (f x k_abs x Q_gut) / BW
```

Where:
- `k_gri` = grinding rate constant (solid -> liquid transition)
- `k_empt(Q_sto)` = **nonlinear** gastric emptying rate, varying between `k_min` and `k_max`
- `k_abs` = intestinal absorption rate constant
- `f` = bioavailability (~0.9 for mixed meals)
- `BW` = body weight

**Critical insight:** `k_empt` is nonlinear — it transitions between `k_min` and `k_max` via a piecewise/tanh function. Initially fast, then slows, then speeds up as stomach empties. This is what creates the gamma-like appearance curve.

#### The Hovorka Model (Simpler Alternative)

The Hovorka model (2004) uses a 2-compartment chain with identical transfer rates:

```
dD1/dt = -D1/tau_D + d(t) x A_G
dD2/dt = (D1 - D2) / tau_D
U_G    = D2 / (tau_D x V_G)
```

This produces a **gamma(2, tau)** curve — a smooth rise to peak followed by exponential tail. Simpler, widely used in control algorithms, but lacks the nonlinear gastric emptying dynamics.

**For our implementation:** We use the Hovorka-style gamma(2, tau) as the base carb curve. It's simpler to compute, well-validated, and the BG-adaptive layer corrects for any inaccuracy.

---

### 3.2 Fat's Dual Mechanism

Fat affects blood glucose through **two distinct, temporally separated mechanisms:**

#### Mechanism 1: Gastric Emptying Delay (0-3h)

Fat in the duodenum triggers release of **CCK (cholecystokinin)** and **GLP-1**, which slow gastric emptying via the enterogastric inhibitory reflex.

**Key characteristics:**
- Dose-dependent: more fat = more delay (continuous, not binary)
- NOT a simple time shift — it **reshapes** the carb absorption curve:
  - Reduces the initial peak amplitude (0-90 min)
  - Flattens and extends the curve over longer duration
  - The same total glucose appears, but spread over a wider window
- The stomach regulates caloric delivery at ~2-3 kcal/min; since fat is 9 kcal/g vs 4 kcal/g for carbs, fat-containing meals take proportionally longer

**Quantified delay from research:**
- Low fat (~9g): minimal delay
- Moderate fat (~27g): significantly slower emptying (p < 0.0001 vs water)
- High fat (~35g): peak glucose shifted ~60-90 min later, amplitude reduced ~30%

**Smart et al. (2013) findings:** The high-fat meal initially REDUCED glycemic excursion for up to 90 minutes (slower gastric emptying), but then produced significantly HIGHER glucose from 210 minutes onward.

#### Mechanism 2: FFA-Induced Insulin Resistance (2-8h)

This is the mechanism the FPU model cannot capture. Dietary fat is digested into free fatty acids (FFAs), which impair insulin signaling at the cellular level.

**The biochemical pathway:**
1. Dietary fat -> digestion -> FFAs enter bloodstream
2. Elevated FFAs -> intracellular accumulation of diacylglycerol (DAG) in muscle and liver
3. DAG activates protein kinase C (PKC-beta2 and PKC-delta)
4. PKC impairs insulin signaling -> reduced GLUT4 translocation
5. Result: glucose transport into cells is impaired -> insulin works LESS EFFECTIVELY
6. This is NOT the classical Randle cycle — it is an upstream signaling defect

**Time course (from Hoeg et al. 2010, graded intralipid infusions):**

| Time After Fat Ingestion | Insulin Resistance Effect |
|--------------------------|--------------------------|
| 0-120 min | No significant insulin resistance |
| ~120 min | Insulin resistance first becomes apparent |
| ~270 min | Insulin resistance becomes statistically significant |
| ~360 min (6h) | **Peak insulin resistance** |
| ~210 min after FFA normalization | Resistance resolves |

**Does fat itself raise blood glucose?** Yes, through multiple pathways:
1. **Glycerol backbone:** Triglycerides hydrolyzed -> glycerol (gluconeogenic substrate) + FFAs
2. **FFA-induced hepatic glucose output:** FFAs increase hepatic gluconeogenesis and impair hepatic insulin sensitivity -> increased endogenous glucose production
3. **FFA-induced peripheral resistance:** Reduced glucose disposal in muscle

**Wolpert et al. (2013) quantified this:**
- High-fat dinner required **12.6 units** vs **9.0 units** for low-fat dinner (identical carbs)
- That is **40% more insulin** on average
- Despite additional insulin, high-fat dinner still caused more hyperglycemia
- AUC >120 mg/dL: **16,967 vs 8,350 mg*dL^-1*min** (P < 0.001)
- Effective carb-to-insulin ratio shifted from 13 g/unit to 9 g/unit
- **Marked interindividual differences** — range 17% to 124% additional insulin

---

### 3.3 Protein's Glucagon-Driven Effect

#### The Glucagon-Insulin Paradox in Type 1 Diabetes

In **healthy individuals**, protein stimulates BOTH insulin and glucagon:
- ~6-fold increase in insulin above basal
- ~8-fold increase in glucagon above basal
- Both glucose disposal AND endogenous glucose production increase by ~25%
- Net effect: euglycemia maintained (the effects cancel out)

In **Type 1 Diabetes**, the insulin response is absent. This creates **unopposed glucagon:**
- Glucagon stimulates hepatic glycogenolysis (rapid onset, wanes 1-3h)
- Glucagon progressively stimulates gluconeogenesis (increases over 3h+, reaches 3x basal rate)
- Without compensatory insulin -> net hyperglycemia

The glucagon response to amino acids remains intact in T1D despite blunted responses to other stimuli.

#### Time Course

| Time Post-Meal | Effect |
|----------------|--------|
| 0-100 min | No significant BG rise from protein |
| ~100 min | BG begins to rise (gluconeogenesis starting) |
| 180 min (3h) | Rise becomes statistically significant vs carb-only meals |
| 210-300 min (3.5-5h) | **Peak glucose excursion** from protein |
| 5+ hours | Effect continues beyond typical measurement windows |

#### Dose-Response

- **< 28g protein** added to a mixed meal: minimal additional glycemic impact
- **>= 28g protein** added to a mixed meal: significant, sustained postprandial hyperglycemia from 2-3h onward, continuing beyond 5h
- **>= 75g protein alone** (no carbs): required to see significant BG rise in isolation
- **40g protein** added to 30g carbs: increased glycemia by **2.4 mmol/L at 5 hours** (Smart 2013)

#### Glucagon's Biphasic Glucose Production (Cherrington et al. 1981)

Glucagon's effects on glucose production have distinct temporal phases:
- **Initial response:** 180% increase in glucose production, primarily from glycogenolysis
- **After 3 hours:** Production increase declines to 41% above basal (glycogenolysis wanes)
- **Gluconeogenesis:** Increases progressively throughout, reaching **3x basal rate**
- **Net result:** Initial glycogenolytic spike fades, but sustained gluconeogenic drive persists

This means protein creates a **slow-onset, long-duration glucose source** — completely different from the rapid spike of carbohydrate absorption.

---

### 3.4 Mixed Meal Dynamics

When carbs, fat, and protein are consumed together, their effects are **additive but temporally offset**, creating a composite response:

#### Phase 1: Carbohydrate-Dominant (0-90 min)
- Rapid glucose appearance from carbohydrate absorption
- Fat may initially REDUCE this phase by slowing gastric emptying
- Standard insulin bolus covers this phase
- Protein has no effect yet

#### Phase 2: Transition (90-180 min)
- Carbohydrate absorption continues (especially complex carbs)
- Protein's glucagon effect begins to appear (~100 min onset)
- Fat is slowing remaining carb absorption
- Insulin from standard bolus is waning

#### Phase 3: Fat/Protein-Dominant (180-300+ min)
- Protein-stimulated gluconeogenesis in full effect
- FFA-induced insulin resistance reaches significance
- Remaining carbs still absorbing slowly (fat-delayed)
- Standard bolus insulin has largely expired
- **This is where the "late hyperglycemia" occurs**

#### Quantified Additive Effects (Smart et al. 2013)

Using 30g carb as baseline with identical insulin doses:

| Meal Composition | Additional Glucose Excursion at 5h |
|------------------|------------------------------------|
| 30g CHO + 4g fat + 5g protein (baseline) | +0.5 mmol/L |
| 30g CHO + 4g fat + **40g protein** | +2.4 mmol/L |
| 30g CHO + **35g fat** + 5g protein | +1.8 mmol/L |
| 30g CHO + **35g fat** + **40g protein** | **+5.4 mmol/L** |

The combined high-fat/high-protein meal produced excursions **greater than the sum of individual effects** — indicating synergistic as well as additive interactions.

---

### 3.5 The Pizza Effect Explained

Pizza (and similar high-fat/high-carb meals) produces a characteristic **biphasic glucose response:**

```
BG
 |           /\         /----------------\
 |          /  \       /                  \
 |   /--\  /    \     /                    \
 |  /    \/      \   /                      \
 | /               \/                         \
 |/                                             \
 +---+---+---+---+---+---+---+---+----> Hours
     1   2   3   4   5   6   7   8

     Phase 1    Phase 2       Phase 3
     Modest     Dip/stable    SUSTAINED HIGH
     rise       (false        (the pizza effect)
     (blunted)  security)
```

**Phase 1 (0-90 min):** Pizza crust (refined carbs) absorbs, but high fat (cheese, meat) slows gastric emptying -> blunted initial spike. Standard bolus is well-matched.

**Phase 2 (90-180 min):** Bolus insulin at peak activity. Gastric emptying slowed by fat. BG may dip or remain stable -> **false sense of adequate coverage**.

**Phase 3 (180-480+ min):** Bolus insulin expired. Remaining carbs STILL absorbing. Protein gluconeogenesis in full effect. FFA insulin resistance at peak. -> **Sustained, difficult-to-correct hyperglycemia lasting 4-8+ hours.**

---

### 3.6 Warsaw Method / FPU Limitations

#### What the Warsaw Method Assumes
1. 1 FPU = 100 kcal from fat+protein ~ 10g carbohydrate equivalent
2. Fixed 60-minute delay before absorption starts
3. Linear absorption after the delay
4. Duration: step function (1 FPU=3h, 2=4h, 3=5h, 4+=8h)
5. Individual adjustment factor applied uniformly

#### Where It Fails

| Assumption | Reality |
|-----------|---------|
| Fixed 60-min delay | Delay is dose-dependent, continuous (10g fat != 40g fat) |
| Linear absorption | Real absorption follows gamma-distribution curves |
| Single "carb equivalent" number | Three different mechanisms with different time courses |
| Fat = delayed carbs | Fat's main effect (2-6h) is insulin resistance, not glucose addition |
| Protein = delayed carbs | Protein's effect is glucagon-driven gluconeogenesis, different pathway entirely |
| Duration step function | Continuous dose-response, not discrete tiers |
| Single adjustment factor | Individual variation: 17-124% (Wolpert 2013) |

#### Clinical Evidence

A randomized crossover trial (PMC10580506) found the FPU algorithm:
- **Decreased late postprandial mean glucose** (p = 0.026) for high-fat/protein meals
- But did NOT improve overall HbA1c or time-in-range
- **Increased early postprandial hypoglycemia** for high-fat/high-carb meals
- **Increased hypoglycemia for normal-protein meals** (~33% rate for <1 FPU)

**Conclusion:** FPU is better than ignoring fat/protein entirely, but it is a crude approximation. It over-doses for small meals, under-doses for large fatty meals, and can't capture the insulin resistance mechanism at all.

---

### 3.7 Key Research Papers

#### Foundational Studies

| Paper | Key Finding |
|-------|------------|
| **Wolpert et al. 2013** (Diabetes Care 36:810) | High-fat dinner required 40% more insulin; AUC>120 doubled; range 17-124% individual variation |
| **Smart et al. 2013** (Diabetes Care 36:3897) | Fat and protein effects are additive; combined HF/HP = +5.4 mmol/L at 5h; protein onset at 180min, fat at 210min |
| **Bell et al. 2015** (Diabetes Care 38:1008) | Systematic review: all 7 fat studies and 7 protein studies showed postprandial effects; recommended 30-35% more insulin for >=40g fat |
| **Bell et al. 2016** (Diabetes Care 39:1631) | HFHP meals required 65% more insulin; optimal delivery: dual-wave 30/70 split over 2.4h |
| **Bao et al. 2011** (Diabetes Care 34:2146) | Food Insulin Index algorithm reduced glucose AUC by 52%, peak excursion by 41% |
| **Cherrington et al. 1981** (Diabetes 30:180) | Glucagon's biphasic effect: initial glycogenolysis (180% increase) -> sustained gluconeogenesis (3x basal) |
| **Hoeg et al. 2010** (J Clin Endocrinol Metab) | FFA-induced insulin resistance: onset ~120min, peak ~360min, resolution ~210min after FFA normalization |
| **Dalla Man et al. 2007** (IEEE Trans Biomed Eng 54:10) | FDA-accepted UVA/Padova model with nonlinear gastric emptying; 3-compartment gut |
| **Hovorka et al. 2004** (Physiol Meas 25:905) | 2-compartment gut model with gamma(2,tau) absorption curve; widely used in closed-loop systems |

#### Recent Studies (2020-2026)

| Paper | Key Finding |
|-------|------------|
| **Keating et al. 2021** (J Clin Endocrinol Metab) | Additional insulin required in BOTH early and late postprandial periods for high-fat/protein |
| **Marigliano et al. 2023** (Acta Diabetol) | Proposed second bolus (30% for HF, 60% for HP) at 3h post-meal for adolescents on pumps |
| **Jafar et al. 2024** (Nature Communications) | Reinforcement learning for personalized fat-meal dosing; improved AUC from 378 to 38 mmol/L/min |
| **Krebs et al. 2024** (RCT) | Protein-based bolus did NOT improve TIR in well-controlled carb-restricted T1D |
| **Diabetes Care March 2025** (48:509) | Comprehensive review confirming unopposed glucagon in T1D; absent endogenous insulin response to protein |

---

## Architecture Overview

### 4.1 Three-Layer System

```
+-------------------------------------------------------------+
|                    LAYER 3: BG-ADAPTIVE                      |
|         Compares predicted vs actual BG every 5 min          |
|         Adjusts remaining carb entries in real-time          |
|         Enables meal-mode SMB enhancement                    |
|                                                              |
|  +--------------------------------------------------------+  |
|  |              LAYER 2: THREE-CURVE ENGINE                |  |
|  |    Carb absorption + protein gluconeogenesis +          |  |
|  |    fat insulin resistance -> shaped carb entries         |  |
|  |    Curve-driven split dosing for all entries            |  |
|  |                                                         |  |
|  |  +---------------------------------------------------+  |  |
|  |  |         LAYER 1: GARMIN SENSITIVITY               |  |  |
|  |  |   Sleep + stress + activity -> sensitivity factor   |  |  |
|  |  |   Scales ALL entry amounts before generation       |  |  |
|  |  +---------------------------------------------------+  |  |
|  +--------------------------------------------------------+  |
+-------------------------------------------------------------+

Execution order:
  1. Garmin -> sensitivityFactor (pre-meal, once)
  2. Three curves -> ALL entries with split dosing (at meal time, once)
  3. BG-adaptive -> entry adjustments + meal-mode SMBs (every 5 min, ongoing)
```

### 4.2 Data Flow

```
Cronometer App
  -> Apple Health (cumulative daily totals)
    -> HKObserverQuery fires in Trio (auto-started at app launch)
      -> NutritionSnapshotStore: new snapshot -> delta = meal detected
        -> MacroAbsorptionEngine activates:

          Step 1: Query Garmin context from Firestore
            -> GarminContextSnapshot (sleep, stress, Body Battery, activity, HRV)
            -> sensitivityFactor = 0.82 (e.g., bad sleep + high stress)

          Step 2: Generate three-curve entry distribution with split dosing
            -> Curve 1: Carbs (gamma curve, tau stretched by fat content)
               -> Calculate safe upfront amount from curve's absorption window
               -> Remaining carbs become future entries along the curve
            -> Curve 2: Protein (slow sigmoid, smooth ramp 15-40g)
            -> Curve 3: Fat resistance (normalized Gaussian, 0.69 total coeff)
            -> Sensitivity factor scales ALL entry amounts
            -> All entries -> CarbEntryStored records tagged with mealID
            -> oref sees: shaped future carb entries (not flat/linear)

          Step 3: Show recommendation to user
            -> "Detected 65g carbs, 28g fat, 22g protein from Cronometer"
            -> "Sleep-adjusted: need 22% more insulin today"
            -> "Upfront: 2.3U for 18g (curve-suggested) | Remaining: 60g via SMBs"
            -> [Dose] [Adjust (slider)] [Skip]
            -> Carbs logged automatically - do NOT also enter manually
            -> User confirms -> bolus enacted + entries stored

          Step 4: Ongoing BG-adaptive loop (every 5 minutes, BEFORE oref)
            -> Predicted BG from our curves vs actual CGM reading
            -> If actual > predicted: increase remaining entries
            -> If actual < predicted: decrease remaining entries
            -> Enable meal-mode SMB enhancement (raised maxSMB ceiling)
            -> Modified entries fed to oref -> adjusted SMB delivery

          Step 5: Outcome tracking (2-10 hours later)
            -> Compare actual BG trajectory to original prediction
            -> Learn: curve parameters, sensitivity weights, individual factors
            -> Feed to Claude weekly for meta-analysis
```

### 4.3 How It Integrates With oref

**We do NOT modify oref's algorithm.** We improve the INPUTS.

oref's deviation-based COB model already provides a self-correcting safety net:
- It compares actual BG change to expected BGI (from insulin)
- The difference is attributed to carb absorption
- Floor: `min_5m_carbimpact` = 8 mg/dL per 5 min
- It doesn't care WHERE the carb entries came from or whether they're "real" carbs or FPU entries

What we change:
1. **All entries distributed along physiological curves** — carbs on a gamma curve, protein on a sigmoid, fat resistance on a Gaussian — replacing both the single carb lump and the flat FPU distribution
2. **Split dosing** — only the near-term portion of the carb curve becomes the upfront bolus; remaining absorption is covered by SMBs as carbs actually absorb
3. **Meal-mode SMB enhancement** — temporarily raised maxSMB during active meal absorption so SMBs can keep pace with curve-predicted absorption
4. **Real-time entry modification** via the BG-adaptive layer
5. **Sensitivity-adjusted amounts** from Garmin data

oref sees carb entries with better timing and amounts -> makes better SMB decisions -> better BG outcomes.

### 4.4 Curve-Driven Split Dosing

The gamma absorption curve tells us exactly how much carbohydrate the body will absorb in any given time window. We use this to split the dose:

```
At meal detection:
  1. Compute the fat-modified gamma curve for carbs
  2. Calculate absorption expected in the "safe window" (configurable, default 45 min)
     -> This is the integral of the gamma curve from 0 to safeWindow
  3. That fraction of carbs becomes the upfront bolus amount
  4. The remaining carbs become future entries along the curve
  5. oref sees future entries as COB -> delivers SMBs as carbs absorb
  6. BG-adaptive layer adjusts if reality diverges from prediction
```

**Example — pizza (65g carbs, 28g fat, 22g protein):**

```
Gamma curve: tau = 57 min (fat-delayed from base tau=35)
First 45 min of curve: ~28% of carbs = 18g
Remaining 72% = 47g distributed as future entries

Recommendation: "Bolus for 18g now (1.8U at CR 10)"
Future entries: 47g distributed along gamma curve from +45min to +5h
Fat resistance entries: normalized gaussian peaking at 6h
Protein entries: sigmoid from 1.5h to 7h

As BG rises confirming absorption -> oref sees COB -> delivers SMBs
If BG rises faster than predicted -> adaptive layer increases entries -> more SMBs
If BG doesn't rise as expected -> adaptive layer decreases entries -> fewer SMBs
```

**Compare to current approach:** Full 6.5U upfront -> possible hypo at 30-60 min -> then rebound high at 3-6h when the rest of the carbs arrive and insulin has worn off.

**The safety win:**
- Initial dose is conservative — only covers what the model expects to absorb in the near term
- SMBs are demand-driven — they only fire when oref sees COB that needs covering, gated by actual BG trends
- oref's safety limits apply — maxIOB, maxSMB caps prevent runaway delivery
- BG-adaptive correction — if the model is wrong, corrections happen every 5 minutes
- No insulin delivered for carbs that haven't arrived yet — the fundamental fix for the fat-meal hypo problem

**User control:** A slider allows the user to override the curve-suggested split. Range is 0-100% upfront (default = curve-calculated percentage). A cautious user can decrease it; a user eating a low-fat meal who trusts their count can slide to 100%.

### 4.5 Meal-Mode SMB Enhancement

**The problem:** If the upfront bolus only covers 28% of carbs, the remaining 72% must be delivered via SMBs. But if maxSMB is 1.5U and oref runs every 5 minutes, that's 18U/hour max throughput. For large meals, this might not keep pace with absorption.

**The solution:** When the engine has active meal entries being absorbed, temporarily raise the SMB ceiling:

```
Normal mode:     maxSMB = user's configured value (e.g., 1.5U)
Meal-active mode: maxSMB = user's value x mealSMBMultiplier (e.g., 1.5 x 2.0 = 3.0U)
```

**Safety gates (ALL must be true to enable enhanced SMBs):**

| Gate | Condition | Why |
|------|-----------|-----|
| Active meal | MacroAbsorptionEngine has unexpired entries | Only during known meal absorption |
| BG floor | Current BG > configurable threshold (default 90 mg/dL) | Never push more insulin when already low |
| BG trend | Trend is flat or rising | Don't enhance delivery into a falling BG |
| CGM fresh | CGM data < 10 min old | No enhanced delivery on stale data |
| IOB ceiling | maxIOB still enforced by oref | Ultimate safety cap unchanged |
| Time window | Within the active absorption window of the curve | Disables after meal is fully absorbed |

If **any** gate fails, maxSMB reverts to the normal configured value instantly. No gradual ramp-down — snap back to safe mode.

**User controls:**
- **Upfront % slider:** "How much to bolus immediately" (0-100%, default = curve-calculated)
- **Meal SMB multiplier:** "How aggressive should follow-up SMBs be" (1.0x-3.0x, default 2.0x)

A cautious user might set 60% upfront + 1.5x SMBs. An aggressive user might set 20% upfront + 3.0x SMBs. The curve-suggested default sits in between.

---

## Layer 1: Three-Curve Macro Absorption Engine

### 5.1 Curve 1 — Carbohydrate Absorption

#### Model: Gamma(2, tau_carb) Distribution

We use the Hovorka-style two-compartment gut model, which produces a gamma(2, tau) glucose appearance curve:

```
Ra_carb(t) = (C x t / tau^2) x exp(-t / tau)
```

Where:
- `C` = total carbs (grams)
- `tau` = time constant (determines peak timing)
- `t` = minutes since meal
- Peak occurs at `t = tau` (by definition of gamma(2, tau))

#### Fat-Modified Time Constant

Fat slows gastric emptying, which stretches tau:

```
tau_carb = tau_base + (fatGrams x fatSlowingCoefficient)

Where:
  tau_base = 35 min (simple carbs) to 90 min (complex carbs)
  fatSlowingCoefficient = 0.8 min per gram of fat

Examples:
  No fat:   tau = 35 min -> peak at 35 min, 90% absorbed by ~120 min
  15g fat:  tau = 47 min -> peak at 47 min, 90% absorbed by ~160 min
  35g fat:  tau = 63 min -> peak at 63 min, 90% absorbed by ~215 min
  60g fat:  tau = 83 min -> peak at 83 min, 90% absorbed by ~280 min
```

#### Generating Carb Entries from the Curve

Instead of a single lump entry or equal-sized entries, we sample the gamma curve at regular intervals (every 10 minutes) and create entries proportional to the curve value:

```
For each time point t_i = 0, 10, 20, ..., duration:
  entryCarbs_i = C x [CDF(t_i + 5) - CDF(t_i - 5)]

  where CDF(t) = 1 - (1 + t/tau) x exp(-t/tau)  (gamma(2,tau) CDF)

  -> Create CarbEntryStored with:
      carbs = entryCarbs_i
      actualDate = mealTime + t_i minutes
      isFPU = true
      fpuID = mealID
      note = "carb-absorption"
```

This produces a bell-curved distribution of entries: small at the beginning, large at the peak, tapering off — matching the actual absorption profile.

**Split dosing integration:** Entries within the safe window (0 to upfrontWindowMinutes) are summed and presented as the upfront bolus recommendation. Entries beyond the safe window are stored as future entries for oref/SMB delivery. See Section 5.6 for details.

#### Duration Calculation

Instead of the FPU step function, use the 95th percentile of the gamma CDF:

```
duration = tau x 4.74  (time to 95% absorption for gamma(2,tau))

Examples:
  tau = 35: duration ~ 166 min (2.8h)
  tau = 47: duration ~ 223 min (3.7h)
  tau = 63: duration ~ 299 min (5.0h)
  tau = 83: duration ~ 394 min (6.6h)
```

---

### 5.2 Curve 2 — Protein Gluconeogenesis

#### Model: Delayed Sigmoid

Protein's glucose-raising effect via gluconeogenesis follows a slow-onset sigmoid that doesn't begin until amino acid absorption and glucagon response have had time to stimulate hepatic glucose production:

```
Ra_protein(t) = P_glucose x sigmoid(t, onset, steepness) x decay(t, peak)

Where:
  P_glucose = proteinGrams x proteinGlucoFactor(proteinGrams)

  sigmoid(t, onset, steepness) = 1 / (1 + exp(-(t - onset) / steepness))
  -> Onset: center of sigmoid = 180 min (3h)
  -> Steepness: 40 min (controls how quickly it ramps up)

  decay(t, peak) = exp(-(t - peak)^2 / (2 x sigma^2))  for t > peak
                 = 1.0                                    for t <= peak
  -> Peak: 300 min (5h)
  -> sigma: 120 min (gradual decay after peak)
```

#### Protein Glucose Factor — Smooth Ramp (Not Cliff)

Instead of a hard cutoff at 28g, the protein effect uses a smooth linear ramp between 15g and 40g:

```
proteinGlucoFactor(proteinGrams):
  if proteinGrams <= 15:   0.0    (below threshold, negligible effect)
  if proteinGrams >= 40:   0.35   (full effect, 35% of protein as glucose-equiv)
  else: linear interpolation:
    factor = (proteinGrams - 15) / (40 - 15) x 0.35

Examples:
  15g protein -> factor = 0.00  (no effect)
  20g protein -> factor = 0.07  (small effect)
  25g protein -> factor = 0.14  (moderate)
  28g protein -> factor = 0.18  (where research threshold is)
  35g protein -> factor = 0.28  (strong)
  40g protein -> factor = 0.35  (full effect, plateau)
```

**Rationale:** The hard 28g cutoff in research reflects statistical significance thresholds, not a physiological cliff. A meal with 27g protein has nearly the same gluconeogenic effect as one with 28g. The ramp starts at 15g (below which research shows no measurable effect) and reaches full strength at 40g (where Smart et al. measured their strongest signal).

**Formula:** `min(0.35, max(0.0, (proteinGrams - 15) / (40 - 15) x 0.35))`

The 40g+ plateau and 15g threshold are learnable parameters — outcome learning (Phase F) can personalize these per individual.

#### Generating Protein Entries

Same approach as carbs — sample the curve and create properly-timed entries:

```
For each time point t_i = 90, 100, 110, ..., 420 min:
  glucoseEquiv_i = P_glucose x [proteinCDF(t_i + 5) - proteinCDF(t_i - 5)]

  -> Create CarbEntryStored with:
      carbs = glucoseEquiv_i
      actualDate = mealTime + t_i minutes
      isFPU = true
      fpuID = mealID
      note = "protein-gluconeogenesis"
```

---

### 5.3 Curve 3 — Fat Insulin Resistance

#### The Fundamental Problem

Fat's primary late effect is NOT adding glucose — it's making insulin less effective. This is a **multiplier** on insulin needs, not an additive term. Ideally we'd modify oref's sensitivity parameter. But since we can't modify oref, we approximate the insulin resistance as **additional carb-equivalent entries** that create the extra insulin demand.

#### Model: Normalized Gaussian with Corrected Coefficient

The original plan used a peak coefficient of 0.15 g-carb-equiv per g-fat. This is incorrect — the math produces a dangerous overdose.

**The error in the original derivation:**

The plan derives 0.69g total carb-equivalent per gram of fat from Wolpert (35g fat -> 24g total carb-equiv -> 24/35 = 0.69). Then it says "the peak coefficient is 0.15 because it's spread over time." But a Gaussian with sigma=90 min sampled at 10-min intervals spans ~14.7 significant sample points. With a peak of 0.15:

```
35g fat x 0.15 x 14.7 effective points = 77g carb-equivalent
Actual Wolpert data: 24g carb-equivalent
Overdose factor: 3.2x -- DANGEROUS
```

**The corrected approach:** Use 0.69 as the **total** coefficient and normalize the Gaussian so entries always sum to exactly the intended total:

```
totalFatEquiv = fatGrams x 0.69 x individualAdjustmentFactor

For each time point t_i:
  rawGaussian_i = exp(-(t_i - t_peak)^2 / (2 x sigma^2))

gaussianSum = sum of all rawGaussian_i values

entry(t_i) = totalFatEquiv x rawGaussian_i / gaussianSum
```

**This guarantees the entries always sum to exactly `totalFatEquiv` regardless of interval spacing or sigma value.**

For 35g fat with default adjustment factor 1.0:
- Total = 35 x 0.69 = 24.15g carb-equivalent spread as a bell curve
- Peak at 6h (360 min), sigma = 90 min
- Matches Wolpert's measured 40% more insulin (24g at CR 10 = 2.4U additional = 40% of base 6U)

#### Fat Ramp (Not Hard Cutoff)

Instead of a hard 10g cutoff, fat resistance uses a smooth ramp:

```
fatEffectiveFraction(fatGrams):
  if fatGrams <= 0:    0.0
  if fatGrams >= 20:   1.0
  else: fatGrams / 20  (linear ramp)

totalFatEquiv = fatGrams x 0.69 x fatEffectiveFraction(fatGrams) x individualAdjustmentFactor
```

This means:
- 5g fat -> 5 x 0.69 x 0.25 = 0.86g carb-equiv (tiny)
- 10g fat -> 10 x 0.69 x 0.50 = 3.45g carb-equiv (small)
- 20g fat -> 20 x 0.69 x 1.0 = 13.8g carb-equiv (full coefficient)
- 35g fat -> 35 x 0.69 x 1.0 = 24.15g carb-equiv (matches Wolpert)

#### Gaussian Parameters

```
t_peak = 360 min (6h, from Hoeg 2010)
sigma = 90 min (significant onset at ~180min, resolves by ~540min)
Only active when t > 120 min (no resistance before FFA elevation begins)
```

#### Why This Works as Carb Equivalents

When we add carb-equivalent entries during the fat resistance window, oref sees COB and delivers insulin to cover it. The insulin it delivers compensates for the reduced effectiveness of insulin already on board. The net effect is correct: more insulin is delivered during the fat-resistance window.

This is an approximation — the "correct" approach would be to modify ISF dynamically. But it works within oref's framework and the BG-adaptive layer corrects any inaccuracy.

#### Generating Fat Resistance Entries

```
For each time point t_i = 120, 130, 140, ..., 540 min:
  entry(t_i) = totalFatEquiv x gaussian(t_i) / sum(all gaussian values)

  -> Create CarbEntryStored with:
      carbs = entry(t_i)
      actualDate = mealTime + t_i minutes
      isFPU = true
      fpuID = mealID
      note = "fat-resistance"
```

---

### 5.4 Composite Insulin Need Calculation

The total insulin need at any time `t` is the sum of all three curves:

```
totalGlucoseImpact(t) = carbAbsorption(t) + proteinGluconeogenesis(t) + fatResistanceEquiv(t)

insulinNeeded(t) = totalGlucoseImpact(t) / CR
```

Where CR is already adjusted by the Garmin sensitivity factor (via scaled entry amounts).

**Composite curve visualization:**

```
Glucose Impact / Insulin Need
    |
    |    /\
    |   /  \  <- Carbs (gamma, fat-stretched)
    |  /    \--\
    | /        \\
    |/     /-----\------\  <- Protein (delayed sigmoid, smooth ramp)
    |     /        \      \
    |    /     /--------\----\  <- Fat resistance (normalized gaussian)
    |   /     /           \    \
    |  /     /              \    \
    | /     /                 \    \
    +--+--+--+--+--+--+--+--+--+---> Hours
       1  2  3  4  5  6  7  8  9

    ^              ^                  ^
    |              |                  |
    Upfront        SMBs deliver       Fat resistance
    bolus covers   remaining carbs    entries drive
    this portion   as they absorb     late SMBs
```

---

### 5.5 Replacing the FPU Entry Distribution

#### Current Implementation Location

`CarbsStorage.swift`, method `processFPU()` (lines 143-205):
- Receives fat, protein, and settings
- Computes carb equivalents via Warsaw method
- Creates equal-sized entries at regular intervals after 60-min delay

#### New Implementation

Replace `processFPU()` with `MacroAbsorptionEngine.generateEntries()`:

```swift
struct MacroAbsorptionEngine {

    /// Generate all carb entries for a mixed meal using the three-curve model.
    /// Returns: (upfrontCarbs: Double, futureEntries: [CarbsEntry])
    /// - upfrontCarbs: the amount to recommend for immediate bolus
    /// - futureEntries: curve-shaped entries for oref to cover via SMBs
    static func generateEntries(
        carbs: Double,
        fat: Double,
        protein: Double,
        mealTime: Date,
        sensitivityFactor: Double,     // from Garmin layer (0.60-1.40)
        upfrontPercent: Double? = nil,  // user override; nil = curve-calculated
        settings: FPUSettings           // individualAdjustmentFactor, etc.
    ) -> MacroAbsorptionResult {

        let mealID = UUID().uuidString
        var allEntries: [CarbsEntry] = []

        // --- Curve 1: Carbohydrate absorption (gamma-shaped) ---
        let tauCarb = carbTau(baseTau: 35, fatGrams: fat)
        let carbEntries = generateGammaCurveEntries(
            totalAmount: carbs,
            tau: tauCarb,
            mealTime: mealTime,
            intervalMinutes: 10,
            mealID: mealID,
            note: "carb-absorption"
        )
        allEntries.append(contentsOf: carbEntries)

        // --- Curve 2: Protein gluconeogenesis (delayed sigmoid, smooth ramp) ---
        let proteinFactor = proteinGlucoFactor(proteinGrams: protein)
        if proteinFactor > 0 {
            let glucoseEquiv = protein * proteinFactor
                * settings.individualAdjustmentFactor
            let proteinEntries = generateProteinCurveEntries(
                totalGlucose: glucoseEquiv,
                mealTime: mealTime,
                intervalMinutes: 15,
                mealID: mealID
            )
            allEntries.append(contentsOf: proteinEntries)
        }

        // --- Curve 3: Fat insulin resistance (normalized gaussian) ---
        let fatFraction = fatEffectiveFraction(fatGrams: fat)
        if fatFraction > 0 {
            let totalFatEquiv = fat * 0.69 * fatFraction
                * settings.individualAdjustmentFactor
            let fatEntries = generateNormalizedFatResistanceEntries(
                totalEquiv: totalFatEquiv,
                mealTime: mealTime,
                intervalMinutes: 15,
                mealID: mealID
            )
            allEntries.append(contentsOf: fatEntries)
        }

        // --- Apply sensitivity factor to ALL entries ---
        let adjustedEntries = allEntries.map { entry in
            var adjusted = entry
            adjusted.carbs = Decimal(Double(entry.carbs) / sensitivityFactor)
            return adjusted
        }

        // --- Split into upfront and future ---
        let safeWindowMinutes = settings.upfrontWindowMinutes  // default 45
        let curveSuggestedPercent = gammaCDFPercent(
            tau: tauCarb, windowMinutes: safeWindowMinutes
        )
        let effectivePercent = upfrontPercent ?? curveSuggestedPercent

        let upfrontCarbs = carbs * effectivePercent / sensitivityFactor
        let futureEntries = adjustedEntries.filter {
            $0.actualDate > mealTime.addingTimeInterval(
                Double(safeWindowMinutes) * 60
            )
        }

        return MacroAbsorptionResult(
            mealID: mealID,
            upfrontCarbs: upfrontCarbs,
            upfrontPercent: effectivePercent,
            curveSuggestedPercent: curveSuggestedPercent,
            futureEntries: futureEntries,
            allEntries: adjustedEntries,
            sensitivityFactor: sensitivityFactor,
            originalCarbs: carbs,
            originalFat: fat,
            originalProtein: protein,
            tauCarb: tauCarb,
            proteinFactor: proteinFactor,
            fatTotalEquiv: fat > 0 ? fat * 0.69 * fatFraction : 0
        )
    }

    /// Smooth protein ramp: 0 at <=15g, linear to 0.35 at 40g, plateau above
    static func proteinGlucoFactor(proteinGrams: Double) -> Double {
        if proteinGrams <= 15 { return 0.0 }
        if proteinGrams >= 40 { return 0.35 }
        return (proteinGrams - 15) / (40 - 15) * 0.35
    }

    /// Smooth fat ramp: linear 0->1 over 0-20g
    static func fatEffectiveFraction(fatGrams: Double) -> Double {
        if fatGrams <= 0 { return 0.0 }
        if fatGrams >= 20 { return 1.0 }
        return fatGrams / 20.0
    }
}
```

---

### 5.6 Split Dosing Strategy

#### How the Safe Window Is Calculated

The gamma(2, tau) CDF gives the fraction of carbs absorbed by any time `t`:

```
CDF(t) = 1 - (1 + t/tau) x exp(-t/tau)

For the default safe window of 45 minutes:
  No fat (tau=35):  CDF(45) = 0.55 -> 55% upfront
  15g fat (tau=47): CDF(45) = 0.40 -> 40% upfront
  28g fat (tau=57): CDF(45) = 0.28 -> 28% upfront
  50g fat (tau=75): CDF(45) = 0.16 -> 16% upfront
```

Higher fat content automatically reduces the upfront percentage because the gamma curve is stretched — this is the physiologically correct behavior.

#### Safe Window Configuration

The safe window duration is configurable (default 45 min, range 30-60 min):

- **Shorter (30 min):** More conservative initial dose. Better for users who experience fast insulin onset or have high fat meals. More reliance on SMBs.
- **Longer (60 min):** Larger initial dose. Better for users with slower insulin action or low-fat meals. Less reliance on SMBs.

#### Examples Across Meal Types

| Meal | Carbs | Fat | tau | Upfront % (45min) | Upfront Carbs | Future Entries |
|------|-------|-----|-----|--------------------|--------------|----------------|
| Rice + chicken | 60g | 5g | 39 | 49% | 29g | 31g |
| Pasta + sauce | 70g | 15g | 47 | 40% | 28g | 42g |
| Pizza (2 slices) | 65g | 28g | 57 | 28% | 18g | 47g |
| Burger + fries | 80g | 40g | 67 | 21% | 17g | 63g |
| Pure carbs (juice) | 30g | 0g | 35 | 55% | 17g | 13g |

---

### 5.7 Sensitivity-Adjusted Entries

The Garmin sensitivity factor is applied to ALL entry amounts (carbs + protein + fat). This means oref sees "insulin-equivalent carbs" rather than grams eaten.

**Why scale entries instead of CR/ISF:**

1. oref reads ISF/CR from the pump profile — we cannot easily change those on the fly
2. Fat/protein entries are already "fake carbs" (carb-equivalents), so scaling them is natural
3. If entries stay at real grams but the user is 20% resistant, oref will under-deliver SMBs for the remaining carbs -> late hyperglycemia (the exact problem we're solving)
4. The upfront bolus recommendation also uses the sensitivity factor: `upfrontCarbs / (CR x sensitivityFactor)` equivalent to `(upfrontCarbs / sensitivityFactor) / CR`

**COB display concern:** COB has never shown "grams eaten" — it already includes FPU entries (fat/protein "fake carbs"). The display should show:

```
COB: 83g (65g eaten, sensitivity-adjusted)
```

This is transparent to the user: "I ate 65g carbs, but because of poor sleep my body treats it like 83g from an insulin perspective."

---

## Layer 2: BG-Adaptive Real-Time Correction

### 6.1 Predicted vs Actual BG Comparison

Every 5 minutes (each loop cycle), the adaptive layer runs **BEFORE oref** so that oref picks up the corrected entries in the same cycle:

1. **Computes predicted BG** from the three curves and insulin delivered:
```
predictedBG(t) = mealTimeBG
    + SUM carbCurve.glucoseImpact(0..t) / ISF_adjusted
    + SUM proteinCurve.glucoseImpact(0..t) / ISF_adjusted
    + SUM fatResistanceEquiv.glucoseImpact(0..t) / ISF_adjusted
    - SUM insulinDelivered(0..t) x ISF_adjusted
```

2. **Reads actual CGM value**

3. **Computes error and trend error:**
```
error = actualBG - predictedBG
trend_error = actualTrend(15min) - predictedTrend(15min)
```

### 6.2 Curve Adjustment Algorithm

Based on the error signal, adjust the **remaining** (future) carb entries:

```
If error > 0 (actual higher than predicted):
  -> Absorption is faster OR more glucose than modeled
  -> Scale up remaining entries by: 1 + (error / scalingConstant)
  -> Cap at 1.5x to prevent runaway adjustment

If error < 0 (actual lower than predicted):
  -> Absorption is slower OR less glucose than modeled
  -> Scale down remaining entries by: 1 + (error / scalingConstant)
  -> Floor at 0.5x to prevent entries from going to zero

scalingConstant = 100 mg/dL (tunable)
  -> At +50 mg/dL error: scale remaining by 1.5x
  -> At -50 mg/dL error: scale remaining by 0.5x
  -> At +20 mg/dL error: scale remaining by 1.2x
```

**Trend-based early detection:**

```
If trend_error > 0 (rising faster than predicted):
  -> Don't wait for absolute error to accumulate
  -> Apply 50% of the trend correction proactively
  -> This catches the pizza effect EARLY (BG starting to rise at 3h
    before absolute error is large)
```

### 6.3 Integration With the Loop Cycle

The adaptive layer hooks into Trio's existing loop cycle and runs **BEFORE oref**:

```
Every 5 minutes when the loop runs:
  1. Read current CGM glucose
  2. Read current IOB from previous oref determination
  3. MacroAdaptiveService runs:
     a. Compute predicted BG from our model
     b. Calculate error vs actual CGM
     c. If |error| > threshold (e.g., 15 mg/dL):
        - Fetch all future CarbEntryStored with our mealID
        - Scale their carbs values by adjustment factor
        - Save updated entries to Core Data
     d. Determine meal-mode SMB status (see 6.4)
     e. Set effective maxSMB for this cycle
  4. oref runs with:
     - Updated carb entries (from step 3c)
     - Updated maxSMB (from step 3e)
  5. oref makes SMB/temp basal decision
```

**Important:** We only modify FUTURE entries (actualDate > now). Past entries are historical record and must not be altered.

**Why BEFORE oref:** If the adaptive service runs after oref, the corrections aren't visible until the next cycle (5 minutes later). Running before oref means corrections are acted on immediately, reducing lag from 10 minutes to 5 minutes.

### 6.4 Meal-Mode SMB Enhancement

When the engine has active meal entries being absorbed, temporarily raise the SMB ceiling:

```swift
struct MealModeState {
    let isActive: Bool
    let effectiveMaxSMB: Double  // user's maxSMB x multiplier, or user's maxSMB if inactive

    /// All safety gates must pass for meal-mode to be active
    static func evaluate(
        activeMealEntries: [CarbEntryStored],
        currentBG: Double,
        bgTrend: Double,          // mg/dL per 5min
        cgmAge: TimeInterval,     // seconds since last CGM reading
        userMaxSMB: Double,
        mealSMBMultiplier: Double, // user setting, default 2.0
        bgFloor: Double            // user setting, default 90
    ) -> MealModeState {

        // Gate 1: Active meal entries exist
        let hasFutureEntries = activeMealEntries.contains { $0.actualDate > Date() }
        guard hasFutureEntries else {
            return MealModeState(isActive: false, effectiveMaxSMB: userMaxSMB)
        }

        // Gate 2: BG above floor
        guard currentBG > bgFloor else {
            return MealModeState(isActive: false, effectiveMaxSMB: userMaxSMB)
        }

        // Gate 3: BG trend flat or rising
        guard bgTrend >= -1.0 else {  // allow slight dip, not rapid fall
            return MealModeState(isActive: false, effectiveMaxSMB: userMaxSMB)
        }

        // Gate 4: CGM data fresh
        guard cgmAge < 600 else {  // 10 minutes
            return MealModeState(isActive: false, effectiveMaxSMB: userMaxSMB)
        }

        // All gates pass: enable meal-mode enhanced SMBs
        return MealModeState(
            isActive: true,
            effectiveMaxSMB: userMaxSMB * mealSMBMultiplier
        )
    }
}
```

**Implementation note:** The `effectiveMaxSMB` is passed to the oref profile/preferences before oref runs each cycle. oref's `maxIOB` limit is NEVER modified — only `maxSMB` is temporarily raised. This means oref still enforces the total insulin ceiling.

### 6.5 Safety Constraints

- **Maximum single-cycle adjustment:** +/-50% of remaining entries
- **Maximum cumulative adjustment:** +/-100% of original total (never more than 2x original, never less than 0x)
- **Minimum time between adjustments:** 15 minutes (3 loop cycles) to prevent oscillation
- **Low BG guard:** If BG < 80 mg/dL, do NOT increase remaining entries regardless of model prediction
- **High BG guard:** If BG > 300 mg/dL, cap entries at original values (don't chase extreme highs with more carb entries — the loop should handle this with its own high-correction logic)
- **Staleness check:** If CGM data is >15 min old, skip adjustment entirely
- **Meal-mode SMB gates:** All 4 gates must pass independently each cycle (see 6.4)
- **maxIOB unchanged:** oref's maxIOB is NEVER increased — only maxSMB is temporarily raised within the meal window. oref will still refuse to deliver SMBs if total IOB approaches maxIOB.

---

## Layer 3: Garmin Sensitivity Model

### 7.1 Firestore Database Structure

The user has an existing Firebase Firestore database that receives all Garmin Health API data whenever the watch syncs to Garmin Connect. The last 30 days of data are available.

**Expected Firestore collections:**

```
firestore/
|-- dailySummaries/
|   +-- {date}/
|       |-- steps: Int
|       |-- activeCalories: Int
|       |-- intensityMinutes: Int
|       |-- restingHeartRate: Int
|       |-- maxHeartRate: Int
|       |-- averageStress: Int
|       |-- maxStress: Int
|       |-- bodyBatteryHigh: Int
|       |-- bodyBatteryLow: Int
|       |-- bodyBatteryAtWake: Int
|       +-- ...
|-- sleepData/
|   +-- {date}/
|       |-- sleepScore: Int (0-100)
|       |-- totalSleepMinutes: Int
|       |-- deepSleepMinutes: Int
|       |-- lightSleepMinutes: Int
|       |-- remSleepMinutes: Int
|       |-- awakeSleepMinutes: Int
|       |-- averageSpO2: Double
|       |-- lowestSpO2: Double
|       |-- averageRespirationRate: Double
|       +-- ...
|-- stressData/
|   +-- {date}/
|       |-- samples: [{timestamp, stressLevel}]
|       |-- averageStress: Int
|       +-- ...
|-- heartRateData/
|   +-- {date}/
|       |-- restingHR: Int
|       |-- averageHR: Int
|       |-- samples: [{timestamp, heartRate}]
|       +-- ...
|-- hrvData/
|   +-- {date}/
|       |-- weeklyAverage: Double
|       |-- lastNightAverage: Double
|       |-- status: String  // "balanced", "low", "unbalanced"
|       +-- ...
|-- activities/
|   +-- {activityId}/
|       |-- startTime: Timestamp
|       |-- duration: Int (seconds)
|       |-- activityType: String
|       |-- activeCalories: Int
|       |-- averageHR: Int
|       |-- maxHR: Int
|       |-- trainingEffect: Double
|       +-- ...
|-- bodyBattery/
|   +-- {date}/
|       |-- samples: [{timestamp, level}]  // continuous throughout day
|       |-- highestLevel: Int
|       |-- lowestLevel: Int
|       +-- ...
+-- trainingStatus/
    +-- latest/
        |-- trainingLoad: String  // "low"/"optimal"/"high"/"very high"
        |-- trainingStatus: String  // "productive"/"recovery"/"overreaching"/"detraining"
        |-- vo2Max: Double
        |-- recoveryTimeHours: Int
        +-- ...
```

**Note:** The exact collection structure needs to be confirmed with the user's actual Firestore schema. The service will be configurable to map to the actual field paths.

### 7.2 GarminContextSnapshot

```swift
/// A point-in-time snapshot of Garmin health data relevant to insulin sensitivity.
/// Queried from Firestore at meal detection time.
struct GarminContextSnapshot {
    let queryTime: Date

    // === Sleep (last night) ===
    let sleepScore: Int?              // 0-100, Garmin's composite score
    let totalSleepMinutes: Int?
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let awakeSleepMinutes: Int?
    let averageSpO2: Double?

    // === Stress & Recovery (current) ===
    let currentBodyBattery: Int?      // 0-100, queried at meal time
    let bodyBatteryAtWake: Int?       // morning level (recovery quality)
    let currentStress: Int?           // 0-100, current reading
    let averageStressToday: Int?

    // === Heart Rate / HRV ===
    let restingHR: Int?
    let restingHR7DayAvg: Int?        // for delta computation
    let hrvLastNight: Double?         // ms
    let hrvWeeklyAvg: Double?         // for delta computation
    let hrvStatus: String?            // "balanced" / "low" / "unbalanced"

    // === Activity (today) ===
    let stepsToday: Int?
    let activeCaloriesToday: Int?
    let intensityMinutesToday: Int?
    let workoutsToday: [GarminWorkout]?

    // === Activity (yesterday -- for delayed sensitivity effects) ===
    let stepsYesterday: Int?
    let activeCaloriesYesterday: Int?
    let workoutsYesterday: [GarminWorkout]?

    // === Training ===
    let trainingLoad: String?         // "low"/"optimal"/"high"/"very high"
    let trainingStatus: String?       // "productive"/"recovery"/"overreaching"
    let recoveryTimeHours: Int?

    // === Computed Deltas ===
    var restingHRDelta: Int? {
        guard let current = restingHR, let avg = restingHR7DayAvg else { return nil }
        return current - avg
    }

    var hrvDeltaPercent: Double? {
        guard let current = hrvLastNight, let avg = hrvWeeklyAvg, avg > 0 else { return nil }
        return ((current - avg) / avg) * 100
    }
}

struct GarminWorkout {
    let startTime: Date
    let durationMinutes: Int
    let activityType: String      // "running", "cycling", "strength", etc.
    let activeCalories: Int
    let averageHR: Int
    let trainingEffect: Double?   // 0-5 scale
}
```

### 7.3 Sensitivity Factor Calculation

The sensitivity factor is a multiplier applied to ALL entry amounts before they are stored:

```
sensitivityFactor: Double  (range 0.60 to 1.40)

  1.0  = baseline (normal day)
  0.80 = 20% more resistant (entries scaled by 1/0.80 = 1.25x -> 25% more insulin)
  1.20 = 20% more sensitive (entries scaled by 1/1.20 = 0.83x -> 17% less insulin)

Usage (applied during entry generation):
  entryCarbs = rawEntryCarbs / sensitivityFactor

  (Lower sensitivity -> higher entry amounts -> oref delivers more insulin)
  (Higher sensitivity -> lower entry amounts -> oref delivers less insulin)

For the upfront bolus recommendation:
  upfrontBolus = upfrontCarbs / CR
  where upfrontCarbs is already sensitivity-adjusted
```

### 7.4 How Each Metric Affects Insulin Sensitivity

Based on research literature:

| Metric | Direction | Magnitude | Evidence |
|--------|-----------|-----------|----------|
| **Poor sleep** (score <50) | Decreases Sensitivity | 15-30% | Well-documented; Spiegel 1999, Donga 2010 |
| **High stress** (>60) / Low Body Battery (<20) | Decreases Sensitivity | 10-20% | Cortisol -> hepatic glucose output + peripheral resistance |
| **Elevated resting HR** (>8 bpm above baseline) | Decreases Sensitivity | 5-15% | Marker of illness, stress, poor recovery |
| **Low HRV** (>15% below baseline) | Decreases Sensitivity | 5-10% | Sympathetic dominance -> catecholamines -> resistance |
| **More activity yesterday** (>500 active cal) | Increases Sensitivity | 10-20% | GLUT4 upregulation; delayed 2-24h; Borghouts 2000 |
| **Intense workout today** | Increases Sensitivity | 5-15% (after initial rise) | Acute: cortisol spike (resistant), then: GLUT4 (sensitive) |
| **Training overreaching** | Decreases Sensitivity | 10-15% | Systemic stress response |
| **Good sleep** (score >85) | Increases Sensitivity | 5-10% | Optimal recovery -> baseline or better |
| **Low stress** / High Body Battery (>75) | Increases Sensitivity | 5-10% | Low cortisol, parasympathetic dominant |

### 7.5 Rule-Based Model (V1)

The initial model uses research-calibrated rules. This runs immediately — no training data needed.

```swift
struct GarminSensitivityModel {

    /// Compute sensitivity factor from Garmin context.
    /// Returns 0.60 - 1.40 where 1.0 = normal baseline.
    static func sensitivityFactor(from ctx: GarminContextSnapshot) -> Double {
        var factor = 1.0

        // --- Sleep ---
        // Poor sleep is the strongest single predictor of next-day resistance.
        // Spiegel (1999): 4h sleep x 6 nights -> 40% reduced glucose clearance.
        // We model a graded response.
        if let sleep = ctx.sleepScore {
            switch sleep {
            case ..<40:  factor -= 0.22  // terrible sleep: 22% more resistant
            case ..<55:  factor -= 0.15  // poor sleep
            case ..<70:  factor -= 0.08  // fair sleep
            case 85...:  factor += 0.05  // great sleep: 5% more sensitive
            default:     break           // 70-84: normal range, no adjustment
            }
        }

        // Duration matters independently of score
        if let duration = ctx.totalSleepMinutes {
            if duration < 300 { factor -= 0.10 }       // <5h: significant
            else if duration < 360 { factor -= 0.05 }  // <6h: mild
        }

        // --- Stress & Recovery ---
        // Body Battery integrates sleep quality, stress, and activity.
        // Low BB at meal time = depleted recovery capacity = resistance.
        if let bb = ctx.currentBodyBattery {
            switch bb {
            case ..<15:  factor -= 0.18  // critically depleted
            case ..<30:  factor -= 0.12  // low
            case ..<50:  factor -= 0.05  // below average
            case 75...:  factor += 0.05  // well recovered
            default:     break           // 50-74: normal
            }
        }

        // Acute stress at meal time
        if let stress = ctx.currentStress {
            if stress > 75 { factor -= 0.08 }       // high acute stress
            else if stress > 60 { factor -= 0.04 }  // moderate
        }

        // --- Heart Rate / HRV ---
        // Elevated resting HR signals illness, stress, or poor recovery.
        if let hrDelta = ctx.restingHRDelta {
            if hrDelta > 12 { factor -= 0.12 }      // significantly elevated
            else if hrDelta > 8 { factor -= 0.07 }   // mildly elevated
            else if hrDelta < -5 { factor += 0.03 }  // unusually low (well-rested)
        }

        // Low HRV = sympathetic dominance = cortisol/catecholamines
        if let hrvDelta = ctx.hrvDeltaPercent {
            if hrvDelta < -20 { factor -= 0.08 }     // HRV >20% below baseline
            else if hrvDelta < -10 { factor -= 0.04 } // >10% below
            else if hrvDelta > 15 { factor += 0.03 }  // well above baseline
        }

        // --- Activity ---
        // Yesterday's activity has the strongest delayed sensitivity effect.
        // Exercise-induced GLUT4 upregulation lasts 24-48h.
        if let yesterdayCal = ctx.activeCaloriesYesterday {
            if yesterdayCal > 600 { factor += 0.15 }      // very active day
            else if yesterdayCal > 400 { factor += 0.10 }  // active
            else if yesterdayCal > 250 { factor += 0.05 }  // moderately active
        }

        // Today's activity (smaller effect, still developing)
        if let todayCal = ctx.activeCaloriesToday {
            if todayCal > 400 { factor += 0.08 }
            else if todayCal > 200 { factor += 0.04 }
        }

        // --- Training Status ---
        // Overreaching = systemic stress = resistance
        if let status = ctx.trainingStatus {
            switch status {
            case "overreaching": factor -= 0.10
            case "detraining":   factor -= 0.05  // deconditioning
            case "productive":   factor += 0.03  // optimal training
            default: break
            }
        }

        // --- Clamp ---
        return max(0.60, min(1.40, factor))
    }
}
```

### 7.6 ML Model (V2, Future)

Once we have 50-100 meals with both Garmin context and BG outcomes, we can train a personalized model:

**Features (~20 inputs):**
```
Sleep: sleepScore, deepSleepPct, duration, SpO2
Stress: bodyBattery, currentStress, avgStress, restingHRDelta, hrvDelta
Activity: todayActiveCal, yesterdayActiveCal, intensityMin, yesterdayWorkoutDuration
Temporal: hourOfDay (encoded), dayOfWeek (encoded)
Meal: totalCarbs, totalFat, totalProtein, mealSimilarityScore
State: currentBG, currentIOB, currentCOB
```

**Target:** Effective ICR for this meal (derived from BG outcome)

**Model type:** Gradient-boosted tree (XGBoost-style) or simple neural network
- Trainable on-device via CoreML's MLUpdateTask
- ~50-100 meals needed for initial training
- Millisecond inference, fully private

**How it replaces the rule-based model:**
```swift
// V1 (rule-based):
let factor = GarminSensitivityModel.sensitivityFactor(from: garminContext)

// V2 (ML, when ready):
let factor = try coreMLModel.prediction(from: featureVector).sensitivityFactor
```

### 7.7 Claude Periodic Recalibration

Claude provides meta-analysis that neither the rule-based nor ML model can do on their own:

**Weekly report generation:**
1. Export last 7 days of: meals, BG outcomes, Garmin context, model predictions
2. Send to Claude API with analysis prompt
3. Claude identifies:
   - Patterns the model missed ("Your Tuesday resistance correlates with Monday night meetings — stress pattern")
   - Parameter adjustments ("Sleep weight should be 0.25, not 0.22 — your data shows stronger sleep sensitivity")
   - Novel interactions ("Post-strength-training, your morning insulin needs drop 20% but lunch needs increase 10%")
4. Claude outputs updated model parameters (rule weights or feature importances)
5. Parameters applied to the on-device model

**This is async and non-blocking** — it runs weekly, not at meal time. No latency impact on dosing decisions.

---

## Macros On Board (MOB) Tracking System

### 8.1 Observer-Driven Automatic Detection

The existing HKObserverQuery (auto-started at app launch) already detects Cronometer writes. The MOB system extends this:

```
Observer fires -> snapshot delta computed -> meal detected
  -> MacroAbsorptionEngine.generateEntries() called automatically
  -> Entries stored in Core Data with unique mealID
  -> Recommendation shown to user
  -> User doesn't need to tap "Crono" manually
```

### 8.2 MOB State Machine

```swift
/// Tracks macros currently "on board" (being absorbed) for display and decisions.
@Observable
final class MacrosOnBoardTracker {

    struct ActiveMeal: Identifiable {
        let id: UUID                    // unique mealID
        let detectedAt: Date
        let originalCarbs: Double
        let originalFat: Double
        let originalProtein: Double
        let sensitivityFactor: Double
        let entries: [CarbEntryStored]  // all generated entries for this meal
        var adjustmentHistory: [(Date, Double)]  // BG-adaptive adjustments
        var dosingState: DosingState    // tracks whether user has dosed
    }

    enum DosingState {
        case undosed                    // meal detected, user hasn't responded
        case dosed(at: Date, units: Double)  // user confirmed bolus
        case skipped(at: Date)          // user chose to skip
        case adjusted(at: Date, units: Double, overridePercent: Double)
    }

    var activeMeals: [ActiveMeal] = []

    /// Current macros on board (sum of all active meals' remaining absorption)
    var carbsOnBoard: Double { /* sum of remaining carb curve values */ }
    var proteinOnBoard: Double { /* sum of remaining protein curve values */ }
    var fatResistanceActive: Double { /* sum of remaining fat resistance values */ }

    /// Total additional insulin still needed from all active meals
    var insulinStillNeeded: Double { /* sum of future entries / CR */ }

    /// Has any undosed meal been detected?
    var hasUndosedMeal: Bool { activeMeals.contains { $0.dosingState == .undosed } }

    /// Is any meal currently in its absorption window? (for meal-mode SMBs)
    var hasMealInAbsorptionWindow: Bool {
        activeMeals.contains { meal in
            meal.entries.contains { $0.actualDate > Date() }
        }
    }
}
```

### 8.3 Recommendation Trigger Logic

```
When observer detects new macros:
  1. Compute meal delta (15-min grouping, existing logic)
  2. Check: is this a significant meal?
     - carbs > 5g OR fat > 5g OR protein > 10g
     - If not -> ignore (probably a correction snack or measurement noise)
  3. Check double-dose protection (see 8.5)
  4. Query Garmin context from Firestore
  5. Generate three-curve entries with split dosing
  6. Compute recommended upfront bolus from curve + current BG + IOB
  7. Show recommendation banner
```

### 8.4 In-App Recommendation Banner

The banner shows the split dosing strategy clearly:

```
+----------------------------------------------+
|  New meal detected from Cronometer            |
|                                               |
|  65g carbs * 28g fat * 22g protein            |
|  Sleep-adjusted: need 22% more insulin today  |
|                                               |
|  Upfront: 2.3U for 18g (28% of carbs)        |
|  Remaining: 60g effective COB via SMBs        |
|  (65g eaten -> 83g effective, sensitivity)    |
|                                               |
|  [Dose]  [Adjust]  [Skip - Not Dosing]       |
|                                               |
|  Carbs logged automatically.                  |
|  Do NOT also enter carbs manually.            |
+----------------------------------------------+
```

**After dosing, the banner changes to:**

```
+----------------------------------------------+
|  Dosed (checkmark) Pizza meal at 12:34 PM     |
|                                               |
|  2.3U delivered | 60g COB remaining via SMBs  |
|  Meal-mode SMBs: active (2.0x)               |
|  Next curve peak: ~57 min                     |
|                                               |
|  [View Details]                               |
+----------------------------------------------+
```

The banner persists on the main Trio screen until the meal's absorption window is complete or the user dismisses it.

### 8.5 Double-Dose Protection

This is a critical safety feature. Two dangerous scenarios must be prevented:

#### Scenario 1: Engine creates entries, user also manually enters carbs

**Mitigation:** When the engine creates entries for a detected meal, they are tagged with a unique `mealID`. Before creating entries:
- Check if entries with the same mealID already exist
- Check if entries within +/-15 min of the same meal time with similar carb amounts (>70% overlap) already exist
- If duplicates found, do NOT create new entries — show a warning instead

The recommendation banner clearly states: **"Carbs logged automatically. Do NOT also enter carbs manually."**

#### Scenario 2: User boluses via recommendation, then forgets and boluses again

**Mitigation:** The `DosingState` per meal tracks whether a bolus has been confirmed:
- Once dosed, the banner changes to the "Dosed" view (see above)
- If the user navigates to the bolus screen and the detected amount matches a recently dosed meal, show a warning:

```
+----------------------------------------------+
|  WARNING: You already dosed for this meal     |
|  at 12:34 PM (2.3U for pizza meal)            |
|                                               |
|  Are you sure you want to dose again?         |
|                                               |
|  [Cancel]  [Dose Anyway (confirm)]            |
+----------------------------------------------+
```

#### Scenario 3: Multiple rapid Cronometer writes for the same meal

**Mitigation:** The 15-min meal grouping window (carried from V1) ensures that items logged within 15 minutes of each other are treated as the same meal. If a second delta arrives within 15 minutes of an existing active meal, it is merged into that meal (entries are recalculated for the combined macros, and the original entries for that mealID are replaced).

### 8.6 User Controls: Upfront Bolus Slider

The "Adjust" action on the recommendation banner opens a slider interface:

```
+----------------------------------------------+
|  Adjust Bolus Split                           |
|                                               |
|  Upfront bolus: [====|=========] 28%          |
|                                               |
|  Curve-suggested: 28% (18g)                   |
|  Current setting: 28% (18g)                   |
|  Remaining via SMBs: 47g                      |
|                                               |
|  Meal SMB Multiplier: [====|====] 2.0x        |
|                                               |
|  [Apply]  [Reset to Curve Default]            |
+----------------------------------------------+
```

The slider ranges from 0% to 100%:
- **0%:** No upfront bolus, everything via SMBs (maximum caution)
- **Curve-suggested %:** The gamma curve's calculated safe amount (default)
- **100%:** Full bolus upfront (like the current system, for low-fat meals the user trusts)

The meal SMB multiplier slider ranges from 1.0x to 3.0x:
- **1.0x:** Normal SMB behavior (no enhancement)
- **2.0x:** Default, doubles maxSMB during meal absorption
- **3.0x:** Maximum aggressiveness for large meals

---

## Outcome Learning & Calibration

### 9.1 Per-Meal Curve Parameter Learning

After each meal (when outcomes are available at 2h, 4h, 6h, 8h checkpoints):

1. **Compare actual BG trajectory to original three-curve prediction**
2. **Identify which curve was wrong:**
   - Early error (0-2h): carb curve tau was wrong -> adjust tau_base
   - Mid error (2-4h): protein onset/magnitude wrong -> adjust proteinGlucoFactor
   - Late error (4-8h): fat resistance wrong -> adjust fatResistanceCoeff (total coefficient)
3. **Update personal parameters:**
   - `personalCarbTau`: learned tau_base for this person's carb absorption speed
   - `personalProteinThreshold`: may be lower or higher than 15g (ramp start)
   - `personalProteinPlateau`: may be lower or higher than 40g (ramp end)
   - `personalProteinFactor`: may be higher or lower than 0.35
   - `personalFatTotalCoeff`: may be higher or lower than 0.69
   - `personalFatRampEnd`: may be different from 20g
4. **Weight recent outcomes more heavily** (same recency weighting as V1)

### 9.2 Garmin Weight Calibration

Compare sensitivity factor predictions to actual outcomes:

```
For each meal with Garmin context:
  predicted = sensitivityFactor from Garmin model
  actual = effectiveISF derived from BG outcome
  error = actual - predicted

  -> Adjust the rule weights that contributed most to the error
  -> E.g., if sleep weight is 0.22 but outcomes show sleep matters more:
     increase sleep weight to 0.25
```

This is the bridge between the rule-based model and the eventual ML model — the rule weights get personalized over time.

### 9.3 ICR-Tagged Outcome Filtering

Carried forward from V1: only outcomes recorded at an ICR within +/-10% of the current pump ICR are used for learning. This prevents stale outcomes from polluting calibration when pump settings change.

Additionally, outcomes now also carry:
- The `sensitivityFactor` that was used
- The `GarminContextSnapshot` at meal time
- The curve parameters used (tau, proteinFactor, fatTotalCoeff)
- The split dosing percentages (upfront%, mealSMBMultiplier)
- The BG-adaptive adjustment history

This rich context enables the ML model (Phase G) and Claude recalibration.

---

## Implementation Plan

### 10.1 Phase A: Three-Curve Absorption Engine

**Goal:** Replace the linear FPU distribution with gamma/sigmoid/normalized-gaussian curves. Implement curve-driven split dosing for all entries.

**New files:**
- `Trio/Sources/Models/MacroAbsorptionEngine.swift` — curve math, entry generation, split dosing logic
- `Trio/Sources/Models/MacroAbsorptionResult.swift` — result struct with upfront/future split

**Modified files:**
- `Trio/Sources/APS/Storage/CarbsStorage.swift` — `processFPU()` calls `MacroAbsorptionEngine` instead of linear distribution

**Steps:**
1. Implement `gammaCDF()`, `proteinSigmoid()` (with smooth ramp), `normalizedFatGaussian()` (with 0.69 total coefficient) math functions
2. Implement `MacroAbsorptionEngine.generateEntries()` that samples curves at intervals
3. Implement split dosing: calculate upfront percentage from gamma CDF at safe window
4. Replace `CarbsStorage.processFPU()` internals to call the engine
5. Preserve backward compatibility: same `CarbEntryStored` output format, mealID tagging system
6. Add unit tests for:
   - Curve shapes match expected values
   - Fat coefficient normalization (entries sum to exactly totalFatEquiv)
   - Protein ramp produces correct factors across the range
   - Split dosing percentages match gamma CDF calculations
   - Entry generation for various meal compositions

**No oref changes. No UI changes yet.** This is a pure backend replacement.

---

### 10.2 Phase B: BG-Adaptive Loop Integration + Meal-Mode SMBs

**Goal:** Compare predicted vs actual BG and adjust future entries every loop cycle. Enable meal-mode SMB enhancement.

**New files:**
- `Trio/Sources/Services/MacroAdaptiveService.swift` — runs BEFORE oref each loop cycle
- `Trio/Sources/Models/MealModeState.swift` — meal-mode SMB evaluation with safety gates

**Modified files:**
- `Trio/Sources/APS/OpenAPS/OpenAPS.swift` — hook adaptive service BEFORE oref in loop cycle
- `Trio/Sources/APS/Storage/CarbsStorage.swift` — method to update future entries by mealID

**Steps:**
1. Implement `MacroAdaptiveService` with predicted BG computation
2. Hook into the loop cycle **BEFORE oref runs** (not after)
3. Implement entry scaling logic with safety constraints (+/-50% per cycle, +/-100% cumulative)
4. Implement `MealModeState` evaluation with all safety gates
5. Pass `effectiveMaxSMB` to oref profile before each cycle
6. Store prediction history for outcome learning
7. Add dampening to prevent oscillation (minimum 15-min between adjustments)
8. Add unit tests for safety gate logic

---

### 10.3 Phase C: Garmin Firestore Integration

**Goal:** Query Garmin health data from the user's existing Firestore database.

**New files:**
- `Trio/Sources/Services/Garmin/GarminFirestoreService.swift` — Firestore queries
- `Trio/Sources/Models/GarminContextSnapshot.swift` — data model

**Dependencies:**
- Firebase iOS SDK (FirebaseFirestore) — add via SPM
- `GoogleService-Info.plist` or manual Firestore configuration

**Steps:**
1. Add Firebase SDK dependency to the project
2. Implement `GarminFirestoreService` with configurable collection paths
3. Build `GarminContextSnapshot` from query results
4. Add Settings UI: Firestore project config, collection paths, enable/disable toggle
5. Test with user's actual Firestore data to confirm schema mapping
6. Add caching (don't re-query within 5 minutes)

**Configuration needed from user:**
- Firebase project ID
- Firestore collection paths (may differ from assumed schema above)
- Read-only security rules for Trio's access

---

### 10.4 Phase D: Sensitivity Model

**Goal:** Compute daily sensitivity factor from Garmin data and apply to all entry generation.

**New files:**
- `Trio/Sources/Models/GarminSensitivityModel.swift` — rule-based model

**Modified files:**
- `Trio/Sources/Models/MacroAbsorptionEngine.swift` — accept sensitivity factor, apply to all entries
- `Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift` — query Garmin before generating entries

**Steps:**
1. Implement rule-based `GarminSensitivityModel.sensitivityFactor(from:)`
2. Wire into `MacroAbsorptionEngine.generateEntries()` as input parameter
3. Display sensitivity factor in the recommendation view ("Sleep-adjusted: +22% insulin")
4. Show which Garmin metrics contributed to the adjustment
5. Display both eaten and effective amounts: "65g eaten -> 83g effective"
6. Log sensitivity factor with each recommendation for outcome learning

---

### 10.5 Phase E: MOB Tracking & Auto-Recommendation

**Goal:** Automatically detect meals, show split-dose recommendations, prevent double dosing.

**New files:**
- `Trio/Sources/Models/MacrosOnBoardTracker.swift` — MOB state machine with dosing state
- `Trio/Sources/Modules/Treatments/View/MealDetectedBannerView.swift` — in-app banner with split dosing display
- `Trio/Sources/Modules/Treatments/View/BolусAdjustSliderView.swift` — upfront % and SMB multiplier sliders

**Modified files:**
- `Trio/Sources/Services/HealthKit/NutritionHealthService.swift` — trigger MOB on observer fire
- `Trio/Sources/Modules/Home/HomeRootView.swift` (or equivalent) — display banner

**Steps:**
1. Implement `MacrosOnBoardTracker` with active meal management and dosing state
2. Implement double-dose protection (mealID checking, duplicate detection, merge logic)
3. Wire observer -> meal detection -> MOB update -> banner display
4. Build `MealDetectedBannerView` with split dosing info and Dose/Adjust/Skip actions
5. Build `BolusAdjustSliderView` with upfront % slider and meal SMB multiplier slider
6. Implement "Dosed" state banner with ongoing absorption info
7. Handle the "Skip - Not Dosing" case (treating a low, snacking without dosing)
8. Handle multiple meals (lunch detected while breakfast is still active)
9. Add double-dose warning when user navigates to manual bolus for a recently dosed meal

---

### 10.6 Phase F: Outcome Learning & Calibration

**Goal:** Personalize curve parameters and sensitivity weights from BG outcomes.

**Modified files:**
- `Trio/Sources/Models/CronometerRecommendation.swift` — store curve params + Garmin context + split dosing info with each recommendation
- `Trio/Sources/Models/MacroAbsorptionEngine.swift` — use personalized parameters
- `Trio/Sources/Models/GarminSensitivityModel.swift` — update rule weights

**Steps:**
1. Extend `CronometerMealRecommendation` with curve parameters, Garmin snapshot, split dosing percentages, and BG-adaptive adjustment history
2. Implement per-curve error analysis (early/mid/late checkpoint attribution)
3. Implement personal parameter updates (carbTau, proteinFactor/threshold/plateau, fatTotalCoeff/ramp)
4. Implement Garmin weight calibration from outcome comparison
5. Respect ICR tagging and factor lock from V1

---

### 10.7 Phase G: Claude Recalibration Service

**Goal:** Weekly Claude API analysis of outcomes, Garmin context, and model accuracy.

**New files:**
- `Trio/Sources/Services/AI/SensitivityRecalibrationService.swift`

**Modified files:**
- `Trio/Sources/Modules/AIInsightsConfig/ClaudeAPIService.swift` — new recalibration prompt

**Steps:**
1. Build data export: last 7 days of meals + outcomes + Garmin contexts + model predictions + split dosing effectiveness
2. Design Claude prompt for parameter analysis
3. Implement weekly trigger (timer or manual)
4. Parse Claude response into parameter updates
5. Apply updates to rule-based model weights
6. Show recalibration results in AI Insights UI

---

## File Reference

### New Files (V2)

| File | Phase | Purpose |
|------|-------|---------|
| `Trio/Sources/Models/MacroAbsorptionEngine.swift` | A | Three-curve math, entry generation, split dosing from gamma/sigmoid/gaussian |
| `Trio/Sources/Models/MacroAbsorptionResult.swift` | A | Result struct: upfront carbs, future entries, curve metadata |
| `Trio/Sources/Services/MacroAdaptiveService.swift` | B | BG-adaptive loop: predicted vs actual, entry scaling, runs BEFORE oref |
| `Trio/Sources/Models/MealModeState.swift` | B | Meal-mode SMB evaluation with safety gates |
| `Trio/Sources/Services/Garmin/GarminFirestoreService.swift` | C | Firestore queries for Garmin health data |
| `Trio/Sources/Models/GarminContextSnapshot.swift` | C | Structured Garmin data at meal time |
| `Trio/Sources/Models/GarminSensitivityModel.swift` | D | Rule-based sensitivity factor from Garmin context |
| `Trio/Sources/Models/MacrosOnBoardTracker.swift` | E | MOB state machine, active meal tracking, dosing state, double-dose protection |
| `Trio/Sources/Modules/Treatments/View/MealDetectedBannerView.swift` | E | In-app recommendation banner with split dosing display |
| `Trio/Sources/Modules/Treatments/View/BolusAdjustSliderView.swift` | E | Upfront % slider and meal SMB multiplier slider |
| `Trio/Sources/Services/AI/SensitivityRecalibrationService.swift` | G | Claude weekly recalibration |

### Modified Files (V2)

| File | Phase | Change |
|------|-------|--------|
| `Trio/Sources/APS/Storage/CarbsStorage.swift` | A, B | `processFPU()` calls `MacroAbsorptionEngine`; method to update future entries by mealID |
| `Trio/Sources/APS/OpenAPS/OpenAPS.swift` | B | Hook adaptive service BEFORE oref in loop cycle; pass effectiveMaxSMB |
| `Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift` | D, E | Query Garmin, wire MOB tracker, display sensitivity info |
| `Trio/Sources/Services/HealthKit/NutritionHealthService.swift` | E | Trigger MOB on observer fire |
| `Trio/Sources/Modules/Home/HomeRootView.swift` | E | Display meal detection banner, double-dose warnings |
| `Trio/Sources/Models/CronometerRecommendation.swift` | F | Store curve params + Garmin context + split dosing info |
| `Trio/Sources/Modules/AIInsightsConfig/ClaudeAPIService.swift` | G | Recalibration prompt |

### Unchanged Core Files

| File | Why Unchanged |
|------|---------------|
| `trio-oref/lib/determine-basal/cob.js` | oref's algorithm is NOT modified — we improve inputs only |
| `trio-oref/lib/meal/total.js` | oref continues to see standard carb entries |
| `trio-oref/lib/meal/history.js` | No changes to how oref reads entries |

---

## Key Technical Decisions

### 1. Three Separate Curves, Not One Combined Curve

**Decision:** Model carb absorption, protein gluconeogenesis, and fat insulin resistance as three independent curves.

**Reason:** The three mechanisms operate through different physiological pathways with different time courses. Carbs absorb through the gut (0-3h). Protein creates glucose via glucagon-driven gluconeogenesis (1.5-5h). Fat impairs insulin signaling via FFA/DAG/PKC (2-8h). Combining them into one curve would lose the temporal structure needed for accurate prediction and BG-adaptive correction.

### 2. Approximate Fat Resistance as Carb Equivalents

**Decision:** Represent fat's insulin resistance effect as additional carb entries rather than modifying ISF.

**Reason:** We cannot modify oref's sensitivity parameter from outside the algorithm. But we CAN add future carb entries that create the same insulin demand. When oref sees COB from fat-resistance entries, it delivers extra insulin via SMBs during the resistance window — achieving the same net effect. The BG-adaptive layer corrects any inaccuracy.

### 3. Gamma(2,tau) for Carb Absorption

**Decision:** Use the Hovorka-style gamma(2,tau) distribution rather than the full Dalla Man nonlinear model.

**Reason:** The Dalla Man model has 35 parameters and requires nonlinear ODE solving. The gamma(2,tau) is a well-validated approximation used in many closed-loop systems, has a closed-form CDF (easy to compute), and the BG-adaptive layer compensates for the simplification. Complexity in the base model is less important than getting the BG feedback loop right.

### 4. Work Within oref, Not Around It

**Decision:** Improve the carb entries fed to oref rather than building a parallel dosing system.

**Reason:** oref's deviation-based COB model already provides a self-correcting safety net. It compares actual BG to expected insulin impact and attributes the difference to carb absorption. Better-shaped input entries -> better oref decisions -> better outcomes. This avoids conflicts between two dosing systems and leverages oref's 10+ years of safety engineering.

### 5. Rule-Based Sensitivity First, ML Later

**Decision:** Start with research-calibrated rules for Garmin sensitivity, upgrade to ML after 50-100 meals.

**Reason:** ML needs training data. The rule-based model provides immediate value from day one using published research on sleep/stress/activity effects. It also serves as a baseline for the ML model to improve upon, and its interpretable weights can be tuned by Claude's recalibration.

### 6. BG-Adaptive Correction via Entry Modification (Before oref)

**Decision:** Adjust future carb entries BEFORE oref runs each cycle, rather than sending correction boluses or running after oref.

**Reason:** Modifying future entries works with oref's existing COB-based decision-making. Running before oref means corrections are visible in the same cycle (no 5-minute lag). oref's own safety checks (max IOB, max SMB, etc.) still apply to all insulin delivery. This is safer than a parallel correction system.

### 7. Firestore for Garmin Data (Not HealthKit)

**Decision:** Read Garmin data from existing Firestore database rather than Apple HealthKit.

**Reason:** HealthKit only receives a subset of Garmin data (steps, HR samples, sleep duration, workouts). The most important signals for sensitivity — Body Battery, stress scores, HRV status, training load, detailed sleep stages — are Garmin-proprietary and never reach HealthKit. The Firestore database already has all of this via the Garmin Health API, structured and queryable.

### 8. Curve-Driven Split Dosing (Not Full Upfront Bolus)

**Decision:** Use the gamma absorption curve to calculate a safe upfront bolus amount, with remaining carbs delivered via SMBs along the curve.

**Reason:** For mixed meals with fat, a full upfront bolus creates a dangerous hypoglycemia window — insulin acts before fat-delayed carbs absorb. The gamma curve tells us exactly how much absorption occurs in the insulin action window, so we can match insulin delivery to actual absorption timing. This eliminates the "bolus-then-crash-then-rebound" pattern that plagues high-fat meals.

### 9. Sensitivity Factor Scales Entry Amounts (Not CR/ISF)

**Decision:** Apply the Garmin sensitivity factor by scaling all entry amounts rather than modifying CR/ISF values.

**Reason:** oref reads CR/ISF from the pump profile, which we cannot easily change on the fly. Scaling entry amounts achieves the same insulin effect: a sensitivity factor of 0.78 causes 65g eaten to appear as 83g of entries, producing 28% more insulin delivery. Fat/protein entries are already "fake carbs," so scaling them is natural. The UI displays both values for transparency: "65g eaten -> 83g effective."

### 10. Meal-Mode SMB Enhancement with Safety Gates

**Decision:** Temporarily raise maxSMB during active meal absorption with strict safety gates that can individually and instantly disable the enhancement.

**Reason:** Split dosing puts most insulin delivery into SMBs. If maxSMB is too low, SMBs can't keep pace with absorption, defeating the purpose. The enhancement is gated by BG floor, BG trend, CGM freshness, and active meal presence — all four must pass independently. If any gate fails, maxSMB instantly reverts. maxIOB is NEVER changed, maintaining the ultimate safety ceiling.

### 11. Smooth Ramps Instead of Hard Cutoffs

**Decision:** Use linear ramps for protein effect (15-40g) and fat effect (0-20g) instead of hard thresholds (28g protein, 10g fat).

**Reason:** Research thresholds (like the 28g protein threshold) reflect statistical significance in studies, not physiological cliffs. A meal with 27g protein has nearly the same gluconeogenic effect as one with 28g. Smooth ramps eliminate discontinuities that could cause surprising jumps in insulin delivery for small changes in meal composition. The ramp endpoints are learnable via outcome calibration.

### 12. Normalized Gaussian for Fat (Not Peak Coefficient)

**Decision:** Use a normalized Gaussian with total coefficient 0.69 g-carb-equiv per g-fat, NOT a peak coefficient of 0.15.

**Reason:** The original plan's peak coefficient of 0.15 produces a 3.2x overdose when integrated across the Gaussian. The correct approach uses 0.69 as the total carb-equivalent per gram of fat (derived from Wolpert: 35g fat = 24g additional carb-equivalent), then distributes this total across a normalized Gaussian that sums to exactly the intended amount regardless of interval spacing. This matches Wolpert's measured 40% additional insulin need.

---

## Safety Philosophy

### Core Principle: The Loop Is the Safety Net

oref has 10+ years of safety engineering. It enforces max IOB, max SMB, max basal, and dynamically adjusts based on BG trends. All insulin delivery goes through oref. We NEVER bypass it.

### Core Principle: Insulin Must Match Absorption Timing

The split dosing strategy ensures insulin delivery is temporally aligned with carb absorption. No insulin is delivered for carbs that haven't arrived yet. This eliminates the dangerous hypoglycemia window that exists when a full bolus is given for a fat-delayed meal.

### What We Control

We control the **inputs** to oref: the carb entries and the maxSMB parameter. Better inputs -> better decisions. But even if our inputs are wrong, oref's deviation-based model self-corrects — it compares actual BG to expected impact and adjusts.

### Double-Dose Prevention

| Scenario | Protection |
|----------|-----------|
| Engine creates entries + user manually enters carbs | mealID tagging, duplicate detection, clear "do NOT enter manually" messaging |
| User doses via banner, then doses again | DosingState tracking per meal, warning dialog before second dose |
| Multiple Cronometer writes for same meal | 15-min grouping window, entry replacement (not addition) for same mealID |

### Safety Constraints (Summary)

| Constraint | Enforcement |
|-----------|-------------|
| Never exceed oref's max IOB | oref enforces this regardless of our entries or maxSMB changes |
| Never exceed oref's max SMB (base) | oref enforces this; meal-mode only raises the ceiling temporarily with safety gates |
| Meal-mode SMB requires all 4 gates | MealModeState evaluated independently each cycle; instant revert on any gate failure |
| BG-adaptive scaling capped at +/-50% per cycle | MacroAdaptiveService |
| Cumulative adjustment capped at +/-100% | MacroAdaptiveService |
| No entry increases when BG < 80 | MacroAdaptiveService |
| No SMB enhancement when BG < 90 (configurable) | MealModeState BG floor gate |
| No SMB enhancement on falling BG | MealModeState trend gate |
| No adaptation on stale CGM data (>15 min) | MacroAdaptiveService |
| No SMB enhancement on stale CGM (>10 min) | MealModeState freshness gate |
| Sensitivity factor clamped to 0.60-1.40 | GarminSensitivityModel |
| Protein effect smooth ramp (no cliff) | MacroAbsorptionEngine |
| Fat coefficient normalized (prevents overdose) | MacroAbsorptionEngine |
| Double-dose detection and warning | MacrosOnBoardTracker |
| All entries tagged with unique mealID | MacroAbsorptionEngine |
| All entries use standard CarbEntryStored format | Compatibility with existing safeguards |
| Split dosing: upfront only covers near-term absorption | MacroAbsorptionEngine gamma CDF calculation |

### Failure Modes

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Garmin data unavailable | sensitivityFactor defaults to 1.0 | Graceful fallback; entries at baseline amounts |
| Firestore query fails | Use V1 flat-factor approach | Fallback to existing system |
| Curve parameters wildly wrong | oref's deviation model self-corrects | BG-adaptive layer also corrects |
| BG-adaptive oscillates | 15-min dampening + +/-50% cap | Built-in stability |
| Meal-mode SMB gate fails | maxSMB instantly reverts to user's base value | No enhanced insulin during unsafe conditions |
| All V2 systems fail | oref runs normally with flat entries | Degrades to current FPU behavior |
| Double entry detection false positive | Meal entries not created; user can manually override | Better to under-dose than double-dose |
| Double entry detection false negative | Possible double-dosing | mitigated by maxIOB cap in oref |

---

## Relationship to V1

V2 builds on V1's infrastructure — it does NOT replace it. The V1 components remain:

| V1 Component | Status in V2 |
|-------------|-------------|
| Snapshot delta system | **Kept** — foundation of meal detection |
| 15-min meal grouping | **Kept** — groups multi-item entries; also used for merge logic |
| Personal adjustment factor | **Replaced** by three-curve engine + sensitivity model |
| Factor lock / ICR tagging | **Kept** — applies to new curve parameters too |
| CronometerMealRecommendation | **Extended** with curve params + Garmin context + split dosing info |
| Outcome backfill | **Extended** with per-curve error analysis |
| Late dosing / meal picker | **Kept** — still useful for forgotten doses |
| Crono button / recommendation view | **Enhanced** with split dosing display + sensitivity info + sliders |

The V1 document (`CRONOMETER_INTEGRATION_AND_AUTO_DOSING_VISION.md`) remains the reference for Phases 1-5b. This V2 document covers the next generation.
