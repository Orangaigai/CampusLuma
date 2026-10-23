import { readFile } from 'node:fs/promises';
import { validateSnnuProfile } from './snnu-preflight.mjs';
import { validateDrcomProfile } from './drcom-profile.mjs';
import { validateBrowserExtensions } from './browser-profile.mjs';

const idPattern = /^[a-z][a-z0-9_-]{0,47}$/;
export function validateSchoolRule(input) {
  const rule = JSON.parse(JSON.stringify(input));
  if (rule.schemaVersion !== 1 || !idPattern.test(rule.id || '') || typeof rule.name !== 'string' || !rule.name) throw new Error('INVALID_SCHOOL_RULE');
  if (rule.enabled !== true) throw new Error('SCHOOL_NOT_ENABLED');
  if (!['browser', 'snnu-jsp', 'drcom-query', 'drcom-aes'].includes(rule.kind) || rule.entry !== 'engine/campus-network-reconnect.ps1') throw new Error('UNSUPPORTED_SCHOOL_ENGINE');
  if (!Array.isArray(rule.trustedOrigins) || !rule.trustedOrigins.length || rule.trustedOrigins.length > 32) throw new Error('INVALID_TRUSTED_ORIGINS');
  for (const origin of rule.trustedOrigins) {
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || origin.replace(/\/$/, '') !== url.origin) throw new Error('INVALID_TRUSTED_ORIGIN');
  }
  rule.trustedOrigins = rule.trustedOrigins.map(value => new URL(value).origin);
  const allowed = value => {
    try { const u = new URL(value); return !u.username && !u.password && rule.trustedOrigins.includes(u.origin); } catch { return false; }
  };
  if (!allowed(rule.fallbackPortal)) throw new Error('UNTRUSTED_SCHOOL_ENTRY');
  if (rule.kind.startsWith('drcom-')) { validateDrcomProfile(rule); return rule; }
  if (rule.kind === 'snnu-jsp') {
    if (rule.id !== 'snnu') throw new Error('INVALID_SNNU_RULE');
    validateSnnuProfile(rule.researchProfile);
    if (rule.researchProfile.mode !== 'snnu-jsp' || rule.researchProfile.requestEncoding !== 'gb2312' || rule.researchProfile.responseEncoding !== 'gb2312') throw new Error('INVALID_SNNU_ENCODING');
    const origins = rule.researchProfile.allowedOrigins;
    if (origins.length !== rule.trustedOrigins.length || origins.some(o => !rule.trustedOrigins.includes(o))) throw new Error('INCONSISTENT_PORTAL_ORIGINS');
    return rule;
  }
  if (!rule.browser || (rule.browser.selfServiceUrl && !allowed(rule.browser.selfServiceUrl))) throw new Error('UNTRUSTED_SCHOOL_ENTRY');
  validateBrowserExtensions(rule);
  if (rule.browser.selfServiceUrl && (!rule.browser.selfService || !Array.isArray(rule.browser.selfService.readyTexts) || !rule.browser.selfService.readyTexts.length)) throw new Error('INVALID_SELF_SERVICE_RULE');
  for (const key of ['usernameSelectors', 'passwordSelectors', 'submitSelectors', 'captchaSelectors', 'captchaImageSelectors']) {
    const selectors = rule.browser[key];
    if (!Array.isArray(selectors) || !selectors.length || selectors.length > 32 || selectors.some(s => typeof s !== 'string' || !s.trim() || s.length > 512)) throw new Error('INVALID_FORM_SELECTORS');
  }
  if (typeof rule.browser.agreementPattern !== 'string' || !rule.browser.agreementPattern || rule.browser.agreementPattern.length > 1000) throw new Error('INVALID_AGREEMENT_PATTERN');
  new RegExp(rule.browser.agreementPattern, 'i');
  if (!Array.isArray(rule.browser.discoveryProbes) || rule.browser.discoveryProbes.length > 8) throw new Error('INVALID_DISCOVERY_PROBES');
  for (const value of rule.browser.discoveryProbes) {
    const u = new URL(value); if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password) throw new Error('INVALID_DISCOVERY_PROBE');
  }
  return rule;
}
export async function loadSchoolRule(id = 'xtu') {
  if (!idPattern.test(id)) throw new Error('INVALID_SCHOOL_ID');
  const url = new URL('../adapters/' + id + '.json', import.meta.url);
  const text = await readFile(url, 'utf8');
  if (text.length > 128 * 1024) throw new Error('SCHOOL_RULE_TOO_LARGE');
  const rule = validateSchoolRule(JSON.parse(text.replace(/^\uFEFF/, '')));
  if (rule.id !== id) throw new Error('SCHOOL_ID_MISMATCH');
  return rule;
}
