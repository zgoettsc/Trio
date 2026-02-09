# V3 Three-Curve Macro Absorption Engine: A Physiologically-Grounded Dosing System for Mixed Meals in Automated Insulin Delivery

**Version 3.0 — February 2026**

---

## Abstract

Standard automated insulin delivery (AID) systems calculate meal boluses from carbohydrate counts alone, treating fat and protein as secondary effects handled by a simplistic linear model (the Warsaw Method). This approach systematically under-doses for mixed meals containing significant fat and protein, producing late hyperglycemia in the 3–9 hour window after eating. We present the V3 Three-Curve Macro Absorption Engine, a replacement dosing system that models carbohydrate absorption as a gamma distribution, protein gluconeogenesis as a delayed sigmoid, and fat-induced insulin resistance as a normalized Gaussian. The system integrates wearable health data from Garmin devices to adjust insulin demand based on sleep, stress, and activity context, with a hardcoded composite demand ceiling that prevents compounding multipliers from producing dangerous over-delivery. A closed-loop outcome learning system tracks BG at timed checkpoints after each meal, attributes errors to the responsible absorption curve using dynamic phase attribution based on actual meal composition, and progressively tunes five personal curve parameters. Meal-attributed insulin-on-board tracking uses oref-matching decay curves to ensure the adaptive system's IOB estimates align with the loop's own insulin activity model. A redesigned treatment flow processes multiple meals independently with per-meal temporal awareness, preventing over-delivery for late-dosed meals. We describe the mathematical formulation, safety architecture, implementation within the Trio open-source AID system, and the rationale grounded in published clinical research.

---

## Table of Contents

1. [The Problem: Why Standard AID Fails for Mixed Meals](#1-the-problem-why-standard-aid-fails-for-mixed-meals)
2. [The V1 Baseline: oref and the Warsaw Method](#2-the-v1-baseline-oref-and-the-warsaw-method)
3. [The V3 Solution: Three-Curve Absorption Model](#3-the-v3-solution-three-curve-absorption-model)
4. [Curve 1: Carbohydrate Absorption — Gamma(2, τ)](#4-curve-1-carbohydrate-absorption)
5. [Curve 2: Protein Gluconeogenesis — Delayed Sigmoid](#5-curve-2-protein-gluconeogenesis)
6. [Curve 3: Fat Insulin Resistance — Normalized Gaussian](#6-curve-3-fat-insulin-resistance)
7. [Split Dosing: Preventing Mixed-Meal Hypoglycemia](#7-split-dosing-preventing-mixed-meal-hypoglycemia)
8. [Garmin Wearable Sensitivity Integration](#8-garmin-wearable-sensitivity-integration)
9. [Meal-Mode SMB Enhancement and Safety Gates](#9-meal-mode-smb-enhancement-and-safety-gates)
10. [BG-Adaptive Real-Time Correction](#10-bg-adaptive-real-time-correction)
11. [Composite Demand Ceiling and Safety Architecture](#11-composite-demand-ceiling-and-safety-architecture)
12. [Outcome Learning and Parameter Tuning](#12-outcome-learning-and-parameter-tuning)
13. [Treatment Flow: Meal Detection, Multi-Meal Processing, and Dose Preview](#13-treatment-flow-meal-detection-multi-meal-processing-and-dose-preview)
14. [User-Facing Configuration](#14-user-facing-configuration)
15. [Worked Examples](#15-worked-examples)
16. [Thread Safety and Concurrency](#16-thread-safety-and-concurrency)
17. [Literature Review and Evidence Base](#17-literature-review-and-evidence-base)
18. [Summary of Improvements Over V1](#18-summary-of-improvements-over-v1)

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

## 3. The V3 Solution: Three-Curve Absorption Model

### Design Principles

The V3 engine replaces the single linear FPU distribution with three independent, physiologically-shaped curves:

1. **Separate pathways for separate mechanisms.** Carbohydrate absorption, protein gluconeogenesis, and fat insulin resistance are modeled independently with different curve shapes, timescales, and parameters.

2. **Curve-driven split dosing.** Instead of delivering the full carb bolus upfront, the engine uses the carbohydrate absorption curve to calculate how much should be bolused immediately vs. delivered later via SMBs — preventing the early dip from premature insulin action.

3. **Personal parameterization.** Five core parameters control the curves. Each can be tuned via sliders or learned automatically from meal outcomes.

4. **Context-aware dosing.** Garmin wearable data adjusts all entries by an insulin demand factor reflecting the user's current physiological state.

5. **Closed-loop learning.** BG checkpoints at 1h/2h/3h/4h/5h/6h/8h are backfilled from CGM data, attributed to the responsible curve phase using dynamic composition-aware attribution, and used to adjust parameters over time.

6. **Layered safety architecture.** A hardcoded composite demand ceiling prevents compounding multipliers from producing dangerous over-delivery, with automatic degradation when the ceiling is hit repeatedly. Meal-attributed IOB uses oref-matching decay curves. Five independent safety gates control SMB enhancement, with IOB-aware stacking prevention.

7. **Per-meal temporal independence.** Multiple meals are processed independently with their own timestamps, preventing over-delivery when dosing late meals alongside current ones.

### Architecture Overview

```
HealthKit Meal Detection / Manual Entry
    ↓
Per-Meal Independent Processing (each meal with own timestamp)
    ↓
MacroAbsorptionEngine.generateEntries() — per meal
    ├── Curve 1: Gamma(2,τ) carb entries → split into upfront bolus + future entries
    ├── Curve 2: Sigmoid protein entries → 90-480 min, every 15 min
    └── Curve 3: Gaussian fat entries → 120-540 min, every 15 min
    ↓
× insulinDemandFactor (from Garmin)
    ↓
Composite Demand Ceiling Check (hardcoded 2.5x max)
    ↓
Upfront carbs → bolus calculator (immediate)
Future entries → Core Data → oref sees them as future carbs → delivers via SMBs
    ↓
BG-Adaptive Service monitors actual BG vs predicted
    Uses meal-attributed IOB with oref-matching decay curves
    Uses BG delta from meal start (not trend extrapolation)
    ↓ (if divergence)
Scale remaining future entries up or down
    ↓
Five Safety Gates control SMB enhancement (with IOB stacking prevention)
    SMB rate reduced when composite demand > 1.5x
    ↓
Outcome Learning backfills BG at 7 checkpoints
    ↓
Dynamic phase attribution based on actual meal composition
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

Fat slows gastric emptying by signaling the pyloric sphincter to reduce emptying rate. The V3 engine models this as a linear increase in τ:

```
τ_effective = τ_base + (fat_grams × 0.8)
```

Where 0.8 minutes per gram of fat is derived from gastric emptying studies (Gentilcore et al., 2006; Horowitz et al., 1993).

> **Note:** The 0.8 min/g coefficient is derived from liquid fat load studies (olive oil infused into the duodenum). Solid food with fat may exhibit different gastric emptying rates due to mechanical breakdown. This coefficient serves as a starting point; the outcome learning system adjusts effective τ from real meal data.

### Fiber Modification of τ

Dietary fiber independently slows gastric emptying and glucose absorption (Torsdottir et al., 1991; Jenkins et al., 1978). The V3 engine adds a fiber delay term:

```
τ_effective = τ_base + (fat_grams × 0.8) + max(0, fiber_grams − 5) × 0.3
```

The 0.3 min/g coefficient is conservative — fiber's effect is real but smaller than fat's. The 5g threshold avoids adjusting for trace amounts. Fiber data is sourced from Apple Health via Cronometer.

**Example — τ values for different meals:**

| Meal | Fat | Fiber | τ_base | τ_effective | Peak Absorption | 95% Duration |
|------|-----|-------|--------|-------------|-----------------|--------------|
| Rice only | 0g | 1g | 35 min | 35 min | 35 min | 166 min (2.8h) |
| Sandwich | 12g | 3g | 35 min | 44.6 min | 45 min | 211 min (3.5h) |
| High-fiber cereal | 2g | 12g | 35 min | 37.7 min | 38 min | 179 min (3.0h) |
| Pizza | 30g | 4g | 35 min | 59 min | 59 min | 280 min (4.7h) |
| Cheese steak | 50g | 2g | 35 min | 75 min | 75 min | 356 min (5.9h) |

### Parameterization

| Parameter | Default | Range | Stored In |
|-----------|---------|-------|-----------|
| τ_base (Carb Tau) | 35 min | 20–60 min | V2PersonalCurveParameters.carbTau |
| Fat slowing coefficient | 0.8 min/g | Fixed | Hardcoded |
| Fiber slowing coefficient | 0.3 min/g | 0.00–1.00 | Tunable via recalibration |
| Fiber threshold | 5g | Fixed | Hardcoded |

The base τ is tunable via the settings slider or learned from early (0–2h) checkpoint errors.

---

## 5. Curve 2: Protein Gluconeogenesis

### The Physiological Mechanism

Dietary protein above a threshold amount stimulates hepatic gluconeogenesis — the liver converts amino acids (primarily alanine and glutamine) into glucose. Additionally, protein stimulates glucagon secretion, which further drives hepatic glucose output. The combined effect produces a slow, delayed glucose rise beginning at approximately 2 hours post-meal and peaking at 4–5 hours.

### Conversion Factor: How Much Protein Becomes Glucose?

The V3 engine uses a **smooth ramp function** rather than a hard threshold:

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

**Constraint:** proteinPlateau must always exceed proteinThreshold. The settings UI enforces this with bidirectional validation — adjusting the threshold pushes the plateau forward if needed, and lowering the plateau pushes the threshold back. A re-entrancy guard prevents the two validators from creating a ping-pong loop.

---

## 6. Curve 3: Fat Insulin Resistance

### The Physiological Mechanism

Dietary fat does not directly raise blood glucose. Instead, fat increases circulating free fatty acids (FFAs) beginning at approximately 2 hours post-meal, peaking at 4–6 hours. Elevated FFAs cause insulin resistance through two mechanisms:

1. **Peripheral resistance:** FFAs compete with glucose for oxidation in muscle, reducing glucose uptake (Randle cycle)
2. **Hepatic glucose output:** FFAs stimulate hepatic gluconeogenesis and glycogenolysis

The net effect is that the same amount of insulin has less glucose-lowering power — the user needs more insulin to maintain the same BG level.

### Nonlinear Conversion Coefficient

The V3 engine converts fat grams to a carb-equivalent using a **nonlinear saturating ramp** rather than a single linear coefficient. Bell (2020) demonstrated that the dose-response relationship between fat intake and insulin requirement is nonlinear — moderate fat amounts (20g) produced a much smaller relative effect than large amounts (60g).

```
fatCarbEquivalent(fatGrams, maxCoeff) =
    0                                               if fatGrams < 5g
    fatGrams × 0.05                                 if fatGrams ≤ 10g (threshold)
    fatGrams × lerp(0.05, maxCoeff, (fat-10)/(50-10))  if 10g < fatGrams < 50g (plateau)
    fatGrams × maxCoeff                             if fatGrams ≥ 50g
```

The ramp uses a minimal coefficient (0.05) below 10g of fat, linearly increases to the full `maxCoeff` at 50g, and saturates above 50g. The threshold (10g) and plateau (50g) represent physiological breakpoints and are hardcoded rather than user-configurable.

**Default maxCoeff:** 0.69 g-carb-equivalent per g-fat (from Wolpert et al., 2013)

**Example values with nonlinear ramp:**

| Fat | Effective Coefficient | Carb-Equivalent |
|-----|----------------------|-----------------|
| 3g | — | 0g (below 5g threshold) |
| 8g | 0.05 | 0.4g |
| 15g | 0.13 | 2.0g |
| 28g | 0.37 | 10.4g |
| 40g | 0.54 | 21.4g |
| 50g+ | 0.69 | 34.5g (at maxCoeff) |

The nonlinear ramp prevents overcharging moderate-fat meals while maintaining full effectiveness for high-fat meals where the insulin resistance effect is strongest.

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
| fatTotalCoeff | 0.69 | 0.30–1.20 | Maximum g-carb-equivalent per g-fat (peak of nonlinear ramp) |

**Note:** The slider range is capped at 1.20 to match the learning system's clamp, preventing users from setting dangerously high values that would generate excessive carb-equivalents for fat.

---

## 7. Split Dosing: Preventing Mixed-Meal Hypoglycemia

### The Problem with Full Upfront Boluses

When fat delays carbohydrate absorption (shifting τ from 35 to 60+ minutes), a full upfront bolus delivers maximum insulin action at 60–90 minutes — before peak carb absorption. This causes:

1. A BG dip at 1–2 hours (insulin peaks before carbs)
2. A rebound rise at 2–4 hours (carbs arrive after insulin wanes)

### Curve-Driven Split Calculation

The V3 engine uses the Gamma CDF to calculate what fraction of carbs will be absorbed within a "safe window" — the period during which the upfront bolus insulin is most active:

```
cdfPercent = CDF(safeWindow) = 1 - (1 + safeWindow/τ) × exp(-safeWindow/τ)
```

The safe window depends on insulin type:

| Insulin Type | Examples | Peak Action | Safe Window |
|-------------|----------|-------------|-------------|
| Ultra-rapid | Fiasp, Lyumjev | 30–45 min | 30 min |
| Rapid-acting | Humalog, Novolog | 60–90 min | 45 min |

### Fat-Scaled Minimum Upfront Floor

The CDF alone under-boluses simple carb meals. For a rice bowl (3g fat, τ=37.4), CDF(45) = 33.9% — only a third of the carbs are covered upfront. Standard AID delivers 100% for simple carbs and it works fine. The split was designed for high-fat meals (Bell 2016), not rice.

The engine applies a **fat-scaled minimum upfront percentage** that ensures clinically meaningful boluses for all meals:

```
minUpfront = lerp(0.80, floor, clamp(fatGrams / 50, 0, 1))
effectivePercent = max(cdfPercent, minUpfront)
```

Where `floor` is a user-configurable setting (default 25%, range 15–70%). The effective upfront percent is the **greater** of the CDF and the fat-scaled minimum.

| Fat | minUpfront (25% floor) | CDF (rapid-acting) | Effective |
|-----|----------------------|---------------------|-----------|
| 0g  | 80.0% | varies | **80.0%** |
| 3g  | 76.7% | 33.9% | **76.7%** (floor wins) |
| 12g | 66.8% | ~25% | **66.8%** (floor wins) |
| 28g | 49.2% | 19.6% | **49.2%** (floor wins) |
| 30g | 47.0% | 17.7% | **47.0%** (floor wins) |
| 50g | 25.0% | 12.3% | **25.0%** (floor wins) |

This preserves aggressive splitting for high-fat meals (where Bell 2016 supports 30/70 dosing) while ensuring simple carb meals get close to standard AID full-bolus behavior. The user's manual upfront override (slider) bypasses the floor entirely.

**Example — Pizza (65g carbs, 30g fat, rapid-acting insulin):**

```
τ = 35 + (30 × 0.8) = 59 min
CDF(45) = 0.177
fatScaledMin = lerp(0.80, 0.25, 30/50) = 0.47
effectivePercent = max(0.177, 0.47) = 0.47

→ 47.0% upfront (30.6g as immediate bolus)
→ 53.0% as future entries (34.5g delivered via SMBs over ~4.7 hours)
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

Simple carb meals now get close to standard AID behavior (77% upfront), while fatty meals still get aggressive splitting (47% for pizza, 25% for cheese steak).

### Safety Invariant

**Critical:** The upfront portion is returned as a number for the bolus calculator. **No Core Data entries are created for it.** Only the remaining carbs (after the safe window) become entries that oref sees. This prevents double-counting — the bolus covers the upfront portion, oref sees only the future portion.

---

## 8. Garmin Wearable Sensitivity Integration

### Rationale

Insulin sensitivity varies day-to-day based on sleep quality, stress, physical activity, illness, and recovery state. A user who slept 4 hours and is highly stressed needs more insulin than the same user after a restful night and a workout. Traditional AID systems ignore this — they use the same carb ratio and sensitivity factor regardless of context.

### Data Source

The V3 system integrates with Garmin wearable devices via Firebase/Firestore. A `GarminContextSnapshot` captures the user's current physiological state:

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

---

## 9. Meal-Mode SMB Enhancement and Safety Gates

### The Problem

oref's default SMB limits (typically 30 minutes of basal rate) are designed for correction, not meal absorption. When the V3 engine creates future carb entries that arrive over 4–8 hours, oref sees them but can only deliver small SMBs. The entries predict the need, but oref's delivery rate can't keep up.

### The Enhancement

When V3 meal entries are active, the system can multiply the maximum SMB size by a configurable factor (default 2.0x, range 1.0–3.0x). This increases `maxSMBBasalMinutes` and `maxUAMSMBBasalMinutes` so oref can deliver larger boluses to match the curve-predicted need.

**Rate Limiting Under High Composite Demand:** When the composite demand (Garmin × adaptive scaling) exceeds 1.5x, the SMB multiplier is automatically reduced to prevent compounding high entry amounts with high delivery rates:
- At 1.5–2.0x composite demand: SMB multiplier linearly reduces toward 1.5x
- Above 2.0x composite demand: SMB multiplier capped at 1.5x

This prevents scenarios where 2.5x entry amounts are delivered at 3.0x rate.

### The Five Safety Gates

Enhancement is NOT always-on. Five independent safety gates must ALL pass on every oref cycle. If **any single gate** fails, the multiplier reverts to 1.0x instantly:

**Gate 1: Active Meal Entries**
Future V3 entries (carb-absorption, protein-gluconeogenesis, or fat-resistance) must exist in Core Data with dates in the future. Once all entries have been consumed, enhancement stops.

**Gate 2: BG Above Floor**
Current BG must be above the configurable floor (default 90 mg/dL, range 70–130). If BG drops below the floor, enhancement stops immediately — no need to deliver more insulin when already heading low.

**Gate 3: BG Trend Flat or Rising (with Hysteresis)**
The CGM trend must not be falling rapidly. Specifically:
- If a CGM direction arrow is available: `doubleDown`, `singleDown`, and `fortyFiveDown` fail the gate
- Fallback: the delta between the two most recent readings must be ≥ −3.0 mg/dL per 5 minutes
- **Hysteresis:** Once the gate fails (trend < −3.0), it requires the trend to recover to ≥ 0.0 mg/dL per 5 minutes before re-enabling. This prevents rapid toggling caused by CGM noise near the threshold.

This prevents enhancement during active drops — if BG is already falling, the existing insulin is working. The −3.0 threshold allows normal post-meal dips (typically −1 to −2 mg/dL/5min) while catching real drops. The hysteresis ensures that once the gate trips, the system waits for a clear recovery before resuming enhanced delivery.

**Gate 3 thread safety:** The hysteresis flag (`gate3FailedLastCycle`) is a static variable accessed from the loop timer thread. An `NSLock` protects all reads and writes to prevent data races.

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
    effectiveMultiplier = min(mealModeSMBMultiplier, rateLimit(compositeDemand))
    effectiveSMBMinutes = baseMaxSMBMinutes × effectiveMultiplier
    effectiveUAMMinutes = baseMaxUAMMinutes × effectiveMultiplier
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
   Uses **meal-attributed IOB** (insulin specifically recorded for this meal via `recordMealInsulin`) rather than total system IOB, preventing correction boluses from confounding the prediction.

   **oref-Matching IOB Decay:** Meal-attributed IOB models insulin decay using the same curves as oref, not a simple accumulator. The system supports two decay models that match oref exactly:

   - **Bilinear (piecewise quadratic):** Uses oref's polynomial coefficients — `-0.001852*x1*x1 + 0.001852*x1 + 1.0` pre-peak, `0.001323*x2*x2 - 0.054233*x2 + 0.555560` post-peak
   - **Exponential:** Uses the LoopKit/Loop formula with tau, rise time factor, and auxiliary scale factor S. Peak times: 75 minutes for rapid-acting, 55 minutes for ultra-rapid.

   The user's insulin curve preference (bilinear, rapid-acting, or ultra-rapid) determines which decay model is used. This eliminates the systematic bias that occurred when the adaptive service's IOB estimate diverged from the loop's own model — previously, an undecayed accumulator would over-estimate active insulin for long meals (6–8h), incorrectly suppressing adaptive scaling in the late window.

2. **Calculate actual BG change** from meal start:
   ```
   actualBGDelta = currentBG - bgAtMealStart
   ```
   Uses the BG at meal start (stored in `V2MealOutcome.bgAtMeal`) rather than extrapolating the current CGM trend, which is more accurate for meals that spiked early and then flattened.

3. **Compute error:**
   ```
   error = actualBGDelta - predictedImpact
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

### Absorbed Carbs Timing with Dynamic Buffer

Entries are classified as "absorbed" only after a dynamic buffer period has elapsed past their scheduled time. This prevents counting entries as absorbed before oref has had a chance to deliver insulin for them:

```
absorptionBuffer = max(5 minutes, timeSinceLastLoop)
absorbed = entries where entryDate + absorptionBuffer ≤ now
```

When the loop is delayed (phone backgrounded, Bluetooth reconnection), the buffer automatically extends to match the actual loop interval, preventing false inflation of absorbed carbs.

### Proportional SMB Attribution

When multiple meals are active simultaneously, SMB insulin is attributed proportionally by remaining carbs rather than split equally:

```
mealShare = mealRemainingCarbs / totalRemainingCarbs
mealInsulin = smbUnits × mealShare
```

This ensures that a large meal with 50g remaining carbs receives proportionally more insulin attribution than a small snack with 5g remaining, keeping each meal's IOB tracking accurate.

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

### Cumulative Scaling Persistence

The cumulative scaling state is persisted to UserDefaults (key `"V2CumulativeScaling"`) and restored on app restart. This prevents a meal already scaled up 80% from being scaled up another 100% after a restart, defeating the safety clamp.

---

## 11. Composite Demand Ceiling and Safety Architecture

### The Problem: Compounding Multipliers

The V3 system has three independent mechanisms that can increase insulin delivery beyond the base calculation:

| Multiplier | Source | Maximum | Mechanism |
|-----------|--------|---------|-----------|
| Garmin demand factor | Wearable health data | 1.67x | Scales all entries at meal time |
| BG-adaptive cumulative scaling | Real-time BG error | 2.0x | Scales remaining entries during absorption |
| Meal-mode SMB multiplier | Safety-gated enhancement | 3.0x delivery rate | Increases SMB size limit |

Without cross-checks, these compound: 1.67 × 2.0 = 3.34x entry amounts, potentially delivered at 3.0x the normal rate.

### The Composite Demand Ceiling

A **hardcoded ceiling of 2.5x** caps the product of demand factor and cumulative scaling:

```
compositeDemand = cumulativeScaling × demandFactor
if compositeDemand > 2.5:
    cumulativeScaling = 2.5 / demandFactor
```

This ceiling is not user-configurable. Exposing safety ceilings to users contradicts the design philosophy of preventing harm — a configurable ceiling invites the user to raise it when they are frustrated, which is precisely when they should not.

### SMB Rate Reduction

The ceiling caps entry *amounts* but not delivery *rate*. A separate rate limiter reduces the meal-mode SMB multiplier when composite demand is elevated:

| Composite Demand | SMB Multiplier Limit |
|-----------------|---------------------|
| ≤ 1.5x | Full user-configured multiplier (up to 3.0x) |
| 1.5x – 2.0x | Linear reduction toward 1.5x |
| > 2.0x | Capped at 1.5x |

### Auto-Degradation on Repeated Ceiling Hits

If the BG-adaptive loop is consistently pushing demand upward (e.g., due to a slow-absorbing meal causing repeated positive BG errors), the cumulative scaling will hit the composite ceiling every cycle. The system automatically degrades when this happens:

- **Cycles 1–2:** Ceiling hit, counter increments, scaling stays at ceiling
- **Cycle 3:** Ceiling hit again, auto-degrade fires — scaling drops to 80% of ceiling
- **If ceiling is hit 3 more times:** Scaling drops to 64% of ceiling, etc.
- **If a cycle does NOT hit the ceiling:** Counter resets, no degradation

This provides automatic self-correction without user intervention. If the engine is stuck at maximum aggressiveness due to a model mismatch (e.g., the user miscounted carbs and the adaptive service keeps trying to compensate), the degradation gradually reduces delivery rather than maintaining maximum output indefinitely.

### Ceiling Hit Logging

All ceiling hits and SMB rate reductions are logged via the debug logging system with full context (demand factor, scaling value, composite value, before/after multiplier). This enables post-hoc analysis of whether the 2.5x ceiling is appropriately set.

---

## 12. Outcome Learning and Parameter Tuning

### Meal Outcome Recording

When a user applies a meal with V3 enabled and "Record Meal Outcomes" on, a `V2MealOutcome` record is created containing:

- The macros applied (carbs, fat, protein, fiber)
- The curve parameters used (tauCarb, proteinFactor, fatTotalEquiv)
- The dosing context (upfrontPercent, insulinDemandFactor, carbRatioAtMeal, isfAtMeal)
- The Garmin context snapshot
- Seven empty BG checkpoints at 1h, 2h, 3h, 4h, 5h, 6h, and 8h (phases dynamically assigned based on meal macros)

### MealID Linkage

The outcome's mealID is linked to the engine's mealID (used as `fpuID` in Core Data entries) through a deferred save mechanism:

1. When the user taps "Apply," a pending outcome is created with a placeholder mealID
2. After `saveMeal()` runs the engine and generates entries, the engine's actual mealID is captured
3. The pending outcome is finalized with the engine's mealID before being persisted

This linkage enables the export system to match outcomes to their scheduled entries in Core Data.

### BG Checkpoint Backfill

Backfill runs automatically in the background every 6 hours (triggered by the loop cycle via `MacroAdaptiveService.runAdaptiveCycle()`), as well as when the user opens a Cronometer recommendation or the Outcome Accuracy page. This ensures learning is not gated on UI interaction. For each empty checkpoint:

1. Calculate target time = meal date + checkpoint hours
2. Wait until 30 minutes after target (to ensure CGM data exists)
3. Query Core Data for the closest glucose reading within ±30 minutes
4. If found, write the BG value

### Dynamic Curve Phase Attribution

Each checkpoint is tagged with the dominant absorption curve at that time. Phase attribution is **dynamic** based on actual meal composition — low-protein meals skip protein checkpoints; low-fat meals skip fat checkpoints. The `.skip` phase excludes the checkpoint from parameter learning, preventing attribution errors for curves that weren't active.

| Checkpoint | Phase | Dominant Curve |
|------------|-------|---------------|
| 1h | carb | Carbohydrate absorption (gamma peak region) |
| 2h | carb | Carbohydrate absorption (tail region) |
| 3h | protein/carb | Protein gluconeogenesis onset (if protein > threshold, else carb) |
| 4h | overlap/protein/fat/carb | Dynamic: overlap if both protein+fat (excluded from learning), else dominant macro |
| 5h | protein/fat/skip | Protein peak (4-5h), or fat if no protein, or skip if neither |
| 6h | fat/skip | Fat insulin resistance peak (if fat ≥ 5g, else skip) |
| 8h | fat/skip | Fat insulin resistance tail (if fat ≥ 5g, else skip) |

### Confounding Meal Detection

When a subsequent meal is eaten before all checkpoints complete, individual checkpoints are marked `isClean = false` when the confounding meal's start time falls before that checkpoint's target time. This preserves early checkpoints (1h, 2h) that are clean even when a snack at 3h contaminates later checkpoints. The detection runs automatically during BG backfill.

Small snacks below a macro-load threshold (**< 15g carbs AND < 5g fat**) are excluded from confounding detection, as they don't produce enough glucose impact to meaningfully contaminate late-phase checkpoints. This preserves clean learning data from meals followed by minor snacks.

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

Errors are computed relative to a configurable target BG (default 110 mg/dL) with a ±30 dead zone, rather than the wider 70–180 band used in earlier versions. This ensures the system learns from a user who consistently lands at 170 (outside the dead zone) rather than treating that as "in range."

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
| overlap | Excluded from learning | The 4h overlap checkpoint is skipped for parameter learning to avoid noise-level adjustments from diluted 30% attribution. The 5h and 6h checkpoints provide cleaner single-curve signal. Overlap data is retained for monitoring. |
| skip | No adjustment | Checkpoint excluded from learning |

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

## 13. Treatment Flow: Meal Detection, Multi-Meal Processing, and Dose Preview

### V1/V2 Mode Toggle

The treatment page includes a segmented control at the top allowing the user to switch between V1 (Warsaw/oref) and V3 (Three-Curve) dosing modes for the current session. The default is determined by the `useV2MacroAbsorption` setting.

### Meal Detection Feed

The V3 treatment flow displays a meal feed showing recent nutrition events detected via HealthKit observer. Meals appear as cards with macro breakdowns. The user can select one or more meals from the feed, or enter macros manually.

### Per-Meal Independent Processing

When multiple meals are selected (e.g., a granola bar from 20 minutes ago plus a current lunch), each meal is processed independently with its own timestamp:

1. Each meal's `V2DetectedMeal` object retains its original detection timestamp
2. `MacroAbsorptionEngine.generateEntries()` is called separately per meal with its own `mealTime`
3. The gamma CDF at each meal's elapsed time correctly accounts for already-absorbed carbs — a 20-minute-old meal has its upfront portion reduced by the CDF at t=20
4. Each meal gets its own `mealID` so the adaptive service, IOB tracking, and outcome learning track them independently

Combined macro totals are displayed for reference, but the engine never sums macros from different timestamps into a single calculation.

### V3-Aware Dose Preview

The dose preview shows a two-line BG forecast chart:

- **"No treatment" line:** Predicted BG using only existing IOB decay (no new bolus, no new meals)
- **"With treatment" line:** Predicted BG with the proposed bolus and all selected meals' entry schedules

Both forecast lines use the **same prediction function** with different parameters. This is critical — using different models (e.g., oref's prediction for one line and a lightweight model for the other) would introduce model divergence that users would misinterpret as treatment effect:

```swift
predict(bolusUnits: Double, meals: [V2DetectedMeal], demandFactor: Double, tau: Double)
    -> [(date: Date, value: Double)]
```

The shared model uses ISF/CR-based BG prediction with per-meal gamma CDF contributions. Because both lines use identical math, the gap between them is purely the treatment effect — zero model divergence.

### Late Meal Handling

Meals older than 1 hour display a late-dose banner with:
- Elapsed time since detection
- Warning severity (mild 15–30 min, moderate 30–45 min, severe 45+ min)
- Percentage of carbs already absorbed (per gamma CDF)
- Adjusted remaining carbs

The per-meal gamma CDF ensures already-absorbed carbs are not double-counted. The engine calculates the upfront portion using `CDF(elapsedTime)` rather than `CDF(0)`, so a meal that's 30 minutes old gets a correspondingly smaller upfront bolus.

### Already-Dosed Meal Detection

If a meal has already been dosed (matched by mealID in Core Data), an indicator warns the user. Re-dosing is allowed but requires explicit confirmation to prevent accidental double-dosing.

### Correction-Only Shortcut

A correction-only path bypasses meal selection entirely, allowing the user to deliver a correction bolus without entering any meal data.

---

## 14. User-Facing Configuration

### Settings Hub Layout

The V3 settings are organized into a tabbed hub (Settings → V2 Macro Dosing) with four tabs:

**Nutrition Tab:**
- Cronometer integration settings
- Fiber data source configuration

**Engine Tab:**
- Enable/disable toggle
- Insulin type picker (rapid-acting / ultra-rapid)
- Safe window display with optional custom override (15–90 min stepper)
- Min Upfront Covered slider (15–70%, step 5%) — fat-scaled minimum upfront bolus floor
- Meal-Mode SMB Enhancement: multiplier slider (1.0–3.0x, step 0.1), BG floor slider (70–130 mg/dL, step 5)
- Fat Coefficient slider (0.30–1.20, step 0.01)
- Protein Factor slider (0.10–0.80, step 0.01)
- Protein Threshold slider (5–30g, step 1)
- Protein Plateau slider (20–80g, step 1)
- Base Carb Tau slider (20–60 min, step 1)
- Each slider has an insulin-direction info box showing what increasing or decreasing the value does
- Live example calculation for a reference meal (65g carbs, 28g fat, 35g protein), updating in real-time

**Garmin Tab:**
- Enable/disable toggle
- Firebase configuration status
- Garmin metric details and current snapshot

**Analysis Tab:**
- Record Meal Outcomes toggle
- Claude AI Recalibration toggle
- Analysis Window picker (7 / 14 / 21 / 30 days, default 14) — visible when Claude recalibration is enabled
- Recorded meal count and BG checkpoint count
- Link to Meal Outcome Accuracy page
- Export All Meal Data button

---

## 15. Worked Examples

### Example A: Simple Carb Meal (Rice Bowl)

**Meal:** 75g carbs, 3g fat, 8g protein, 2g fiber
**Settings:** Defaults (25% floor), rapid-acting insulin, no Garmin

**Carb curve:**
```
τ = 35 + (3 × 0.8) + max(0, 2 - 5) × 0.3 = 37.4 min  (fiber below threshold)
CDF(45) = 0.339
fatScaledMin = lerp(0.80, 0.25, 3/50) = 0.767
effectivePercent = max(0.339, 0.767) = 0.767  ← floor wins
Upfront: 75 × 0.767 = 57.5g → bolus
Remaining: 75 × 0.233 = 17.5g → future entries over 177 min
```

**Protein:** 8g < 15g threshold → 0g equivalent, no entries

**Fat:** 3g < 5g threshold → 0g equivalent, no entries

**Total:** 57.5g bolus now, 17.5g via SMBs over ~3 hours. No delayed fat/protein effect. The fat-scaled floor ensures this simple carb meal gets close to standard AID behavior (77% upfront vs. the old 34% from CDF alone).

### Example B: Mixed Meal (Cheeseburger and Fries)

**Meal:** 65g carbs, 28g fat, 35g protein, 3g fiber
**Settings:** Defaults (25% floor), rapid-acting insulin, no Garmin

**Carb curve:**
```
τ = 35 + (28 × 0.8) = 57.4 min  (fiber below threshold)
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

**Fat (nonlinear ramp):**
```
fatCarbEquivalent(28g, maxCoeff=0.69):
  effectiveCoeff = lerp(0.05, 0.69, (28-10)/(50-10)) = 0.05 + 0.64 × 0.45 = 0.338
  fatEquiv = 28 × 0.338 = 9.5g
→ 28 entries from 120-540 min (Gaussian, peak at 6h)
```

**Total effective carbs:** 32.0 + 33.0 + 9.8 + 9.5 = 84.3g
**Total delayed:** 52.3g over 9 hours

**Compare to V1:**
```
V1: FPU = (35×4 + 28×9) / 100 = 3.92
    Duration: 5 hours
    carbEquiv = (35×4 + 28×9) / 10 × 0.5 = 19.6g linear over 5 hours
    Upfront bolus: full 65g

V3 total delayed: 52.3g (2.7× more than V1's 19.6g)
V3 upfront: 32.0g (vs V1's 65g)
```

The V3 system delivers roughly half the carbs upfront for this mixed meal and shifts the rest to match the delayed absorption profile — more insulin when fat/protein effects peak, less at the start where it would cause a dip.

### Example C: High-Fat Meal with Bad Sleep (Pizza Night)

**Meal:** 80g carbs, 40g fat, 25g protein, 4g fiber
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
τ = 35 + (40 × 0.8) = 67 min  (fiber below threshold)
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

**Fat (nonlinear ramp):**
```
fatCarbEquivalent(40g, maxCoeff=0.69):
  effectiveCoeff = lerp(0.05, 0.69, (40-10)/(50-10)) = 0.05 + 0.64 × 0.75 = 0.530
  fatEquiv = 40 × 0.530 = 21.2g
× demandFactor: 21.2 × 1.49 = 31.6g → Gaussian entries
```

**Total:** 42.9g bolus now, 113.1g via SMBs over 9 hours. The fat-scaled floor raises the upfront from the CDF's 9.2% to 36%, while the Garmin context adds 49% more insulin across the board — appropriate for a sleep-deprived, stressed state eating a large fatty meal.

**Composite demand check:** If the BG-adaptive service later scales cumulative to 1.68x:
```
compositeDemand = 1.68 × 1.49 = 2.50  (exactly at ceiling — OK)
```
If it tries to scale to 1.80x:
```
compositeDemand = 1.80 × 1.49 = 2.68  (exceeds 2.5x ceiling)
cumulativeScaling capped to: 2.5 / 1.49 = 1.68x
```

### Example D: Multi-Meal with Late Dose

**Situation:** User ate a granola bar (30g carbs, 5g fat, 4g protein) 25 minutes ago, now eating lunch (50g carbs, 20g fat, 30g protein).

**Processing — Granola bar (t=25 min ago):**
```
τ = 35 + (5 × 0.8) = 39 min
CDF(25) = 0.176
Already absorbed: 30 × 0.176 = 5.3g (won't be double-counted)
fatScaledMin at t=45: lerp(0.80, 0.25, 5/50) = 0.745
CDF(45) = 0.314
effectivePercent = max(0.314, 0.745) = 0.745  ← floor wins
Remaining for upfront: 0.745 - 0.176 = 0.569 → 17.1g
Remaining for future entries: 30 × (1 - 0.745) = 7.7g
```

**Processing — Lunch (t=0, current):**
```
τ = 35 + (20 × 0.8) = 51 min
CDF(45) = 0.232
fatScaledMin = lerp(0.80, 0.25, 20/50) = 0.58
effectivePercent = max(0.232, 0.58) = 0.58  ← floor wins
Upfront: 50 × 0.58 = 29.0g
Future: 50 × 0.42 = 21.0g
```

Each meal gets its own mealID, its own adaptive tracking, and its own outcome record. The 25-minute-old granola bar's absorbed carbs are correctly accounted for by the gamma CDF — they don't appear as upfront or future entries.

---

## 16. Thread Safety and Concurrency

### The Problem

`MacroAdaptiveService` has multiple entry points that execute concurrently:

- `runAdaptiveCycle()` — called from the loop timer every 5 minutes
- `recordMealInsulin()` — called from bolus delivery (including SMB deliveries)
- `recordMealDemandFactor()` — called when a new meal is created
- `mealCompleted()` — called when a meal finishes absorbing

These all read/write shared mutable state: cumulative scaling, meal insulin records, meal demand factors, adjustment history, ceiling hit counts, and last adjustment time.

### Solution: Single NSLock

A single `NSLock` (`stateLock`) protects all mutable instance state. Every read or write of shared state acquires the lock:

**Protected operations:**
- `recordMealInsulin()` — full method under lock
- `getMealAttributedIOB()` — snapshot records under lock, compute IOB decay outside lock
- `recordMealDemandFactor()` — write + persist under lock
- `runAdaptiveCycle()` — read demand factors + cumulative scaling under lock
- `scaleFutureEntries()` — all cumulative scaling reads/writes, ceiling hit tracking, persist under lock
- `mealCompleted()` — all state cleanup under lock

### Lock Granularity

Lock regions are kept fine: acquire for state access, release before I/O (Core Data fetches, `context.perform`). This avoids holding the lock across async operations.

### Deferred Logging Pattern

`scaleFutureEntries()` captures log messages as local `String?` variables while the lock is held, then emits them via `debug()` after unlock. An earlier implementation released and re-acquired the lock around `debug()` calls, which created a race window where another thread could modify state between the read and the subsequent write — a classic lost-update scenario. The deferred pattern keeps the lock region contiguous (single acquire → single release) while still avoiding holding the lock during I/O.

---

## 17. Literature Review and Evidence Base

### Fat and Glucose Response

**Wolpert HA, et al. (2013).** *Dietary Fat Acutely Increases Glucose Concentrations and Insulin Requirements in Patients With Type 1 Diabetes.* Diabetes Care, 36(4), 810-816.
- High-fat dinner (60g fat) vs low-fat (10g fat) with identical carbs
- **42% more insulin required** for high-fat meal (range 17–124%)
- Late glucose excursion peaked at 5 hours
- Foundation for the 0.69 fat coefficient

**Bell KJ, et al. (2020).** *Amount and Type of Dietary Fat, Postprandial Glycemia, and Insulin Requirements in Type 1 Diabetes.* Journal of Clinical Endocrinology & Metabolism, 105(3).
- 60g fat: +21% insulin. 40g fat: +6%. 20g fat: +6%.
- Saturated fat produced the largest glycemic impact
- Dose-response relationship is nonlinear — foundation for the nonlinear fat ramp

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

### Fiber and Glucose Response

**Torsdottir I, et al. (1991).** *A Small Dose of Soluble Alginate-Fiber Affects Postprandial Glycemia and Gastric Emptying in Humans with Diabetes.* Journal of Nutrition, 121(6), 795-799.
- Soluble fiber slowed gastric emptying and reduced postprandial glucose

**Jenkins DJ, et al. (1978).** *Dietary Fibres, Fibre Analogues, and Glucose Tolerance.* British Medical Journal, 1(6124), 1392-1394.
- Dietary fiber reduces the rate of glucose absorption
- Foundation for the fiber modification of τ

### Insulin Sensitivity and Lifestyle

**Donga E, et al. (2010).** *A Single Night of Partial Sleep Deprivation Induces Insulin Resistance.* Journal of Clinical Endocrinology & Metabolism, 95(6), 2963-2968.
- One night of 4 hours sleep reduced insulin sensitivity by approximately 25%
- Foundation for the sleep score impact weights

**Spiegel K, et al. (1999).** *Impact of Sleep Debt on Metabolic and Endocrine Function.* The Lancet, 354(9188), 1435-1439.
- Chronic sleep restriction (4h/night for 6 nights) reduced glucose tolerance by 40%

**Pańkowska E, et al. (2009).** *Application of Novel Dual Wave Meal Bolus and Its Impact on Glycated Hemoglobin A1c in Children With Type 1 Diabetes.* Pediatric Diabetes, 10(5), 298-303.
- Original Warsaw Method / Fat-Protein Unit system
- Foundation for V1 implementation (which V3 replaces)

### Exercise and Sensitivity

**Borghouts LB, Keizer HA. (2000).** *Exercise and Insulin Sensitivity: A Review.* International Journal of Sports Medicine, 21(1), 1-12.
- Single bout of exercise increases insulin sensitivity for 24–72 hours
- Foundation for the yesterday/today activity impact weights

---

## 18. Summary of Improvements Over V1

| Aspect | V1 (Warsaw/oref) | V3 (Three-Curve Engine) |
|--------|-------------------|------------------------|
| **Carb model** | Linear decay, fixed duration | Gamma(2,τ) with fat- and fiber-modified τ |
| **Protein model** | Combined with fat as calories/10 | Independent sigmoid, threshold/plateau ramp, dynamic phase attribution |
| **Fat model** | Combined with protein as calories/10 | Independent Gaussian, nonlinear dose-response ramp, peaks at 6h |
| **Upfront bolus** | 100% of carbs | Fat-scaled split: 80% for simple carbs → 25% for high-fat meals |
| **Delayed delivery** | Linear entries, small amounts | Curve-shaped entries matching absorption physiology |
| **individualAdjustmentFactor** | Halves all FPU (default 0.5) | Not applied — V3 coefficients are research-calibrated |
| **Sensitivity context** | None (same ratio every day) | Garmin sleep/stress/activity/HR/HRV → demand factor |
| **SMB delivery** | Default oref limits | Safety-gated multiplier with rate limiting under high demand |
| **Real-time correction** | oref only (slow) | BG-adaptive scaling with oref-matching IOB decay curves |
| **IOB tracking** | System-wide total | Per-meal attributed IOB with proper insulin curve decay |
| **Safety architecture** | oref defaults only | 5 gates, composite demand ceiling (2.5x), auto-degradation, rate limiting |
| **Multi-meal handling** | Single carb entry | Per-meal independent processing with temporal awareness |
| **Learning** | None (fixed coefficients) | Dynamic phase-attributed outcome learning from 7 BG checkpoints |
| **AI recalibration** | None | Claude AI pattern analysis with 30% change limit and validation pipeline |
| **Confounding detection** | None | Per-checkpoint dirty marking preserves clean early checkpoints |
| **Tuning** | Single global factor | 5 independent sliders with live preview, validated constraints |
| **Thread safety** | N/A | NSLock protecting all shared mutable state |
| **Dose preview** | oref simulation | V3-aware prediction with same-model forecast lines |
| **Fat entry magnitude** | 28g fat → ~4.8g equiv (with 0.5 factor) | 28g fat → 9.5g equiv (nonlinear ramp) |
| **Protein entry magnitude** | 35g protein → ~3.4g equiv | 35g protein → 9.8g equiv |
| **Outcome storage** | None | Core Data with queryable attributes, 90-day retention |

The V3 system delivers insulin that matches the temporal profile of mixed-meal absorption — more insulin when fat/protein effects peak, less insulin when only the bolus-covered upfront carbs are active — while adapting to the user's daily physiological state, learning from every meal outcome, and maintaining layered safety protections that prevent compounding multipliers from producing dangerous over-delivery. Per-meal independent processing ensures accurate dosing even when multiple meals overlap or are dosed late.

---

## 19. Known Limitations and Planned Improvements

The following items have been identified through external review and are acknowledged as real design limitations. Items marked **[Planned]** are scheduled for implementation; items marked **[Acknowledged]** are known tradeoffs with no immediate fix planned.

### Planned Improvements

#### #5 — Pre-Meal BG Slope Correction

**The Problem**

The BG-adaptive service calculates error as `actualBGDelta - predictedImpact`, where `actualBGDelta = currentBG - bgAtMealStart`. This attributes the entire BG change since meal start to the meal. But BG was already moving before you ate.

The most common case is dawn phenomenon — hepatic glucose dump in the early morning that raises BG at +1 to +3 mg/dL per 5 minutes. If your BG was rising at +2 mg/dL/5min before breakfast and continues that trajectory for the first hour, that's +24 mg/dL of rise that has nothing to do with the meal. The adaptive service sees it as "BG rising more than predicted → under-dosed" and scales up remaining entries. The learning system sees the 1h and 2h checkpoints running high and nudges carbTau down (faster absorption → more upfront insulin next time).

Both responses are wrong. You're not under-dosed — you have a pre-existing rise the meal didn't cause. Over weeks of breakfasts, carbTau drifts lower for no physiological reason. The system is learning from contaminated signal.

This also happens with:

- **Active correction boluses** — BG is dropping pre-meal, which then gets attributed as "meal caused a drop" at the 1h checkpoint
- **Exercise-induced sensitivity changes** — BG falling from a recent workout
- **Rebound from a treated low** — BG rising from glucose tabs taken 30 minutes before the meal

**What Needs to Change**

Measure the BG slope in the 15 minutes before meal start. Subtract a bounded version of that slope from the first 1-2 hours of post-meal BG delta, linearly ramping the correction to zero by 2h. This removes the pre-existing trend from both the adaptive service's real-time error calculation and the learning system's checkpoint evaluation.

**How**

**Step 1: Capture pre-meal slope at meal recording time**

When the outcome is created, query the two CGM readings closest to (mealTime - 5min) and (mealTime - 15min). Compute the slope in mg/dL per 5 minutes. Store it as `preMealSlope` on the `V2MealOutcome`.

If fewer than 2 readings exist in that window, or if the readings are more than 10 minutes apart, set `preMealSlope = 0` (no correction — better to skip than use bad data).

**Step 2: Apply stability check**

Only apply the correction if the slope is stable — meaning the two 5-minute deltas in the 15-minute window don't diverge wildly. If one segment shows +3 and another shows -1, the trend isn't consistent and shouldn't be extrapolated. A simple check: if the variance between segments exceeds a threshold (say, the segments differ by more than 2 mg/dL/5min), discard and set slope to 0.

**Step 3: Cap the slope**

Clamp the stored slope to ±2 mg/dL per 5 minutes. This prevents an anomalous pre-meal reading (compression low, calibration jump) from generating a huge correction. A ±2 cap means the maximum correction at 1h is ±24 mg/dL, which is already generous — most dawn phenomenon is +1 to +1.5 mg/dL/5min.

Also cap the total cumulative correction to ±20 mg/dL. This is a second safety bound that catches edge cases where a moderate slope applied over many checkpoints accumulates too much.

**Step 4: Apply to adaptive service**

In `runAdaptiveCycle()`, when computing `actualBGDelta`:

```swift
let minutesSinceMeal = Date().timeIntervalSince(mealStart) / 60
let rampFactor: Double
if minutesSinceMeal <= 60 {
    rampFactor = 1.0  // full correction in first hour
} else if minutesSinceMeal <= 120 {
    rampFactor = 1.0 - (minutesSinceMeal - 60) / 60  // linear ramp to 0
} else {
    rampFactor = 0.0  // no correction after 2h
}

let slopeCorrection = preMealSlope * (minutesSinceMeal / 5.0) * rampFactor
let correctedDelta = actualBGDelta - clamp(slopeCorrection, -20, 20)
```

Use `correctedDelta` instead of `actualBGDelta` in the error calculation.

**Step 5: Apply to learning checkpoints**

The same correction applies to the 1h and 2h checkpoint evaluation in `recalculateCurveParameters()`. The 1h checkpoint gets the full slope subtracted (ramp = 1.0). The 2h checkpoint gets half (ramp = 0.5 at 120min... actually ramp hits 0 at 120min, so 2h gets zero correction — which is intentional because by 2h the meal's own absorption signal dominates).

Actually, rethinking: the ramp goes 1.0 at ≤60min, linear to 0.0 at 120min. So at exactly 120min (the 2h checkpoint), the correction is 0. The 1h checkpoint gets full correction. The 3h+ checkpoints get nothing. That's the right behavior — pre-meal trend only contaminates the early window.

**What This Doesn't Fix**

This doesn't help if the pre-meal trend *changes* at meal time — for example, if you were flat before eating but dawn phenomenon kicks in right as you eat. That's indistinguishable from meal absorption. But that's also a much rarer scenario than the common case of an established trend that continues through the meal's early absorption window.

**Core Data Impact**

One new optional Double attribute on `V2MealOutcomeStored` — `preMealSlope`. Lightweight migration, default nil, old meals get no correction (which is the safe default).

---

#### #2 — Garmin Demand Factor Feedback Loop

**The Problem**

The Garmin sensitivity model applies up to ±40% adjustment to insulin delivery based on sleep, stress, activity, and cardiovascular metrics. But there's no mechanism to evaluate whether those adjustments are actually helping. The weights are heuristics — educated guesses based on directional findings from the literature (Spiegel, Donga, Borghouts). The epistemic note in the whitepaper explicitly calls this out.

Right now, the only feedback path is Claude AI recalibration, which can suggest weight changes but runs weekly, requires manual approval, and analyzes aggregate patterns rather than directly measuring metric effectiveness. The rule-based learning system adjusts curve parameters (carbTau, proteinFactor, fatTotalCoeff) but never touches Garmin weights. This means curve parameters are absorbing Garmin model errors — if the sleep weight is too aggressive, carbTau drifts to compensate, which then causes errors on well-slept days.

**The Core Insight**

You can't compare "adjusted meals" to "unadjusted meals" directly because Garmin adjustments correlate with physiological state. People who get bad sleep actually *are* more insulin resistant — comparing their meals to well-rested meals confounds the Garmin adjustment with the real physiological effect. You'd be measuring biology, not model accuracy.

What you *can* measure is **within-group variance**: among meals where Garmin applied a meaningful adjustment (say, demand factor > 1.15 or < 0.88), is the magnitude of the adjustment correlated with checkpoint error? If the sleep weight is perfectly calibrated, meals with demand factor 1.3 and meals with demand factor 1.5 should have similar checkpoint errors (both compensated correctly). If the sleep weight is too low, the 1.5x meals should still run high (under-compensated), showing a positive correlation between demand factor and BG error.

**What Needs to Change**

Add a periodic analysis (weekly, run before rule-based learning) that computes the Pearson correlation between `insulinDemandFactor` and average checkpoint BG error across Garmin-adjusted meals. If the correlation is significantly positive (under-compensating) or negative (over-compensating), nudge the dominant Garmin weights in the appropriate direction.

**How**

**Step 1: Filter to Garmin-adjusted meals**

From the outcome store, pull all clean (non-confounded) meals from the analysis window where `insulinDemandFactor` deviates from 1.0 by more than a threshold — say, `|demandFactor - 1.0| > 0.12`. This gives you meals where Garmin was actively adjusting. Exclude meals with demand factor near 1.0 because they're in the model's "no adjustment" zone and add noise.

**Step 2: Compute per-meal average BG error**

For each meal, average the checkpoint errors using the same formula as the learning system (BG > 180: positive error, BG < 70: negative error, in-range: 0). Use only clean checkpoints. This gives you one error number per meal.

**Step 3: Compute Pearson correlation**

Correlate `demandFactor` with `averageCheckpointError` across the filtered meals. You need the stored Garmin contributions from #10 to break this down by metric later, but the first-order signal is the aggregate correlation.

**Step 4: Interpret and act**

| Correlation | Meaning | Action |
|-------------|---------|--------|
| r > +0.3 (significant positive) | Higher demand factor → higher BG error. Model under-compensating. | Garmin weights too conservative — needs larger adjustments |
| r < -0.3 (significant negative) | Higher demand factor → lower BG error. Model over-compensating. | Garmin weights too aggressive — needs smaller adjustments |
| -0.3 < r < +0.3 | No significant correlation | Model is calibrated reasonably well, or insufficient data |

Significance threshold: require at least 10 adjusted meals in the window before acting. Below that, the correlation is too noisy to be meaningful.

**Step 5: Nudge weights**

If the correlation is significant, apply a small uniform scaling to all negative-impact weights (sleep, stress, body battery, RHR, HRV) — the weights that push demand up:

```swift
let nudgeFactor = 1.0 + (correlation * 0.1)  // e.g., r=0.4 → scale weights by 1.04
for weight in negativeImpactWeights {
    weight *= nudgeFactor
}
```

The 0.1 multiplier keeps nudges small — even a strong correlation (r=0.5) only adjusts weights by 5%. Clamp all weights to their existing min/max ranges.

**Step 6: Per-metric breakdown (uses #10)**

Once aggregate correlation is working, break it down using the stored Garmin contributions. For each metric, compute the correlation between that metric's contribution and the checkpoint error. This tells you *which specific metric* is miscalibrated:

```
sleep_score_contribution vs error: r = +0.35 → sleep weight too conservative
body_battery_contribution vs error: r = -0.05 → well calibrated
stress_contribution vs error: r = +0.22 → mildly too conservative
```

This enables per-metric weight adjustment instead of uniform scaling. But the uniform scaling is a fine v1 — per-metric comes later.

**When It Runs**

Weekly, before rule-based learning runs. Order matters: fix Garmin weights first so curve parameters don't absorb Garmin errors. The sequence is:

1. Garmin feedback loop analyzes and adjusts weights
2. Rule-based learning runs with corrected demand factors
3. Claude AI recalibration (if triggered) sees both updated weights and curve parameters

**Safety Bounds**

- Maximum weight change per cycle: ±10% (the `× 0.1` multiplier handles this)
- Minimum sample size: 10 adjusted meals (below this, skip)
- Weight clamping: same ranges as Claude AI validation pipeline
- Persist adjustments to the same Garmin weights store Claude uses
- Log the correlation coefficient, sample size, and any weight changes for post-hoc analysis

**What This Doesn't Fix**

Per-metric correlation requires sufficient data per metric. If a user always sleeps badly AND is always stressed, those two metrics co-vary and you can't disentangle them with correlation alone. You'd need multivariate regression, which needs even more data. The uniform scaling approach sidesteps this — it doesn't try to identify which metric is wrong, just whether the aggregate adjustment magnitude is right.

The per-metric breakdown (#10 contributions) helps when metrics are somewhat independent — a user who has variable sleep but consistent stress gives you data to isolate the sleep weight. But fully entangled metrics remain a limitation until you have enough meals (50+) for multivariate analysis, which is likely a Claude AI task rather than an on-device computation.

**Core Data Impact**

No new entities or attributes needed. The analysis reads existing `V2MealOutcomeStored` records (demand factor, checkpoints, Garmin contributions from #10). Weight adjustments write to the existing Garmin weights store.

---

#### Implementation Order

**#5 first.** It's 2-3 hours, self-contained, and immediately improves data quality for both the adaptive service and the learning system. Every breakfast meal gets cleaner signal starting immediately.

**#2 second.** It depends on #10 (done) for per-metric breakdown, benefits from #5 (cleaner checkpoint data), and is the last piece before the learning system is architecturally complete. The v1 (aggregate correlation with uniform scaling) is ~3 hours. Per-metric breakdown is an additional 1-2 hours on top.

**~~Confounding meal detection scaling by macro load.~~** Implemented — small snacks (< 15g carbs AND < 5g fat) are now excluded from confounding detection. See §12 Confounding Meal Detection.

**~~Export re-derives Garmin contributions with current weights.~~** Implemented — per-metric Garmin contributions are now captured and stored at meal time in `V2MealOutcome.garminContributions`. The export uses stored contributions when available, falling back to re-derivation only for legacy outcomes recorded before this change.

### Acknowledged Tradeoffs

**The V2/V3 naming mismatch.** The codebase consistently uses "V2" naming (`V2MacroDosingSettings`, `V2MealOutcome`, `useV2MacroAbsorption`) while this document describes the system as "V3." This reflects the iterative development history — the code was written as "V2" (replacing V1 Warsaw Method), and this whitepaper documents the third major revision of the design. Renaming all code symbols would touch dozens of files with no functional benefit.

---

*This document describes the V3 Three-Curve Macro Absorption Engine as implemented in the Trio open-source automated insulin delivery system. The system is for research and personal use. It is not FDA-approved and should not be used as the sole basis for insulin dosing decisions without clinical oversight.*
