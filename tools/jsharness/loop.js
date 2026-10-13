'use strict';
// Runs one full loop (profile → iob → meal → determine-basal) exactly as the app sequences it.
const { OrefRunner } = require('./oref.js');
const synth = require('./synth.js');

function runLoop({ clockMs, glucoseShape = 'flat', pumpOpts = {}, carbOpts = {}, tempOpts = {}, prefOverrides = {}, customVars = {}, runner = null, autosens = { ratio: 1 }, reservoir = 300 }) {
  runner = runner || new OrefRunner({ timeZone: 'UTC' });
  const docs = synth.settingsDocuments({ preferences: prefOverrides });
  const profile = runner.profile({
    pumpSettings: docs.pumpSettings, bgTargets: docs.bgTargets, isf: docs.isf, basalProfile: docs.basalProfile,
    preferences: docs.preferences, carbRatio: docs.carbRatio, tempTargets: docs.tempTargets, model: docs.model,
    autotune: null, trioData: docs.trioData,
  }, clockMs).value;
  if (profile.error) throw new Error('profile: ' + profile.error);

  const glucose = synth.glucoseSeries(clockMs, glucoseShape);
  const pumpHistory = synth.pumpHistory(clockMs, pumpOpts);
  const carbs = synth.carbs(clockMs, carbOpts);
  const clock = synth.iso(clockMs);

  const iob = runner.iob({ pumpHistory, profile, clock, autosens }, clockMs).value;
  const meal = runner.meal({ pumpHistory, profile, clock, glucose, basalProfile: docs.basalProfile, carbs }, clockMs).value;
  const inputs = {
    iob, currentTemp: synth.currentTemp(clockMs, tempOpts), glucose, profile, autosens, meal, microBolusAllowed: true,
    reservoir, clock, pumpHistory, preferences: docs.preferences, basalProfile: docs.basalProfile,
    trioCustomOrefVariables: synth.trioCustomOrefVariables(clockMs, customVars),
    carbs, // not consumed by determine-basal (meal already absorbed it); kept so fixtures record it
  };
  const result = runner.determineBasal(inputs, clockMs);
  return { inputs, result, profile, iob, meal };
}

module.exports = { runLoop };
