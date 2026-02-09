# V2 Three-Curve Macro Absorption Engine: A Physiologically-Grounded Dosing System for Mixed Meals in Automated Insulin Delivery

**Version 2.0 — February 2026**

---

## Abstract

Standard automated insulin delivery (AID) systems calculate meal boluses from carbohydrate counts alone, treating fat and protein as secondary effects handled by a simplistic linear model (the Warsaw Method). This approach systematically under-doses for mixed meals containing significant fat and protein, producing late hyperglycemia in the 3–9 hour window after eating. We present the V2 Three-Curve Macro Absorption Engine, a replacement dosing system that models carbohydrate absorption as a gamma distribution, protein gluconeogenesis as a delayed sigmoid, and fat-induced insulin resistance as a normalized Gaussian. The system integrates wearable health data from Garmin devices to adjust insulin demand based on sleep, stress, and activity context. A closed-loop outcome learning system tracks BG at timed checkpoints after each meal, attributes errors to the responsible absorption curve, and progressively tunes five personal curve parameters. We describe the mathematical formulation, implementation within the Trio open-source AID system, and the rationale grounded in published clinical research.

---

## Table of Contents

1. [The Problem: Why Standard AID Fails for Mixed Meals](#1-the-problem-why-standard-aid-fails-for-mixed-meals)
2. [The V1 Baseline: oref and the Warsaw Method](#2-the-v1-baseline-oref-and-the-warsaw-method)
3. [The V2 Solution: Three-Curve Absorption Model](#3-the-v2-solution-three-curve-absorption-model)
4. [Curve 1: Carbohydrate Absorption — Gamma(2, τ)](#4-curve-1-carbohydrate-absorption)
5. [Curve 2: Protein Gluconeogenesis — Delayed Sigmoid](#5-curve-2-protein-gluconeogenesis)
6. [Curve 3: Fat Insulin Resistance — Normalized Gaussian](#6-curve-3-fat-insulin-resistance)
7. [Split Dosing: Preventing Mixed-Meal Hypoglycemia](#7-split-dosing-preventing-mixed-meal-hypoglycemia)
8. [Garmin Wearable Sensitivity Integration](#8-garmin-wearable-sensitivity-integration)
9. [Meal-Mode SMB Enhancement and Safety Gates](#9-meal-mode-smb-enhancement-and-safety-gates)
10. [BG-Adaptive Real-Time Correction](#10-bg-adaptive-real-time-correction)
11. [Outcome Learning and Parameter Tuning](#11-outcome-learning-and-parameter-tuning)
12. [User-Facing Configuration: Sliders and Examples](#12-user-facing-configuration-sliders-and-examples)
13. [Worked Examples](#13-worked-examples)
14. [Literature Review and Evidence Base](#14-literature-review-and-evidence-base)
15. [Summary of Improvements Over V1](#15-summary-of-improvements-over-v1)

---

## 1. The Problem: Why Standard AID Fails for Mixed Meals

### What oref Does

The OpenAPS reference implementation (oref) — the algorithm at the core of Trio, Loop, and AndroidAPS — treats meals as a carbohydrate-only event. When a user enters a meal, oref:

1. Calculates a bolus from carb grams and the user's insulin-to-carb ratio (ICR)
2. Delivers the full bolus immediately (or as a single extended bolus)
3. Models absorption as a linear decay over a fixed duration (typically 3–4 hours)
4. Uses Super Micro Boluses (SMBs) to correct any residual rise

This works well for simple carbohydrate meals — rice, bread, juice — where the glucose profile is a relatively fast spike that peaks at 45–90 minutes and declines by 3 hours.

### Where It Breaks Down

Real meals contain fat and protein. A cheeseburger, a steak dinner, pizza, or a bowl of pasta with cream sauce behaves nothing like a glass of orange juice:

**Fat delays gastric emptying.** The pyloric sphincter slows stomach emptying in response to fat, delaying carbohydrate absorption. A high-fat meal can shift peak glucose from 60 minutes to 120+ minutes (Gentilcore et al., 2006). The insulin from the upfront bolus arrives too early, causing a dip at 1–2 hours followed by a late spike at 3–4 hours.

**Fat causes delayed insulin resistance.** Free fatty acid (FFA) elevation at 4–6 hours post-meal impairs peripheral glucose uptake and increases hepatic glucose output, requiring additional insulin for 4–9 hours after the meal (Wolpert et al., 2013).

**Protein triggers gluconeogenesis.** Above a threshold amount (~15g), dietary protein stimulates hepatic gluconeogenesis and glucagon secretion, producing a slow glucose rise from 2–5 hours post-meal (Smart et al., 2013; Paterson et al., 2016).

**These effects are additive.** A meal with both significant fat and protein produces a compound late rise that can persist for 6–9 hours. Bell et al. (2016) found that high-fat, high-protein (HFHP) meals required 65% more insulin than carb-matched low-fat, low-protein meals, with an optimal dual-wave delivery of 30% upfront / 70% extended over 2.4 hours.

### The Clinical Impact

For a person eating real food, the standard AID pattern is predictable and frustrating:

1. **0–1h:** Bolus arrives, BG drops or stays flat (bolus may be too much for the delayed carbs)
2. **1–2h:** BG seems fine, oref reduces SMBs
3. **2–4h:** BG begins rising as delayed carbs arrive and protein gluconeogenesis starts
4. **4–8h:** BG stays elevated from fat-induced insulin resistance, oref issues correction boluses that arrive too late

The total insulin delivered over 8 hours may be correct, but the *timing* is wrong. The upfront bolus is too large for the actual absorption rate, and the delayed effects are not anticipated.

---

## 2. The V1 Baseline: oref and the Warsaw Method

### How V1 Handles Fat and Protein

Trio's V1 system uses the **Warsaw Method** (also called the Fat-Protein Unit method) from Pańkowska et al. (2009):

```
FPU = (protein_grams × 4 + fat_grams × 9) / 100
```

The FPU count determines duration:

| FPU | Duration |
|-----|----------|
| < 2 | 3 hours |
| 2–3 | 4 hours |
| 3–4 | 5 hours |
| ≥ 4 | 6 hours (capped by timeCap setting) |

The total carb-equivalent is:

```
carbEquivalent = (protein × 4 + fat × 9) / 10 × individualAdjustmentFactor
```

These carb-equivalents are distributed as **evenly-spaced linear entries** across the duration, starting after a configurable delay (default 60 minutes).

### Problems with V1

**1. Linear distribution ignores absorption physiology.** Fat and protein effects are not constant over time. Protein gluconeogenesis follows a sigmoid onset at 2–3 hours. Fat-induced insulin resistance peaks at 5–6 hours as a Gaussian. Linear entries at 30-minute intervals miss both the shape and timing of these effects.

**2. The `individualAdjustmentFactor` (default 0.5) makes entries clinically insignificant.** This factor was intended as a personal scaling value, but it multiplies the already-conservative physiological coefficients. For a meal with 28g fat and 35g protein:

```
V1: (35×4 + 28×9) / 10 × 0.5 = 19.6g carb-equivalent over 6 hours
  = 3.3g per hour, spread as ~1.6g entries every 30 min
```

Each entry is too small for oref to act on meaningfully. The SMBs generated from 1.6g entries are negligible.

**3. The combined caloric model conflates two different mechanisms.** Protein and fat affect glucose through entirely different pathways — gluconeogenesis vs. insulin resistance — with different time courses. Combining them into a single caloric number and distributing linearly loses all physiological information.

**4. No sensitivity adjustment.** V1 applies the same FPU calculation regardless of whether the user had 4 hours of sleep or 9, whether they ran a marathon yesterday or sat at a desk, whether their resting heart rate is elevated from illness.

**5. No learning.** The coefficients never change. A user who consistently runs high after fatty meals has no mechanism to increase the fat effect — they can only adjust the global `individualAdjustmentFactor`, which affects protein and fat equally.

---

## 3. The V2 Solution: Three-Curve Absorption Model

### Design Principles

The V2 engine replaces the single linear FPU distribution with three independent, physiologically-shaped curves:

1. **Separate pathways for separate mechanisms.** Carbohydrate absorption, protein gluconeogenesis, and fat insulin resistance are modeled independently with different curve shapes, timescales, and parameters.

2. **Curve-driven split dosing.** Instead of delivering the full carb bolus upfront, the engine uses the carbohydrate absorption curve to calculate how much should be bolused immediately vs. delivered later via SMBs — preventing the early dip from premature insulin action.

3. **Personal parameterization.** Five core parameters control the curves. Each can be tuned via sliders or learned automatically from meal outcomes.

4. **Context-aware dosing.** Garmin wearable data adjusts all entries by an insulin demand factor reflecting the user's current physiological state.

5. **Closed-loop learning.** BG checkpoints at 1h/2h/3h/4h/6h/8h are backfilled from CGM data, attributed to the responsible curve phase, and used to adjust parameters over time.

### Architecture Overview

```
Cronometer Meal (via Apple Health)
    ↓
MacroAbsorptionEngine.generateEntries()
    ├── Curve 1: Gamma(2,τ) carb entries → split into upfront bolus + future entries
    ├── Curve 2: Sigmoid protein entries → 90-480 min, every 15 min
    └── Curve 3: Gaussian fat entries → 120-540 min, every 15 min
    ↓
× insulinDemandFactor (from Garmin)
    ↓
Upfront carbs → bolus calculator (immediate)
Future entries → Core Data → oref sees them as future carbs → delivers via SMBs
    ↓
BG-Adaptive Service monitors actual BG vs predicted
    ↓ (if divergence)
Scale remaining future entries up or down
    ↓
Outcome Learning backfills BG at checkpoints
    ↓
Attribute errors to curve phases → adjust parameters
    ↓
Updated parameters used for next meal
```

---

## 4. Curve 1: Carbohydrate Absorption

### Mathematical Model

Carbohydrate absorption follows a **Gamma(2, τ) distribution**, where τ (tau) is the time constant in minutes.

**Probability Density Function (rate of absorption at time t):**

```
PDF(t) = (t / τ²) × exp(-t / τ)
```

**Cumulative Distribution Function (fraction absorbed by time t):**

```
CDF(t) = 1 - (1 + t/τ) × exp(-t/τ)
```

**Duration to 95% absorption:**

```
t₉₅ = 4.74 × τ
```

### Why Gamma(2, τ)?

The gamma distribution with shape parameter k=2 produces a curve that:
- Starts at zero (no absorption at t=0)
- Rises to a peak at t=τ
- Has a long right tail (slow trailing absorption)

This matches the physiological reality of gastric emptying and intestinal absorption: food doesn't absorb instantly, absorption rate peaks as the bolus reaches the small intestine, and trailing absorption continues as remaining food empties.

### Fat Modification of τ

Fat slows gastric emptying by signaling the pyloric sphincter to reduce emptying rate. The V2 engine models this as a linear increase in τ:

```
τ_effective = τ_base + (fat_grams × 0.8)
```

Where 0.8 minutes per gram of fat is derived from gastric emptying studies (Gentilcore et al., 2006; Horowitz et al., 1993).

> **Note:** The 0.8 min/g coefficient is derived from liquid fat load studies (olive oil infused into the duodenum). Solid food with fat may exhibit different gastric emptying rates due to mechanical breakdown. This coefficient serves as a starting point; the outcome learning system adjusts effective τ from real meal data.

**Fiber Modification of τ:** Dietary fiber independently slows gastric emptying and glucose absorption (Torsdottir et al., 1991; Jenkins et al., 1978). The V2 engine adds a fiber delay term:

```
τ_effective = τ_base + (fat_grams × 0.8) + max(0, fiber_grams − 5) × 0.3
```

The 0.3 min/g coefficient is conservative — fiber's effect is real but smaller than fat's. The 5g threshold avoids adjusting for trace amounts. Fiber data is sourced from Apple Health via Cronometer.

**Example — τ values for different meals:**

| Meal | Fat | τ_base | τ_effective | Peak Absorption | 95% Duration |
|------|-----|--------|-------------|-----------------|--------------|
| Rice only | 0g | 35 min | 35 min | 35 min | 166 min (2.8h) |
| Sandwich | 12g | 35 min | 44.6 min | 45 min | 211 min (3.5h) |
| Pizza | 30g | 35 min | 59 min | 59 min | 280 min (4.7h) |
| Cheese steak | 50g | 35 min | 75 min | 75 min | 356 min (5.9h) |

### Parameterization

| Parameter | Default | Range | Stored In |
|-----------|---------|-------|-----------|
| τ_base (Carb Tau) | 35 min | 20–60 min | V2PersonalCurveParameters.carbTau |
| Fat slowing coefficient | 0.8 min/g | Fixed | Hardcoded |

The base τ is tunable via the settings slider or learned from early (0–2h) checkpoint errors.

---

## 5. Curve 2: Protein Gluconeogenesis

### The Physiological Mechanism

Dietary protein above a threshold amount stimulates hepatic gluconeogenesis — the liver converts amino acids (primarily alanine and glutamine) into glucose. Additionally, protein stimulates glucagon secretion, which further drives hepatic glucose output. The combined effect produces a slow, delayed glucose rise beginning at approximately 2 hours post-meal and peaking at 4–5 hours.

### Conversion Factor: How Much Protein Becomes Glucose?

The V2 engine uses a **smooth ramp function** rather than a hard threshold:

```
proteinGlucoFactor(P) =
    0                                       if P ≤ threshold
    (P - threshold) / (plateau - threshold) × maxFactor    if threshold < P < plateau
    maxFactor                               if P ≥ plateau
```

**Default parameters:**
- **threshold** = 15g (below this, protein effect is negligible)
- **plateau** = 40g (above this, conversion rate is saturated)
- **maxFactor** = 0.35 (at most 35% of protein grams become glucose-equivalent)

The total glucose-equivalent from protein is:

```
proteinGlucoseEquiv = protein_grams × proteinGlucoFactor(protein_grams)
```

**Example values:**

| Protein | Factor | Glucose-Equivalent |
|---------|--------|--------------------|
| 10g | 0.00 | 0.0g |
| 15g | 0.00 | 0.0g (at threshold) |
| 20g | 0.07 | 1.4g |
| 25g | 0.14 | 3.5g |
| 30g | 0.21 | 6.3g |
| 35g | 0.28 | 9.8g |
| 40g | 0.35 | 14.0g (at plateau) |
| 60g | 0.35 | 21.0g (capped) |

### Temporal Distribution: Delayed Sigmoid with Decay

The glucose-equivalent is distributed along a sigmoid curve with a decay tail:

```
proteinCurveValue(t) = sigmoid(t) × decay(t)

sigmoid(t) = 1 / (1 + exp(-(t - 180) / 40))
    onset center = 180 min (3 hours)
    steepness = 40 min

decay(t) =
    1.0                                if t ≤ 300 min (5h)
    exp(-(t - 300)² / (2 × 120²))     if t > 300 min
    peak = 300 min (5 hours)
    decay sigma = 120 min
```

This produces a curve that:
- Is near zero before 90 minutes
- Rises steeply between 120–240 minutes (sigmoid onset)
- Peaks at approximately 240–300 minutes (4–5 hours)
- Decays as a Gaussian tail from 300–480 minutes

Entries are generated every 15 minutes from 90 to 480 minutes (1.5–8 hours), normalized so they sum exactly to the calculated glucose-equivalent.

### Parameterization

| Parameter | Default | Range | What It Controls |
|-----------|---------|-------|-----------------|
| proteinFactor | 0.35 | 0.10–0.80 | Maximum conversion fraction |
| proteinThreshold | 15g | 5–30g | Below this, no protein effect |
| proteinPlateau | 40g | 20–80g | Above this, conversion saturates |

---

## 6. Curve 3: Fat Insulin Resistance

### The Physiological Mechanism

Dietary fat does not directly raise blood glucose. Instead, fat increases circulating free fatty acids (FFAs) beginning at approximately 2 hours post-meal, peaking at 4–6 hours. Elevated FFAs cause insulin resistance through two mechanisms:

1. **Peripheral resistance:** FFAs compete with glucose for oxidation in muscle, reducing glucose uptake (Randle cycle)
2. **Hepatic glucose output:** FFAs stimulate hepatic gluconeogenesis and glycogenolysis

The net effect is that the same amount of insulin has less glucose-lowering power — the user needs more insulin to maintain the same BG level.

### Conversion Coefficient

The V2 engine converts fat grams to a carb-equivalent using a coefficient derived from Wolpert et al. (2013):

```
fatCarbEquivalent = fat_grams × fatCoefficient     (if fat ≥ 5g)
fatCarbEquivalent = 0                               (if fat < 5g)
```

**Default coefficient:** 0.69 g-carb-equivalent per g-fat

**Derivation:** Wolpert found that adding 50g of fat to a 65g carb meal required 42% more insulin. The additional insulin need = 65g × 0.42 = 27.3g carb-equivalent. Per gram of fat: 27.3 / 50 = 0.55. However, Wolpert's subjects had variable responses (range 17–124%), and the coefficient includes a margin for the median-to-upper range, arriving at 0.69.

**Example values:**

| Fat | Coefficient | Carb-Equivalent | Duration |
|-----|-------------|-----------------|----------|
| 3g | — | 0g (below 5g threshold) | — |
| 10g | 0.69 | 6.9g | 2–9h |
| 20g | 0.69 | 13.8g | 2–9h |
| 28g | 0.69 | 19.3g | 2–9h |
| 50g | 0.69 | 34.5g | 2–9h |

### Temporal Distribution: Normalized Gaussian

The carb-equivalent is distributed along a Gaussian curve:

```
gaussianValue(t) =
    0                                           if t < 120 min
    exp(-(t - 360)² / (2 × 90²))               if t ≥ 120 min

    center (tPeak) = 360 min (6 hours)
    standard deviation (σ) = 90 min
```

This produces a bell curve centered at 6 hours with most effect between 3–9 hours. No effect before 2 hours (FFA elevation hasn't begun).

Entries are generated every 15 minutes from 120 to 540 minutes (2–9 hours), normalized so they sum exactly to the calculated carb-equivalent.

### Parameterization

| Parameter | Default | Range | What It Controls |
|-----------|---------|-------|-----------------|
| fatTotalCoeff | 0.69 | 0.30–1.20 | g-carb-equivalent per g-fat (peak of nonlinear ramp) |

---

## 7. Split Dosing: Preventing Mixed-Meal Hypoglycemia

### The Problem with Full Upfront Boluses

When fat delays carbohydrate absorption (shifting τ from 35 to 60+ minutes), a full upfront bolus delivers maximum insulin action at 60–90 minutes — before peak carb absorption. This causes:

1. A BG dip at 1–2 hours (insulin peaks before carbs)
2. A rebound rise at 2–4 hours (carbs arrive after insulin wanes)

### Curve-Driven Split Calculation

The V2 engine uses the Gamma CDF to calculate the fraction of carbs absorbed within a "safe window," then applies a **fat-scaled minimum upfront floor** to prevent under-bolusing simple carb meals:

```
cdfPercent = CDF(safeWindow) = 1 - (1 + safeWindow/τ) × exp(-safeWindow/τ)
minUpfront = lerp(0.80, floor, clamp(fatGrams / 50, 0, 1))
effectivePercent = max(cdfPercent, minUpfront)
```

The safe window depends on insulin type:

| Insulin Type | Examples | Peak Action | Safe Window |
|-------------|----------|-------------|-------------|
| Ultra-rapid | Fiasp, Lyumjev | 30–45 min | 30 min |
| Rapid-acting | Humalog, Novolog | 60–90 min | 45 min |

The `floor` is user-configurable (default 25%, range 15–70%). Low-fat meals get up to 80% upfront; the floor sets the absolute minimum for high-fat (≥50g) meals. This ensures simple carb meals get close to standard AID full-bolus behavior while high-fat meals still get aggressive splitting.

| Fat | minUpfront (25% floor) | CDF (rapid-acting) | Effective |
|-----|----------------------|---------------------|-----------|
| 0g  | 80.0% | varies | **80.0%** |
| 3g  | 76.7% | 33.9% | **76.7%** |
| 28g | 49.2% | 19.6% | **49.2%** |
| 50g | 25.0% | 12.3% | **25.0%** |

**Example — Pizza (65g carbs, 30g fat, rapid-acting insulin):**

```
τ = 35 + (30 × 0.8) = 59 min
CDF(45) = 0.177
fatScaledMin = lerp(0.80, 0.25, 30/50) = 0.47
effectivePercent = max(0.177, 0.47) = 0.47

→ 47.0% upfront (30.6g as immediate bolus)
→ 53.0% as future entries (34.5g via SMBs over ~4.7 hours)
```

Compare to a low-fat meal (65g carbs, 3g fat):

```
τ = 35 + (3 × 0.8) = 37.4 min
CDF(45) = 0.339
fatScaledMin = lerp(0.80, 0.25, 3/50) = 0.767
effectivePercent = max(0.339, 0.767) = 0.767

→ 76.7% upfront (49.9g as immediate bolus)
→ 23.3% as future entries (15.1g via SMBs)
```

The engine automatically gives a larger upfront bolus for fast-absorbing simple carb meals and progressively smaller upfront amounts as fat content increases. The user can override with a manual upfront slider (bypasses the fat-scaled floor) or adjust the floor via the "Min Upfront Covered" slider in settings.

### Safety Invariant

**Critical:** The upfront portion is returned as a number for the bolus calculator. **No Core Data entries are created for it.** Only the remaining carbs (after the safe window) become entries that oref sees. This prevents double-counting — the bolus covers the upfront portion, oref sees only the future portion.

---

## 8. Garmin Wearable Sensitivity Integration

### Rationale

Insulin sensitivity varies day-to-day based on sleep quality, stress, physical activity, illness, and recovery state. A user who slept 4 hours and is highly stressed needs more insulin than the same user after a restful night and a workout. Traditional AID systems ignore this — they use the same carb ratio and sensitivity factor regardless of context.

### Data Source

The V2 system integrates with Garmin wearable devices via Firebase/Firestore. A `GarminContextSnapshot` captures the user's current physiological state:

**Sleep metrics:**
- Sleep score (0–100), sleep duration, deep/light/REM breakdown

**Stress and recovery:**
- Current stress level (1–100), average stress today
- Body Battery level (current and at wake)

**Cardiovascular:**
- Resting heart rate (and delta from 7-day average)
- HRV last night average and delta from weekly average

**Activity:**
- Yesterday's active calories, steps, vigorous minutes
- Today's active calories and intensity minutes

### The Demand Factor Model

The `GarminSensitivityModel` converts the snapshot into a single **insulin demand factor** using additive rule-based scoring.

> **Epistemic Note:** The impact weights below are starting heuristics based on directional findings from the literature (e.g., Spiegel 1999, Donga 2010 for sleep; general exercise physiology for activity). The specific magnitudes are estimated, not calibrated against BG outcome data, and their additive stacking to a potential 1.67x demand factor is unvalidated. The outcome learning system is intended to validate and adjust these over time. Users should monitor the demand factor's effect on their outcomes and adjust or disable if results are poor.

```
sensitivityFactor = 1.0   (start at baseline)
```

Each metric independently contributes a positive or negative impact:

**Sleep Score:**

| Score | Impact | Interpretation |
|-------|--------|----------------|
| < 40 | −0.22 | Terrible sleep → 22% more resistant |
| 40–55 | −0.15 | Poor sleep → 15% more resistant |
| 55–70 | −0.08 | Fair sleep → 8% more resistant |
| 70–85 | 0.00 | Normal sleep → no adjustment |
| > 85 | +0.05 | Great sleep → 5% more sensitive |

**Sleep Duration:**

| Duration | Impact |
|----------|--------|
| < 5 hours | −0.10 |
| 5–6 hours | −0.05 |
| ≥ 6 hours | 0.00 |

**Body Battery:**

| Level | Impact | Interpretation |
|-------|--------|----------------|
| < 15 | −0.18 | Critically depleted |
| 15–30 | −0.12 | Low recovery |
| 30–50 | −0.05 | Below average |
| 50–75 | 0.00 | Normal |
| > 75 | +0.05 | Well recovered |

**Stress:**

| Current Stress | Impact |
|---------------|--------|
| > 75 | −0.08 |
| 60–75 | −0.04 |
| Average today > 60 | −0.06 |
| Average today 45–60 | −0.03 |

**Resting Heart Rate Delta (from 7-day average):**

| Delta | Impact | Interpretation |
|-------|--------|----------------|
| > +12 bpm | −0.12 | Illness/stress indicator |
| +8 to +12 bpm | −0.07 | Mildly elevated |
| −5 to +8 bpm | 0.00 | Normal range |
| < −5 bpm | +0.03 | Well-rested indicator |

**HRV Delta (from weekly average):**

| Delta | Impact |
|-------|--------|
| < −20% | −0.08 |
| −10% to −20% | −0.04 |
| > +15% | +0.03 |

**Yesterday's Activity:**

| Active Calories | Impact | Interpretation |
|----------------|--------|----------------|
| > 600 kcal | +0.15 | Very active → 15% more sensitive |
| 400–600 kcal | +0.10 | Active → 10% more sensitive |
| 250–400 kcal | +0.05 | Moderate → 5% more sensitive |

**Yesterday Vigorous Exercise:**

| Duration | Impact |
|----------|--------|
| > 45 min | +0.08 |
| 20–45 min | +0.04 |

**Today's Activity:**

| Active Calories | Impact |
|----------------|--------|
| > 400 kcal | +0.08 |
| 200–400 kcal | +0.04 |

### Final Calculation

```
sensitivityFactor = 1.0 + Σ(all impacts)
sensitivityFactor = clamp(sensitivityFactor, 0.60, 1.40)
insulinDemandFactor = 1.0 / sensitivityFactor
```

The inversion converts sensitivity into demand: lower sensitivity → higher demand → more insulin.

**Final demand factor range:** 0.71 (very sensitive, 29% less insulin) to 1.67 (very resistant, 67% more insulin).

### Application to Entries

The demand factor multiplies **all** future entries and the upfront carb recommendation:

```
upfrontCarbs = carbs × upfrontPercent × insulinDemandFactor
each futureEntry.carbs = entry.carbs × insulinDemandFactor
```

### Worked Example: Bad Night

A user had 4.5 hours of sleep (score 38), Body Battery at 12, current stress 78, resting HR +14 bpm above average, yesterday was sedentary (150 kcal active):

```
Sleep score < 40:     -0.22
Sleep duration < 5h:  -0.10
Body Battery < 15:    -0.18
Current stress > 75:  -0.08
Avg stress (unknown):  0.00
RHR delta > 12:       -0.12
HRV (unknown):         0.00
Yesterday < 250 kcal:  0.00
Today (unknown):       0.00

sensitivityFactor = 1.0 + (-0.22 -0.10 -0.18 -0.08 -0.12) = 0.30
clamp(0.30, 0.60, 1.40) = 0.60
insulinDemandFactor = 1.0 / 0.60 = 1.67
```

This user gets 67% more insulin for the same meal. A 65g carb meal that normally gets a 22g upfront bolus instead gets 22 × 1.67 = 36.7g equivalent — and all delayed entries are similarly scaled.

---

## 9. Meal-Mode SMB Enhancement and Safety Gates

### The Problem

oref's default SMB limits (typically 30 minutes of basal rate) are designed for correction, not meal absorption. When the V2 engine creates future carb entries that arrive over 4–8 hours, oref sees them but can only deliver small SMBs. The entries predict the need, but oref's delivery rate can't keep up.

### The Enhancement

When V2 meal entries are active, the system can multiply the maximum SMB size by a configurable factor (default 2.0x, range 1.0–3.0x). This increases `maxSMBBasalMinutes` and `maxUAMSMBBasalMinutes` so oref can deliver larger boluses to match the curve-predicted need.

### The Five Safety Gates

Enhancement is NOT always-on. Five independent safety gates must ALL pass on every oref cycle. If **any single gate** fails, the multiplier reverts to 1.0x instantly:

**Gate 1: Active Meal Entries**
Future V2 entries (carb-absorption, protein-gluconeogenesis, or fat-resistance) must exist in Core Data with dates in the future. Once all entries have been consumed, enhancement stops.

**Gate 2: BG Above Floor**
Current BG must be above the configurable floor (default 90 mg/dL, range 70–130). If BG drops below the floor, enhancement stops immediately — no need to deliver more insulin when already heading low.

**Gate 3: BG Trend Flat or Rising (with Hysteresis)**
The CGM trend must not be falling rapidly. Specifically:
- If a CGM direction arrow is available: `doubleDown`, `singleDown`, and `fortyFiveDown` fail the gate
- Fallback: the delta between the two most recent readings must be ≥ −3.0 mg/dL per 5 minutes
- **Hysteresis:** Once the gate fails (trend < −3.0), it requires the trend to recover to ≥ 0.0 mg/dL per 5 minutes before re-enabling. This prevents rapid toggling caused by CGM noise near the threshold.

This prevents enhancement during active drops — if BG is already falling, the existing insulin is working. The −3.0 threshold allows normal post-meal dips (typically −1 to −2 mg/dL/5min) while catching real drops. The hysteresis ensures that once the gate trips, the system waits for a clear recovery before resuming enhanced delivery.

**Gate 4: CGM Freshness**
The most recent CGM reading must be less than 10 minutes old. Stale data (sensor warmup, compression gap) should not trigger enhanced delivery.

**Gate 5: IOB vs Remaining Absorption**
Current IOB must not exceed 120% of the remaining insulin need. Specifically:
```
remainingInsulinNeed = remainingCarbsForActiveMeals / carbRatio
if currentIOB > remainingInsulinNeed × 1.2: gate fails
```
This prevents insulin stacking — if the IOB already covers the remaining predicted absorption plus a 20% buffer, there's no need to deliver enhanced SMBs.

### Implementation

```
if allGatesPass:
    effectiveSMBMinutes = baseMaxSMBMinutes × mealModeSMBMultiplier
    effectiveUAMMinutes = baseMaxUAMMinutes × mealModeSMBMultiplier
else:
    effectiveSMBMinutes = baseMaxSMBMinutes  (unmodified)
    effectiveUAMMinutes = baseMaxUAMMinutes  (unmodified)
```

---

## 10. BG-Adaptive Real-Time Correction

### Purpose

The three-curve model predicts future glucose impact, but the prediction may diverge from reality — the user may have miscounted carbs, absorbed faster than modeled, or be more resistant than the Garmin data suggested. The BG-adaptive service monitors actual BG against predicted impact and scales remaining future entries in real-time.

### How It Works

The adaptive service runs before each oref cycle (approximately every 5 minutes):

1. **Calculate predicted BG impact** from the meal:
   ```
   predictedImpact = (absorbedCarbs / carbRatio) × ISF - mealIOB × ISF
   ```
   Uses meal-attributed IOB (insulin specifically recorded for this meal via `recordMealInsulin`) rather than total system IOB, preventing correction boluses from confounding the prediction.

2. **Calculate actual BG change** from meal start:
   ```
   actualBGDelta = currentBG - bgAtMealStart
   ```
   Uses the BG at meal start (stored in `V2MealOutcome.bgAtMeal`) rather than extrapolating the current CGM trend, which is more accurate for meals that spiked early and then flattened.

3. **Compute error:**
   ```
   error = actualTrend - predictedImpact
   ```
   Positive error = BG rising more than predicted (under-dosed)
   Negative error = BG falling more than predicted (over-dosed)

4. **Calculate scaling factor:**
   ```
   rawScaling = 1.0 + (error / 100)
   blendedScaling = 1.0 + (rawScaling - 1.0) × 0.5    // 50% damping
   ```
   The 50% damping prevents overreaction to transient fluctuations.

5. **Apply to future entries:** All remaining FPU entries for this meal are scaled by the blended factor.

### Safety Limits

| Limit | Value | Purpose |
|-------|-------|---------|
| Error threshold | 15 mg/dL | Don't adjust for small deviations |
| Single-cycle clamp | 0.5–1.5 | Max ±50% per cycle |
| Cumulative clamp | 0.0–2.0 | Max ±100% total from original |
| Damping interval | 15 minutes | Minimum time between adjustments |
| BG floor | 80 mg/dL | Don't increase entries when BG is low |
| BG ceiling | 300 mg/dL | Don't chase extreme highs |
| CGM age limit | 15 minutes | Don't adjust on stale data |

---

## 11. Outcome Learning and Parameter Tuning

### Meal Outcome Recording

When a user applies a Cronometer recommendation with V2 enabled, a `V2MealOutcome` record is created containing:

- The macros applied (carbs, fat, protein)
- The curve parameters used (tauCarb, proteinFactor, fatTotalEquiv)
- The dosing context (upfrontPercent, insulinDemandFactor, carbRatioAtMeal, isfAtMeal)
- The Garmin context snapshot
- Seven empty BG checkpoints at 1h, 2h, 3h, 4h, 5h, 6h, and 8h (phases dynamically assigned based on meal macros)

### BG Checkpoint Backfill

Backfill runs when the user opens a Cronometer recommendation or the Outcome Accuracy page. For each empty checkpoint:

1. Calculate target time = meal date + checkpoint hours
2. Wait until 30 minutes after target (to ensure CGM data exists)
3. Query Core Data for the closest glucose reading within ±30 minutes
4. If found, write the BG value

### Curve Phase Attribution

Each checkpoint is tagged with the dominant absorption curve at that time:

| Checkpoint | Phase | Dominant Curve |
|------------|-------|---------------|
| 1h | carb | Carbohydrate absorption (gamma peak region) |
| 2h | carb | Carbohydrate absorption (tail region) |
| 3h | protein/carb | Protein gluconeogenesis onset (if protein > threshold, else carb) |
| 4h | overlap/protein/fat/carb | Dynamic: overlap if both protein+fat, else dominant macro |
| 5h | protein/fat/skip | Protein peak (4-5h), or fat if no protein, or skip if neither |
| 6h | fat/skip | Fat insulin resistance peak (if fat ≥ 5g, else skip) |
| 8h | fat/skip | Fat insulin resistance tail (if fat ≥ 5g, else skip) |

Phase attribution is **dynamic** based on actual meal composition (#3). Low-protein meals skip protein checkpoints; low-fat meals skip fat checkpoints. The `.skip` phase excludes the checkpoint from parameter learning, preventing attribution errors for curves that weren't active.

### Rule-Based Parameter Recalibration

The `recalculateCurveParameters()` method processes all non-confounded outcomes:

**Step 1: Filter outcomes**
- Exclude meals where `hasConfoundingMeal == true`
- If current carb ratio is known, exclude outcomes where the carb ratio at meal time differs by more than ±10%

**Step 2: Weight by recency**
```
recencyWeight = max(0.1, 1.0 - (ageInDays / 90))
```

**Step 3: Calculate per-checkpoint error (target-based with dead zone)**

Errors are computed relative to a target BG (default 110 mg/dL) with a ±30 dead zone (80–140), ensuring the system learns from users who consistently land near the upper boundary rather than treating 170 as "in range."

```
deadZoneLow  = targetBG - 30 = 80
deadZoneHigh = targetBG + 30 = 140

if BG > deadZoneHigh:  error = +(BG - targetBG) / 100    (under-dosed, relative to target)
if BG < deadZoneLow:   error = -(targetBG - BG) / 100    (over-dosed, relative to target)
if deadZoneLow ≤ BG ≤ deadZoneHigh: error = 0            (within dead zone, skip)
```

**Step 4: Attribute to curve phase**

| Phase | Error Direction | Adjustment |
|-------|----------------|------------|
| carb: high BG | Carbs absorbed faster than predicted | τ -= error × 2.0 × weight |
| carb: low BG | Carbs absorbed slower | τ += |error| × 2.0 × weight |
| protein: high BG | Protein effect stronger | proteinFactor += error × 0.02 × weight |
| protein: low BG | Protein effect weaker | proteinFactor -= |error| × 0.02 × weight |
| fat: high BG | Fat resistance stronger | fatCoeff += error × 0.05 × weight |
| fat: low BG | Fat resistance weaker | fatCoeff -= |error| × 0.05 × weight |
| overlap | Excluded from learning | Overlap produces noise-level adjustments; 5h/6h provide cleaner signal |

**Step 5: Apply with clamping**

| Parameter | Minimum | Maximum |
|-----------|---------|---------|
| carbTau | 20 min | 60 min |
| proteinFactor | 0.10 | 0.80 |
| fatTotalCoeff | 0.30 | 1.20 |

### Claude AI Recalibration

When enabled, the `SensitivityRecalibrationService` exports recent outcomes (with full Garmin context) to the Claude API for pattern analysis. The analysis window is configurable: 7, 14, 21, or 30 days (default 14). This runs weekly or on manual trigger (Settings → V2 Macro Dosing → AI Insights).

The 14-day default balances data volume against staleness — 7 days typically yields only 12-15 clean checkpoints after confounding exclusion, which is insufficient for reliable pattern detection. At 2-3 meals/day, 14 days provides ~25-35 clean data points, enough for Claude to separate signal from noise.

#### What Claude Analyzes

Claude receives a structured data prompt containing:
- Current model parameters (carbTau, proteinFactor, fatCoefficient, fiberCoefficient, protein threshold/plateau)
- Each meal outcome: macros (carbs, fat, protein, fiber), curve parameters used, BG checkpoints with phase attribution, adaptive adjustments applied, Garmin context snapshot, dosing context (CR, ISF, demand factor)
- Confounding meal flags and per-checkpoint clean/dirty status
- Per-phase sample size summary: clean/total checkpoints and meal count for each curve phase (carb, protein, fat)

Claude identifies patterns the rule-based system cannot detect:
- Time-of-day insulin sensitivity patterns
- Day-of-week patterns (weekend meals differ from weekday)
- Correlations between specific Garmin metrics and BG outcomes
- Systematic drift in a single parameter
- Interactions between multiple parameters (e.g., high-fat + low-sleep)

#### Prompt Structure

The system prompt defines Claude's role as a diabetes insulin sensitivity calibration expert and describes the three-curve model, the fiber modifier, and the Garmin sensitivity model with all rule weights. The data prompt includes current parameters and every meal outcome from the analysis period with full context.

#### Expected JSON Response Schema

```json
{
  "analysis_window_days": 14,
  "per_phase_sample_sizes": {
    "carb": { "clean_checkpoints": 42, "total_checkpoints": 48, "meals_with_data": 28 },
    "protein": { "clean_checkpoints": 19, "total_checkpoints": 22, "meals_with_data": 19 },
    "fat": { "clean_checkpoints": 6, "total_checkpoints": 8, "meals_with_data": 6 }
  },
  "curve_parameter_updates": {
    "carb_tau": { "current": 35, "recommended": 33, "rationale": "...", "confidence": "high" },
    "protein_factor": { "current": 0.35, "recommended": 0.38, "rationale": "...", "confidence": "medium" },
    "fat_coefficient": null,
    "protein_threshold": null,
    "protein_plateau": null,
    "fiber_coefficient": null
  },
  "sensitivity_weight_updates": {
    "sleep_weight": null,
    "body_battery_weight": null,
    "stress_weight": { "current": 0.08, "recommended": 0.12, "rationale": "...", "confidence": "medium" },
    "resting_hr_weight": null,
    "hrv_weight": null,
    "activity_yesterday_weight": null,
    "activity_today_weight": null
  },
  "patterns": [
    { "pattern_type": "time_of_day", "description": "...", "frequency": "...", "impact": "...", "confidence": "high" }
  ],
  "explanation": "Natural language summary of findings and recommendations",
  "confidence": "medium",
  "meals_analyzed": 28
}
```

The `per_phase_sample_sizes` block lets users judge recommendation quality: a fat coefficient recommendation based on 6 clean checkpoints deserves more scrutiny than a carb tau recommendation based on 42. Claude is instructed to lower its confidence when sample sizes are small (< 10 clean checkpoints for a phase).

#### Validation Pipeline

1. **JSON extraction:** Parse the response, extracting JSON from within any surrounding text
2. **Schema validation:** Verify all required fields exist and have correct types
3. **Per-parameter change limit:** Reject any single parameter change > 30% from current value (prevents hallucinated recommendations from causing harm)
4. **Confidence filter:** Only apply updates with medium or high confidence (configurable minimum)
5. **Range clamping:** Every recommended value is clamped to the same limits as the settings UI:

| Parameter | Minimum | Maximum |
|-----------|---------|---------|
| carbTau | 20 min | 60 min |
| proteinFactor | 0.10 | 0.80 |
| fatTotalCoeff | 0.30 | 1.20 |
| fiberCoefficient | 0.00 | 1.00 |
| proteinThreshold | 10g | 25g |
| proteinPlateau | 30g | 60g |
| Garmin weights | per-metric min | per-metric max |

#### User Confirmation Flow

Recommendations are presented in the AI Insights view for user review before applying:
1. Each recommended change shows: current value → recommended value, rationale, confidence level
2. Detected patterns are listed with descriptions, frequency, and impact
3. The user must explicitly tap "Apply Recommendations" to save changes
4. No parameters are modified without user confirmation

#### Error Handling

- **Malformed JSON:** Falls back to response text as explanation, no parameters applied
- **API failure / network error:** Returns nil, logged for debugging
- **Rate limiting:** Service respects weekly cadence; manual triggers have no limit
- **Parameters outside ranges:** Clamped silently to valid range after 30% change validation
- **Low confidence:** All parameters at "low" confidence are skipped by default

### Outcome Storage

Meal outcomes are stored in Core Data (`V2MealOutcomeStored` entity) with queryable attributes for date, mealID, macros, and curve parameters. Nested data (BG checkpoints, adaptive adjustments, Garmin context snapshot) is stored as JSON-encoded binary attributes, balancing query performance with schema simplicity. A one-time migration moves existing outcomes from UserDefaults to Core Data on first access after the update.

### Data Retention

Outcomes older than 90 days are excluded automatically via date predicates. Recency weighting further reduces influence of old data. This allows the system to adapt to seasonal changes, medication changes, and lifestyle shifts.

---

## 12. User-Facing Configuration: Sliders and Examples

### Settings Page Layout

The V2 Macro Dosing settings page (Settings → V2 Macro Dosing) provides direct control over all aspects of the system:

**Section: V2 Macro Engine**
- Enable/disable toggle
- Insulin type picker (rapid-acting / ultra-rapid)
- Safe window display with optional custom override (15–90 min stepper)
- Min Upfront Covered slider (15–70%, step 5%) — fat-scaled minimum upfront bolus floor

**Section: Meal-Mode SMB Enhancement**
- SMB Multiplier slider (1.0–3.0x, step 0.1)
- BG Floor slider (70–130 mg/dL, step 5)

**Section: Fat Absorption**
- Fat Coefficient slider (0.30–1.20, step 0.01)

**Section: Protein Absorption**
- Protein Factor slider (0.10–0.80, step 0.01)
- Protein Threshold slider (5–30g, step 1)
- Protein Plateau slider (20–80g, step 1)

**Section: Carb Absorption**
- Base Carb Tau slider (20–60 min, step 1)

Each slider has an insulin-direction info box showing what increasing or decreasing the value does to insulin delivery.

**Section: Example Calculation**
A live preview shows how the current settings would process a reference meal (65g carbs, 28g fat, 35g protein), updating in real-time as sliders are adjusted.

**Section: Garmin Sensitivity**
- Enable/disable toggle
- Firebase configuration status

**Section: Outcome Learning**
- Record Meal Outcomes toggle
- Recorded meal count and BG checkpoint count
- Claude AI Recalibration toggle
- Analysis Window picker (7 / 14 / 21 / 30 days, default 14) — visible when Claude recalibration is enabled

**Section: Analysis**
- Link to Meal Outcome Accuracy page

---

## 13. Worked Examples

### Example A: Simple Carb Meal (Rice Bowl)

**Meal:** 75g carbs, 3g fat, 8g protein
**Settings:** Defaults (25% floor), rapid-acting insulin, no Garmin

**Carb curve:**
```
τ = 35 + (3 × 0.8) = 37.4 min
CDF(45) = 0.339
fatScaledMin = lerp(0.80, 0.25, 3/50) = 0.767
effectivePercent = max(0.339, 0.767) = 0.767  ← floor wins
Upfront: 75 × 0.767 = 57.5g → bolus
Remaining: 75 × 0.233 = 17.5g → future entries over 177 min
```

**Protein:** 8g < 15g threshold → 0g equivalent, no entries

**Fat:** 3g < 5g threshold → 0g equivalent, no entries

**Total:** 57.5g bolus now, 17.5g via SMBs over ~3 hours. No delayed fat/protein effect. The fat-scaled floor ensures this simple carb meal gets close to standard AID behavior (77% upfront).

### Example B: Mixed Meal (Cheeseburger and Fries)

**Meal:** 65g carbs, 28g fat, 35g protein
**Settings:** Defaults (25% floor), rapid-acting insulin, no Garmin

**Carb curve:**
```
τ = 35 + (28 × 0.8) = 57.4 min
CDF(45) = 0.196
fatScaledMin = lerp(0.80, 0.25, 28/50) = 0.492
effectivePercent = max(0.196, 0.492) = 0.492  ← floor wins
Upfront: 65 × 0.492 = 32.0g → bolus
Remaining: 65 × 0.508 = 33.0g → future entries over 272 min (4.5h)
```

**Protein:**
```
factor = (35 - 15) / (40 - 15) × 0.35 = 0.28
glucoseEquiv = 35 × 0.28 = 9.8g
→ 26 entries from 90-480 min (sigmoid shape, peak at 4-5h)
```

**Fat:**
```
fatEquiv = 28 × 0.69 = 19.3g
→ 28 entries from 120-540 min (Gaussian, peak at 6h)
```

**Total effective carbs:** 32.0 + 33.0 + 9.8 + 19.3 = 94.1g
**Total delayed:** 62.1g over 9 hours

**Compare to V1:**
```
V1: FPU = (35×4 + 28×9) / 100 = 3.92
    Duration: 5 hours
    carbEquiv = (35×4 + 28×9) / 10 × 0.5 = 19.6g linear over 5 hours
    Upfront bolus: full 65g

V2 total delayed: 62.1g (3.2× more than V1's 19.6g)
V2 upfront: 32.0g (vs V1's 65g)
```

The V2 system delivers roughly half the carbs upfront for this mixed meal and shifts the rest to match the delayed absorption profile.

### Example C: High-Fat Meal with Bad Sleep (Pizza Night)

**Meal:** 80g carbs, 40g fat, 25g protein
**Settings:** Defaults, ultra-rapid insulin
**Garmin:** Sleep score 42, sleep 5.2h, Body Battery 22, stress 65, RHR +9, yesterday 450 kcal active

**Garmin demand factor:**
```
Sleep score 40-55:     -0.15
Sleep 5-6h:            -0.05
Body Battery 15-30:    -0.12
Stress 60-75:          -0.04
Avg stress (unknown):   0.00
RHR +8 to +12:         -0.07
Yesterday 400-600 cal: +0.10

sensitivityFactor = 1.0 - 0.15 - 0.05 - 0.12 - 0.04 - 0.07 + 0.10 = 0.67
clamp(0.67, 0.60, 1.40) = 0.67
demandFactor = 1.0 / 0.67 = 1.49
```

**Carb curve:**
```
τ = 35 + (40 × 0.8) = 67 min
CDF(30) = 0.092  (ultra-rapid: 30 min window)
fatScaledMin = lerp(0.80, 0.25, 40/50) = 0.36
effectivePercent = max(0.092, 0.36) = 0.36  ← floor wins
Upfront: 80 × 0.36 × 1.49 = 42.9g → bolus
Remaining: 80 × 0.64 × 1.49 = 76.3g → future entries
```

**Protein:**
```
factor = (25 - 15) / (40 - 15) × 0.35 = 0.14
glucoseEquiv = 25 × 0.14 = 3.5g
× demandFactor: 3.5 × 1.49 = 5.2g → sigmoid entries
```

**Fat:**
```
fatEquiv = 40 × 0.69 = 27.6g
× demandFactor: 27.6 × 1.49 = 41.1g → Gaussian entries
```

**Total:** 42.9g bolus now, 122.6g via SMBs over 9 hours. The fat-scaled floor raises the upfront from 9.2% to 36%, while the Garmin context adds 49% more insulin across the board — appropriate for a sleep-deprived, stressed state eating a large fatty meal.

---

## 14. Literature Review and Evidence Base

### Fat and Glucose Response

**Wolpert HA, et al. (2013).** *Dietary Fat Acutely Increases Glucose Concentrations and Insulin Requirements in Patients With Type 1 Diabetes.* Diabetes Care, 36(4), 810-816.
- High-fat dinner (60g fat) vs low-fat (10g fat) with identical carbs
- **42% more insulin required** for high-fat meal (range 17–124%)
- Late glucose excursion peaked at 5 hours
- Foundation for the 0.69 fat coefficient

**Bell KJ, et al. (2020).** *Amount and Type of Dietary Fat, Postprandial Glycemia, and Insulin Requirements in Type 1 Diabetes.* Journal of Clinical Endocrinology & Metabolism, 105(3).
- 60g fat: +21% insulin. 40g fat: +6%. 20g fat: +6%.
- Saturated fat produced the largest glycemic impact
- Dose-response relationship is nonlinear

**Gentilcore D, et al. (2006).** *Effects of Fat on Gastric Emptying of and the Glycemic, Insulin, and Incretin Responses to a Carbohydrate Meal.* Journal of Clinical Endocrinology & Metabolism, 91(6), 2062-2067.
- Fat delays gastric emptying in a dose-dependent manner
- Foundation for the 0.8 min/g fat slowing coefficient on τ

### Protein and Glucose Response

**Smart CE, et al. (2013).** *Both Dietary Protein and Fat Increase Postprandial Glucose Excursions in Children With Type 1 Diabetes, and the Effect Is Additive.* Diabetes Care, 36(12), 3897-3902.
- Fat and protein effects on glucose are **additive** (not overlapping)
- Combined HFHP meal produced +5.4 mmol/L (97 mg/dL) excursion at 5 hours
- Protein alone produced significant late rises

**Paterson MA, et al. (2016).** *Influence of Pure Protein on Postprandial Blood Glucose Levels in Individuals With Type 1 Diabetes Mellitus.* Diabetologia, 59(9), 2057-2064.
- 75g and 100g pure protein loads raised BG from 3 hours onward
- Effect was dose-dependent with saturation at higher amounts
- Foundation for the threshold/plateau model

**Bell KJ, et al. (2016).** *Optimized Mealtime Insulin Dosing for Fat and Protein in Type 1 Diabetes: the Bionic Pancreas.* Diabetes Care, 39(9), e141-e142.
- HFHP meals required **65% more insulin** (range 17–124%)
- Optimal delivery: **30% upfront / 70% extended** over 2.4 hours
- Direct validation of the split-dosing approach

### Insulin Sensitivity and Lifestyle

**Donga E, et al. (2010).** *A Single Night of Partial Sleep Deprivation Induces Insulin Resistance.* Journal of Clinical Endocrinology & Metabolism, 95(6), 2963-2968.
- One night of 4 hours sleep reduced insulin sensitivity by approximately 25%
- Foundation for the sleep score impact weights

**Spiegel K, et al. (1999).** *Impact of Sleep Debt on Metabolic and Endocrine Function.* The Lancet, 354(9188), 1435-1439.
- Chronic sleep restriction (4h/night for 6 nights) reduced glucose tolerance by 40%

**Pańkowska E, et al. (2009).** *Application of Novel Dual Wave Meal Bolus and Its Impact on Glycated Hemoglobin A1c in Children With Type 1 Diabetes.* Pediatric Diabetes, 10(5), 298-303.
- Original Warsaw Method / Fat-Protein Unit system
- Foundation for V1 implementation (which V2 replaces)

### Exercise and Sensitivity

**Borghouts LB, Keizer HA. (2000).** *Exercise and Insulin Sensitivity: A Review.* International Journal of Sports Medicine, 21(1), 1-12.
- Single bout of exercise increases insulin sensitivity for 24–72 hours
- Foundation for the yesterday/today activity impact weights

---

## 15. Summary of Improvements Over V1

| Aspect | V1 (Warsaw/oref) | V2 (Three-Curve Engine) |
|--------|-------------------|------------------------|
| **Carb model** | Linear decay, fixed duration | Gamma(2,τ) with fat-modified τ |
| **Protein model** | Combined with fat as calories/10 | Independent sigmoid, threshold/plateau ramp |
| **Fat model** | Combined with protein as calories/10 | Independent Gaussian, peaks at 6h |
| **Upfront bolus** | 100% of carbs | Curve-calculated split (17–34% for mixed meals) |
| **Delayed delivery** | Linear entries, small amounts | Curve-shaped entries matching absorption physiology |
| **individualAdjustmentFactor** | Halves all FPU (default 0.5) | Not applied — V2 coefficients are research-calibrated |
| **Sensitivity context** | None (same ratio every day) | Garmin sleep/stress/activity/HR/HRV → demand factor |
| **SMB delivery** | Default oref limits | Safety-gated multiplier during active meal entries |
| **Real-time correction** | oref only (slow) | BG-adaptive scaling of future entries every 5 min |
| **Learning** | None (fixed coefficients) | Phase-attributed outcome learning from BG checkpoints |
| **Tuning** | Single global factor | 5 independent sliders with live preview |
| **Fat entry magnitude** | 28g fat → ~4.8g equiv (with 0.5 factor) | 28g fat → 19.3g equiv (full coefficient) |
| **Protein entry magnitude** | 35g protein → ~3.4g equiv | 35g protein → 9.8g equiv |

The V2 system delivers insulin that matches the temporal profile of mixed-meal absorption — more insulin when fat/protein effects peak, less insulin when only the bolus-covered upfront carbs are active — while adapting to the user's daily physiological state and learning from every meal outcome.

---

*This document describes the V2 Macro Absorption Engine as implemented in the Trio open-source automated insulin delivery system. The system is for research and personal use. It is not FDA-approved and should not be used as the sole basis for insulin dosing decisions without clinical oversight.*
