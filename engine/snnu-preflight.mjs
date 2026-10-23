// Shared portal inspection. The preflight CLI only performs credential-free GETs.
import http from 'node:http';
import https from 'node:https';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export async function loadSnnuResearchProfile() {
  const rule = JSON.parse((await readFile(new URL('../adapters/snnu.json', import.meta.url), 'utf8')).replace(/^\uFEFF/, ''));
  if (rule.id !== 'snnu' || rule.enabled !== false || !['research', 'snnu-jsp'].includes(rule.kind)) throw new Error('NOT_A_RESEARCH_RULE');
  return rule.researchProfile;
}
export function validateSnnuProfile(profile) {
  if (!profile || profile.schemaVersion !== 1 || !['read-only-preflight', 'snnu-jsp'].includes(profile.mode)) throw new Error('INVALID_PREFLIGHT_PROFILE');
  const paths = [profile.loginPage, profile.statusPage];
  if (paths[0] !== '/snnuportal/login.jsp' || paths[1] !== '/snnuportal/userstatus.jsp' || profile.loginAction !== '/snnuportal/login') throw new Error('INVALID_PORTAL_PATH');
  if (!Array.isArray(profile.allowedOrigins) || !profile.allowedOrigins.length || profile.allowedOrigins.length > 32) throw new Error('INVALID_PORTAL_ORIGINS');
  for (const origin of profile.allowedOrigins) {
    const u = new URL(origin);
    if (u.origin !== origin || u.protocol !== 'http:' || !['202.117.144.205', 'net.snnu.edu.cn'].includes(u.hostname)) throw new Error('INVALID_PORTAL_ORIGIN');
  }
  if (!Array.isArray(profile.roots) || !profile.roots.length || profile.roots.length > 2 || profile.roots.some(u => !trusted(profile, u) || new URL(u).pathname !== '/')) throw new Error('INVALID_PORTAL_ROOT');
  if (!Array.isArray(profile.services) || profile.services.some(s => typeof s.value !== 'string')) throw new Error('INVALID_SERVICE_VALUES');
  if (!profile.services.length || new Set(profile.services.map(s => s.value)).size !== profile.services.length || profile.formMethod !== 'POST') throw new Error('INVALID_SERVICE_VALUES');
  for (const key of ['usernameField', 'passwordField', 'serviceField', 'captchaField']) {
    if (!/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/.test(profile[key] || '')) throw new Error('INVALID_FORM_FIELD');
  }
  return profile;
}
export function trusted(profile, value) {
  try { const u = new URL(value); return !u.username && !u.password && profile.allowedOrigins.includes(u.origin); }
  catch { return false; }
}
function readable(profile, value) {
  if (!trusted(profile, value)) return false;
  const u = new URL(value);
  return !u.search && !u.hash && ['/', profile.loginPage, profile.statusPage].includes(u.pathname);
}
function entities(value) {
  return value.replace(/&(?:amp|quot|apos|lt|gt|#\d+|#x[\da-f]+);/gi, code => {
    const named = { '&amp;': '&', '&quot;': '"', '&apos;': "'", '&lt;': '<', '&gt;': '>' };
    if (named[code.toLowerCase()]) return named[code.toLowerCase()];
    const n = Number.parseInt(code.slice(code[2].toLowerCase() === 'x' ? 3 : 2, -1), code[2].toLowerCase() === 'x' ? 16 : 10);
    return n >= 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '';
  });
}
function attrs(text) {
  const result = {};
  for (const m of text.matchAll(/([^\s=/'">]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) result[m[1].toLowerCase()] = entities(m[2] ?? m[3] ?? m[4] ?? '');
  return result;
}
const inputPattern = /<input\b((?:"[^"]*"|'[^']*'|[^'">])*)>/gi;
function stripped(html) { return html.replace(/<!--[\s\S]*?-->/g, '').replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, ''); }
export function portalText(html) { return entities(stripped(html).replace(/<[^>]*>/g, ' ')); }
function inputsIn(html) { return [...html.matchAll(inputPattern)].map(m => { const a = attrs(m[1]); a.type = (a.type || 'text').toLowerCase(); return a; }); }
export function findSnnuLoginForm(profile, html) {
  const clean = stripped(html);
  for (const match of clean.matchAll(/<form\b((?:"[^"]*"|'[^']*'|[^'">])*)>([\s\S]*?)<\/form>/gi)) {
    const fields = inputsIn(match[2]);
    if (fields.some(i => i.name === profile.usernameField) && fields.some(i => i.name === profile.passwordField && i.type === 'password'))
      return { attributes: attrs(match[1]), fields, hasBase: /<base\b/i.test(clean) };
  }
  return null;
}
export function portalAccount(profile, html) {
  return inputsIn(stripped(html)).find(i => i.type === 'hidden' && i.id === profile.onlineAccountId)?.value || '';
}
export function inspectSnnuPage(profile, url, html) {
  if (!readable(profile, url)) return { Code: 'UNTRUSTED_PAGE' };
  const clean = stripped(html);
  const inputs = inputsIn(clean);
  const account = inputs.find(i => i.type === 'hidden' && i.id === profile.onlineAccountId && i.value);
  if (account && clean.replace(/<[^>]*>/g, ' ').includes(profile.onlineText)) return { Code: 'PORTAL_SESSION_PRESENT' };
  const parsed = findSnnuLoginForm(profile, clean);
  if (parsed) {
    const form = parsed.attributes, fields = parsed.fields;
    // A <base> changes relative form targets. This prototype refuses it.
    if (/<base\b/i.test(clean)) return { Code: 'UNSUPPORTED_BASE_ELEMENT' };
    let action;
    try { action = new URL(form.action || url, url); } catch { return { Code: 'UNTRUSTED_FORM_ACTION' }; }
    if (!trusted(profile, action.href) || action.origin !== new URL(url).origin || action.pathname !== profile.loginAction || action.search || action.hash) return { Code: 'UNTRUSTED_FORM_ACTION' };
    if ((form.method || 'GET').toUpperCase() !== profile.formMethod) return { Code: 'UNEXPECTED_FORM_METHOD' };
    const services = fields.filter(i => i.name === profile.serviceField && i.type === 'radio').map(i => i.value ?? '');
    if (!services.length || services.some(value => !profile.services.some(s => s.value === value))) return { Code: 'UNKNOWN_SERVICE_VALUES' };
    return { Code: fields.some(i => i.name === profile.captchaField) ? 'CAPTCHA_REQUIRED' : 'PORTAL_FORM_READY',
      PortalOrigin: new URL(url).origin, LoginPath: new URL(url).pathname, SubmitPath: action.pathname,
      FieldNames: [...new Set(fields.map(i => i.name).filter(Boolean))], ServiceValues: services,
      HiddenFieldNames: fields.filter(i => i.type === 'hidden').map(i => i.name).filter(Boolean) };
  }
  return { Code: 'PORTAL_PAGE_UNRECOGNIZED' };
}
export function decodePortalBody(body, contentType = '', fallback = 'gb2312') {
  if (typeof body === 'string') return body;
  const encoding = /charset\s*=\s*["']?([\w-]+)/i.exec(contentType)?.[1] || fallback;
  try { return new TextDecoder(encoding).decode(body); }
  catch { return new TextDecoder(fallback).decode(body); }
}
function redirectInHtml(html) {
  const clean = html.replace(/<!--[\s\S]*?-->/g, '');
  const js = /(?:\b(?:window|document)\.)?location(?:\.href)?\s*=\s*(["'])([^"']+)\1/i.exec(clean);
  if (js) return entities(js[2]);
  const call = /(?:\bwindow\.)?location\.(?:replace|assign)\s*\(\s*(["'])([^"']+)\1/i.exec(clean);
  if (call) return entities(call[2]);
  for (const m of clean.matchAll(/<meta\b((?:"[^"]*"|'[^']*'|[^'">])*)>/gi)) {
    const a = attrs(m[1]);
    if (a['http-equiv']?.toLowerCase() === 'refresh') return /url\s*=\s*["']?([^"']+)/i.exec(a.content || '')?.[1]?.trim();
  }
  return null;
}
// Node's native request does not apply Windows system proxy or proxy env vars.
export function directPortalRequest(url, { timeoutMs = 3000, cookie, method = 'GET', body, headers = {} }) {
  return new Promise((resolve, reject) => {
    if (!['GET', 'POST'].includes(method) || (body && method !== 'POST')) { reject(new Error('INVALID_HTTP_METHOD')); return; }
    const u = new URL(url);
    const req = (u.protocol === 'https:' ? https : http).request(u, {
      method, agent: false, headers: { 'User-Agent': 'CampusLuma-PortalClient/0.1', ...headers, ...(cookie ? { Cookie: cookie } : {}) }
    }, res => {
      const parts = []; let size = 0;
      res.on('data', part => { size += part.length; if (size > 256 * 1024) req.destroy(new Error('BODY_LIMIT')); else parts.push(part); });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(parts) }));
      res.on('error', reject);
    });
    const timer = setTimeout(() => { const error = new Error('REQUEST_TIMEOUT'); error.name = 'TimeoutError'; req.destroy(error); }, timeoutMs);
    req.on('close', () => clearTimeout(timer)); req.on('error', reject); req.end(body);
  });
}
export async function preflightSnnu(profile, { request = directPortalRequest, preferredPortal, timeoutMs = 1500, totalMs = 15000, maxRequests = 10 } = {}) {
  validateSnnuProfile(profile);
  const started = Date.now(), cookies = new Map(); let count = 0;
  const finish = result => ({ ...result, ReadOnly: true, CredentialSubmission: false, Requests: count });
  const preferred = [];
  if (preferredPortal !== undefined && preferredPortal !== null && preferredPortal !== '') {
    if (typeof preferredPortal !== 'string' || !trusted(profile, preferredPortal)) return finish({ Code: 'UNTRUSTED_PORTAL' });
    const u = new URL(preferredPortal);
    if (!['/', profile.loginPage, profile.loginAction, profile.statusPage].includes(u.pathname)) return finish({ Code: 'UNTRUSTED_PORTAL' });
    // The supplied /login is a submission target, not an existing form session.
    // Read a fresh form on the same registered origin; never replay query values.
    preferred.push(u.origin + (u.pathname === '/' ? '/' : profile.loginPage));
  }
  async function visit(initial) {
    let url = initial;
    const seen = new Set();
    for (let hops = 0; hops < 4; hops++) {
      if (!readable(profile, url)) return { Code: 'UNTRUSTED_REDIRECT' };
      if (seen.has(url)) return { Code: 'REDIRECT_LOOP' }; seen.add(url);
      const remaining = totalMs - (Date.now() - started);
      if (count >= maxRequests || remaining <= 0) return { Code: 'PREFLIGHT_BUDGET_EXHAUSTED' };
      count++;
      let page;
      try { page = await request(url, { timeoutMs: Math.min(timeoutMs, remaining), cookie: cookies.get(new URL(url).hostname) }); }
      catch { return { Code: 'PORTAL_UNREACHABLE' }; }
      const setCookie = page.headers?.['set-cookie'];
      if (setCookie) {
        const session = (Array.isArray(setCookie) ? setCookie : [setCookie]).map(s => /^JSESSIONID=[^;\r\n]+/i.exec(s)?.[0]).find(Boolean);
        if (session) cookies.set(new URL(url).hostname, session);
      }
      const html = decodePortalBody(page.body, page.headers?.['content-type'], profile.responseEncoding);
      const target = page.status >= 300 && page.status < 400 ? page.headers?.location : (page.status === 200 ? redirectInHtml(html) : null);
      if (target) {
        try { url = new URL(target, url).href; } catch { return { Code: 'UNTRUSTED_REDIRECT' }; }
        continue;
      }
      if (page.status !== 200) return { Code: 'PORTAL_HTTP_ERROR' };
      return inspectSnnuPage(profile, url, html);
    }
    return { Code: 'REDIRECT_LIMIT' };
  }
  const candidates = [...new Set([...preferred, ...profile.roots, ...profile.allowedOrigins.filter(o => new URL(o).port).map(o => o + profile.loginPage)])];
  let last = { Code: 'PORTAL_UNREACHABLE' };
  for (const url of candidates) {
    last = await visit(url);
    if (['PORTAL_FORM_READY', 'PORTAL_SESSION_PRESENT', 'CAPTCHA_REQUIRED', 'UNTRUSTED_REDIRECT', 'UNTRUSTED_FORM_ACTION', 'UNKNOWN_SERVICE_VALUES', 'UNEXPECTED_FORM_METHOD', 'UNSUPPORTED_BASE_ELEMENT', 'PREFLIGHT_BUDGET_EXHAUSTED'].includes(last.Code)) return finish(last);
  }
  return finish(last);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { const result = await preflightSnnu(await loadSnnuResearchProfile()); console.log(JSON.stringify(result)); process.exitCode = ['PORTAL_FORM_READY', 'PORTAL_SESSION_PRESENT'].includes(result.Code) ? 0 : 2; }
  catch (error) { console.log(JSON.stringify({ Code: 'PREFLIGHT_ERROR', ReadOnly: true, CredentialSubmission: false, ErrorType: error.name })); process.exitCode = 2; }
}
