import { loadSchoolRule, validateSchoolRule } from './school-rules.mjs';
import { pathToFileURL } from 'node:url';

export async function authenticateSchool(inputRule, payload, options = {}) {
  const rule = validateSchoolRule(inputRule);
  if (payload.schoolId && payload.schoolId !== rule.id) return { Code: 'CREDENTIAL_SCHOOL_MISMATCH', Submitted: false };
  if (rule.kind.startsWith('drcom-')) {
    const { authenticateDrcom } = await import('./drcom-auth.mjs');
    return authenticateDrcom(rule, payload, options);
  }
  if (rule.kind === 'snnu-jsp') {
    const { authenticateSnnu } = await import('./snnu-auth.mjs');
    return authenticateSnnu(rule, payload, options);
  }
  const { createBrowserAdapter } = await import('./browser-auth.mjs');
  return createBrowserAdapter(rule, options).authenticate(payload);
}
export async function runProviderCli({ loadRule = loadSchoolRule, ...options } = {}) {
  let input = '', payload, rule, result;
  try {
    for await (const part of process.stdin) {
      input += part.toString('utf8');
      if (Buffer.byteLength(input, 'utf8') > 64 * 1024) throw new Error('REQUEST_TOO_LARGE');
    }
    payload = JSON.parse(input.replace(/^\uFEFF/, '')); input = '';
    rule = await loadRule(payload.schoolId || 'xtu');
    result = await authenticateSchool(rule, payload, options);
  } catch (error) {
    const safe = ['SCHOOL_NOT_ENABLED', 'INVALID_SCHOOL_ID', 'INVALID_SCHOOL_RULE', 'REQUEST_TOO_LARGE', 'UNSUPPORTED_SCHOOL_ENGINE'];
    result = { Code: safe.includes(error.message) ? error.message : error.code === 'ERR_MODULE_NOT_FOUND'
      ? (rule?.kind === 'browser' ? 'BROWSER_DEPENDENCIES_MISSING' : 'AUTH_DEPENDENCIES_MISSING') : 'SCHOOL_OR_BROWSER_PROVIDER_ERROR', Submitted: false };
  } finally { input = ''; if (payload) payload.password = ''; }
  process.stdout.write(JSON.stringify(result) + '\n');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await runProviderCli();
