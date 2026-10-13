'use strict';
// Node runner for the exact JavaScript the app evaluates (Trio/Resources/javascript).
// Mirrors the script batches in Trio/Sources/APS/OpenAPS/OpenAPS.swift so that a
// loop can be re-executed outside the app. Used by tools/jsharness/check-determinism.js
// and as the reference for AlgorithmKit's JSOrefCore (which does the same in JavaScriptCore).
//
// Determinism: a `Date` shim is installed in the context. When a clock is pinned,
// `new Date()` (no arguments) and `Date.now()` return the pinned instant, so the
// wall-clock fallbacks inside the minified bundles (profile schedule lookups,
// autosens 24h anchor, iob fallback) become functions of the tick clock.

const vm = require('vm');
const fs = require('fs');
const path = require('path');

const DEFAULT_ROOT = path.resolve(__dirname, '../../Trio/Resources/javascript');

const CLOCK_SHIM = `
(function () {
  const RealDate = Date;
  let pinned = null;
  class ShimDate extends RealDate {
    constructor(...args) {
      if (args.length === 0 && pinned !== null) { super(pinned); } else { super(...args); }
    }
    static now() { return pinned !== null ? pinned : RealDate.now(); }
  }
  globalThis.Date = ShimDate;
  globalThis.__pinClock = function (ms) { pinned = (ms === null || ms === undefined) ? null : Number(ms); };
})();
`;

const BATCHES = {
  profile: ['prepare/log.js', 'bundle/profile.js', 'prepare/profile.js'],
  iob: ['prepare/log.js', 'bundle/iob.js', 'prepare/iob.js'],
  meal: ['prepare/log.js', 'bundle/meal.js', 'prepare/meal.js'],
  autosens: ['prepare/log.js', 'bundle/autosens.js', 'prepare/autosens.js'],
  determineBasal: [
    'prepare/log.js',
    'prepare/determine-basal.js',
    'bundle/basal-set-temp.js',
    'bundle/glucose-get-last.js',
    'bundle/determine-basal.js',
    'middleware/determine_basal.js',
  ],
};

class OrefRunner {
  constructor({ root = DEFAULT_ROOT, overrides = {}, timeZone = null, log = () => {} } = {}) {
    this.root = root;
    this.overrides = overrides; // { 'prepare/determine-basal.js': '<source text>' }
    this.log = log;
    if (timeZone) process.env.TZ = timeZone; // schedule lookups use process-local time
  }

  source(name) {
    if (this.overrides[name] !== undefined) return this.overrides[name];
    return fs.readFileSync(path.join(this.root, name), 'utf8');
  }

  // Fresh context per call: no state leaks between loops (the app reuses pooled
  // contexts; the scripts redefine their globals on every batch so this is equivalent).
  makeContext(batch) {
    const logs = [];
    const ctx = { _consoleLog: (args) => logs.push(String(args)) };
    vm.createContext(ctx);
    vm.runInContext(CLOCK_SHIM, ctx, { filename: 'clock-shim.js' });
    for (const name of BATCHES[batch]) {
      vm.runInContext(this.source(name), ctx, { filename: name });
    }
    return { ctx, logs };
  }

  call(batch, fn, args, clockMs = null) {
    const { ctx, logs } = this.makeContext(batch);
    ctx.__pinClock(clockMs);
    // Same encoding the app uses: arguments are JSON text, result is JSON.stringify(..., null, 4).
    const joined = args.map((a) => JSON.stringify(a)).join(',');
    const raw = vm.runInContext(`JSON.stringify(${fn}(${joined}), null, 4);`, ctx, { filename: `${batch}-call` });
    this.log(batch, logs);
    return { raw, value: raw === undefined ? undefined : JSON.parse(raw), logs };
  }

  profile({ pumpSettings, bgTargets, isf, basalProfile, preferences, carbRatio, tempTargets, model, autotune, trioData }, clockMs) {
    return this.call('profile', 'generate', [pumpSettings, bgTargets, isf, basalProfile, preferences, carbRatio, tempTargets, model, autotune, trioData], clockMs);
  }
  iob({ pumpHistory, profile, clock, autosens }, clockMs) {
    return this.call('iob', 'generate', [pumpHistory, profile, clock, autosens], clockMs);
  }
  meal({ pumpHistory, profile, clock, glucose, basalProfile, carbs }, clockMs) {
    return this.call('meal', 'generate', [pumpHistory, profile, clock, glucose, basalProfile, carbs], clockMs);
  }
  autosens({ glucose, pumpHistory, basalProfile, profile, carbs, tempTargets }, clockMs) {
    return this.call('autosens', 'generate', [glucose, pumpHistory, basalProfile, profile, carbs, tempTargets], clockMs);
  }
  determineBasal({ iob, currentTemp, glucose, profile, autosens, meal, microBolusAllowed, reservoir, clock, pumpHistory, preferences, basalProfile, trioCustomOrefVariables }, clockMs) {
    return this.call('determineBasal', 'generate', [iob, currentTemp, glucose, profile, autosens, meal, microBolusAllowed, reservoir, clock, pumpHistory, preferences, basalProfile, trioCustomOrefVariables], clockMs);
  }
}

module.exports = { OrefRunner, BATCHES, DEFAULT_ROOT };
