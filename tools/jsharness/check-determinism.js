'use strict';
// Plan step S0.2 — proves the determinism edit to prepare/determine-basal.js is
// (1) effective: a recorded clock reproduces a loop byte-for-byte, and
// (2) behaviour-neutral: given the same clock, the old wrapper and the new wrapper
//     produce identical output.
// Exit code 1 on any failure. Run: node tools/jsharness/check-determinism.js
const { execFileSync } = require('child_process');
const path = require('path');
const { OrefRunner } = require('./oref.js');
const { runLoop } = require('./loop.js');

const REPO = path.resolve(__dirname, '../..');
const BASELINE_COMMIT = process.env.BASELINE_COMMIT || '6e3277848';
const T0 = Date.UTC(2026, 8, 15, 13, 0, 0); // a fixed historical instant

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
  if (!ok) failures++;
}

const scenarios = [
  { name: 'flat', glucoseShape: 'flat' },
  { name: 'rising+bolus', glucoseShape: 'rising', pumpOpts: { bolusUnitsAgoMin: [2, 90] } },
  { name: 'falling', glucoseShape: 'falling' },
  { name: 'high+tempbasal', glucoseShape: 'high', pumpOpts: { tempBasals: [[2.5, 30, 10]] }, tempOpts: { rate: 2.5, duration: 20, minAgo: 10 } },
  { name: 'carbs40g', glucoseShape: 'rising', carbOpts: { gramsAgoMin: [40, 45] } },
];

const newRunner = new OrefRunner({ timeZone: 'UTC' });
const oldWrapper = execFileSync('git', ['show', `${BASELINE_COMMIT}:Trio/Resources/javascript/prepare/determine-basal.js`], { cwd: REPO, encoding: 'utf8' });
const oldRunner = new OrefRunner({ timeZone: 'UTC', overrides: { 'prepare/determine-basal.js': oldWrapper } });

for (const sc of scenarios) {
  const a = runLoop({ clockMs: T0, runner: newRunner, ...sc });
  const b = runLoop({ clockMs: T0, runner: newRunner, ...sc });
  check(`[${sc.name}] same inputs → identical output`, a.result.raw === b.result.raw);
  check(`[${sc.name}] deliverAt equals the passed clock`, a.result.value.deliverAt === new Date(T0).toISOString(), a.result.value.deliverAt);

  // Behaviour-neutral: old wrapper under the same pinned clock produces identical bytes.
  const o = runLoop({ clockMs: T0, runner: oldRunner, ...sc });
  check(`[${sc.name}] old wrapper ≡ new wrapper under equal clock`, o.result.raw === a.result.raw);

  // Effectiveness: without a pinned clock, the OLD wrapper replays a historical loop with
  // wall-clock time (data looks stale → different decision); the NEW wrapper honours the
  // clock argument and still reproduces the pinned result for the clock-dependent fields.
  const inputs = a.inputs;
  const oldUnpinned = oldRunner.determineBasal(inputs, null).value;
  const newUnpinned = newRunner.determineBasal(inputs, null).value;
  check(`[${sc.name}] old wrapper without pinned clock drifts (demonstrates the bug)`, oldUnpinned.deliverAt !== a.result.value.deliverAt, `deliverAt=${oldUnpinned.deliverAt}`);
  check(`[${sc.name}] new wrapper without pinned clock still honours clock`, newUnpinned.deliverAt === a.result.value.deliverAt && newUnpinned.rate === a.result.value.rate && newUnpinned.units === a.result.value.units && newUnpinned.eventualBG === a.result.value.eventualBG);
}

// Clock as epoch milliseconds (the harness may pass numbers) must behave like the ISO string.
{
  const a = runLoop({ clockMs: T0, runner: newRunner, glucoseShape: 'rising' });
  const viaNumber = newRunner.determineBasal({ ...a.inputs, clock: T0 }, T0).value;
  check('clock as epoch ms ≡ clock as ISO string', viaNumber.deliverAt === a.result.value.deliverAt && viaNumber.eventualBG === a.result.value.eventualBG);
  // An unparseable clock must fall back to wall-clock time (pinned here to T0) without throwing.
  const garbage = newRunner.determineBasal({ ...a.inputs, clock: 'not-a-date' }, T0).value;
  check('unparseable clock falls back to wall clock without throwing', garbage.deliverAt === a.result.value.deliverAt && garbage.eventualBG === a.result.value.eventualBG);
}

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
