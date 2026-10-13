'use strict';
// Generates the golden scenario fixtures for AlgorithmKit's tests from the Node harness.
// Each fixture holds the exact input documents, the clock, and the output the JavaScript
// produced here. AlgorithmKit runs the same scripts in JavaScriptCore and must match.
// Scenarios also carry named assertions that pin *current* oref behaviour (plan S0.2
// "OrefScenarioTests"), so a later change that alters a decision fails loudly.
//
// Run: node tools/jsharness/make-fixtures.js   (writes AlgorithmKit/Tests/AlgorithmKitTests/Fixtures/scenarios)
const fs = require('fs');
const path = require('path');
const { OrefRunner } = require('./oref.js');
const { runLoop } = require('./loop.js');
const synth = require('./synth.js');

const OUT = path.resolve(__dirname, '../../AlgorithmKit/Tests/AlgorithmKitTests/Fixtures/scenarios');
const T0 = Date.UTC(2026, 8, 15, 13, 0, 0);
const runner = new OrefRunner({ timeZone: 'UTC' });

// A sensor jump of +50 mg/dL in one reading: maxDelta (50) > 0.2 × bg (150 → 30) disables SMBs.
synth.glucoseSeriesJump = (clockMs) => {
  const s = synth.glucoseSeries(clockMs, 'flat');
  s.forEach((g, i) => { g.sgv = i === 0 ? 160 : 110; });
  return s;
};

const scenarios = [
  {
    name: 'flat_in_range',
    loop: { glucoseShape: 'flat' },
    assertions: [{ field: 'insulinReq', op: '==', value: 0.2 }, { field: 'units', op: '==', value: 0.1 }],
    note: 'Flat 110 vs target 100 with no insulin on board: insulinReq 0.2 U, SMB = floor(0.2 × 0.5) = 0.1 U.',
  },
  {
    name: 'rising_smb_capped_at_basal_x_30min',
    loop: { glucoseShape: 'rising', pumpOpts: { bolusUnitsAgoMin: [2, 90] } },
    assertions: [{ field: 'units', op: '==', value: 0.5 }, { field: 'insulinReq', op: '>=', value: 1.0 }],
    note: 'determine-basal.js:1744-1822 — SMB = min(insulinReq × 0.5, basal × 30/60 U) = 0.5 U at basal 1.0.',
  },
  {
    name: 'high_smb_half_of_insulinReq',
    loop: { glucoseShape: 'high', prefOverrides: { maxSMBBasalMinutes: 120, maxUAMSMBBasalMinutes: 120 } },
    assertions: [{ field: 'units', op: 'halfOf', value: 'insulinReq', tolerance: 0.1 }],
    note: 'With the minutes cap lifted, SMB is floor(insulinReq × smb_delivery_ratio 0.5) to 0.1 U.',
  },
  {
    name: 'falling_zero_temp_below_threshold',
    loop: { glucoseShape: 'falling' },
    assertions: [{ field: 'rate', op: '==', value: 0 }, { field: 'duration', op: '>=', value: 30 }, { field: 'units', op: 'absent' }],
    note: 'determine-basal.js:1407-1430 — minGuardBG below threshold → zero temp, no SMB.',
  },
  {
    name: 'sensor_jump_disables_smb',
    loop: { glucoseShape: 'flat', glucoseOverride: 'jump' },
    assertions: [{ field: 'units', op: 'absent' }, { field: 'reason', op: 'contains', value: 'maxDelta' }],
    note: 'determine-basal.js:1369-1380 — maxDelta > 20% of BG disables SMB for this loop.',
  },
  {
    name: 'meal_window_raises_ratio_and_minutes',
    loop: { glucoseShape: 'rising', pumpOpts: { bolusUnitsAgoMin: [2, 90] }, customVars: { mealWindowActive: true, mealWindowMinutesRemaining: 60, toughMealActive: true, toughMealMinutesRemaining: 60 } },
    assertions: [{ field: 'units', op: '>', value: 0.5 }],
    note: 'Fork hunk: meal window → SMB ratio 0.8 and minutes ×2, so the SMB exceeds the baseline 0.5 U.',
  },
  {
    name: 'carbs40g_cob_prediction',
    loop: { glucoseShape: 'rising', carbOpts: { gramsAgoMin: [40, 45] } },
    assertions: [{ field: 'COB', op: '>', value: 0 }],
    note: 'Entered carbs are absorbed per cob.js; COB > 0 and the COB curve is present.',
  },
  {
    name: 'stale_glucose_no_decision',
    loop: { glucoseShape: 'flat', clockOffsetMin: 20 },
    assertions: [{ field: 'reason', op: 'contains', value: 'BG data is too old' }],
    note: 'determine-basal.js:534-579 — newest reading older than 12 minutes → no new temp.',
  },
];

fs.mkdirSync(OUT, { recursive: true });
for (const sc of scenarios) {
  const clockMs = T0 + (sc.loop.clockOffsetMin || 0) * 60000;
  let res;
  if (sc.loop.glucoseOverride === 'jump') {
    const base = runLoop({ clockMs: T0, runner, glucoseShape: 'flat' });
    const inputs = { ...base.inputs, glucose: synth.glucoseSeriesJump(T0) };
    // meal must be recomputed with the jumped glucose, as the app would
    const meal = runner.meal({ pumpHistory: inputs.pumpHistory, profile: inputs.profile, clock: inputs.clock, glucose: inputs.glucose, basalProfile: inputs.basalProfile, carbs: [] }, T0).value;
    inputs.meal = meal;
    res = { inputs, result: runner.determineBasal(inputs, T0), iob: inputs.iob, meal };
  } else if (sc.loop.clockOffsetMin) {
    // Glucose/pump data generated at T0, but the loop runs later: iob and meal must be
    // recomputed at the shifted clock, exactly as the app (and JSOrefCore.run) do.
    const base = runLoop({ clockMs: T0, runner, ...sc.loop });
    const clock = synth.iso(clockMs);
    const iob = runner.iob({ pumpHistory: base.inputs.pumpHistory, profile: base.inputs.profile, clock, autosens: base.inputs.autosens }, clockMs).value;
    const meal = runner.meal({ pumpHistory: base.inputs.pumpHistory, profile: base.inputs.profile, clock, glucose: base.inputs.glucose, basalProfile: base.inputs.basalProfile, carbs: base.inputs.carbs || [] }, clockMs).value;
    const inputs = { ...base.inputs, clock, iob, meal };
    res = { inputs, result: runner.determineBasal(inputs, clockMs), iob, meal };
  } else {
    res = runLoop({ clockMs, runner, ...sc.loop });
  }
  const { inputs, result } = res;
  const fixture = {
    name: sc.name,
    note: sc.note,
    clock: inputs.clock,
    timeZone: 'UTC',
    inputs: {
      glucose: inputs.glucose,
      pumpHistory: inputs.pumpHistory,
      carbs: inputs.carbs || [],
      profile: inputs.profile,
      basalProfile: inputs.basalProfile,
      autosens: inputs.autosens,
      reservoir: inputs.reservoir,
      preferences: inputs.preferences,
      trioCustomOrefVariables: inputs.trioCustomOrefVariables,
      currentTemp: inputs.currentTemp,
      microBolusAllowed: true,
    },
    expected: { iob: res.iob, meal: res.meal, determination: result.value },
    assertions: sc.assertions,
  };
  fs.writeFileSync(path.join(OUT, `${sc.name}.json`), JSON.stringify(fixture, null, 2));
  const v = result.value;
  console.log(`${sc.name}: rate=${v.rate} dur=${v.duration} units=${v.units} eventualBG=${v.eventualBG} insulinReq=${v.insulinReq} COB=${v.COB}`);
}
// loop.js needs to pass carbs through for fixtures; it already stores inputs.carbs via meal call args
