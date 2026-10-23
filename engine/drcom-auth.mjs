import { createCipheriv, randomInt } from 'node:crypto';
import { isIP } from 'node:net';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';
import { validateDrcomProfile } from './drcom-profile.mjs';
import { validateSchoolRule } from './school-rules.mjs';
import { directPortalRequest, decodePortalBody } from './snnu-preflight.mjs';
import { testInternet } from './connectivity.mjs';

const probes = ['http://www.msftconnecttest.com/connecttest.txt', 'http://www.163.com/'];
function allowed(rule, value) {
  try { const u = new URL(value); return !u.username && !u.password && rule.trustedOrigins.includes(u.origin); } catch { return false; }
}
function readable(rule, value, script = false) {
  if (!allowed(rule, value)) return false;
  const u = new URL(value);
  if (/\/(?:login|logout|online_list|loadConfig|bind|unbind)(?:\/|$)/i.test(u.pathname)) return false;
  return script ? /\.js$/i.test(u.pathname) : u.pathname === '/' || /\.(?:html?|jsp)$/i.test(u.pathname);
}
function redirect(html) {
  return /(?:\b(?:window|document)\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']/i.exec(html)?.[1]
    || /<meta\b[^>]*content\s*=\s*["'][^"']*url=([^"';>]+)/i.exec(html)?.[1];
}
function validIpv4(value) {
  if (typeof value !== 'string' || isIP(value) !== 4) return false;
  const [a, b] = value.split('.').map(Number);
  return a === 10 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168;
}
export function validateNetwork(network) {
  if (!network || !validIpv4(network.ipv4) || typeof network.mac !== 'string') return null;
  const mac = network.mac.replace(/[:-]/g, '').toLowerCase();
  if (!/^[0-9a-f]{12}$/.test(mac) || /^(0{12}|f{12})$/.test(mac)) return null;
  return { ipv4: network.ipv4, mac };
}
export function parseJsonp(text, callback) {
  if (typeof text !== 'string' || text.length > 256 * 1024) throw new Error('INVALID_PORTAL_RESPONSE');
  text = text.replace(/^\uFEFF/, '').trim();
  if (!text.startsWith('{')) {
    const escaped = callback.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = new RegExp('^' + escaped + '\\s*\\(([\\s\\S]*)\\)\\s*;?$').exec(text);
    if (!match) throw new Error('INVALID_PORTAL_RESPONSE');
    text = match[1];
  }
  const value = JSON.parse(text);
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('INVALID_PORTAL_RESPONSE');
  return value;
}
export function classifyDrcomResponse(response) {
  let text = [response.msg, response.message, response.error].filter(v => typeof v === 'string').join(' ');
  if (/^[\w+/=]+$/.test(text) && text.length % 4 === 0) {
    const decoded = Buffer.from(text, 'base64').toString('utf8'); if (!decoded.includes('\uFFFD')) text += ' ' + decoded;
  }
  if (/验证码|captcha|checkcode/i.test(text)) return 'CAPTCHA_REQUIRED';
  // Operator AAA errors are not the campus account password.
  if (/109026002|109020106|欠费|余额不足|到期|arrears/i.test(text)) return 'ACCOUNT_ARREARS';
  if (/109026004|109020109|上限|超限|Rad:Oppp|too many|terminal.*limit/i.test(text)) return 'DEVICE_LIMIT';
  if (/109026012|109020105|109026001|109020133|运营商|未绑定|代拨|AAA authenticate terminal failed/i.test(text)) return 'SERVICE_REJECTED';
  if (/不在.*(?:上网|认证|登录)时间|不允许.*时间|时段.*(?:禁止|限制)|time.*limit/i.test(text)) return 'AUTH_TIME_RESTRICTED';
  if (/userid error[12]|账号.*不存在|密码.*(?:错误|不正确)|password.*(?:error|incorrect)|账号或密码/i.test(text)) return 'LOGIN_REJECTED';
  return null;
}
function fingerprint(rule, source, html) {
  const markup = html.replace(/<!--[\s\S]*?-->/g, '').replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
  if (/<input\b(?=[^>]*(?:name|id)\s*=\s*["'](?:captcha|checkcode)["'])(?![^>]*type\s*=\s*["']hidden["'])[^>]*>/i.test(markup)) return 'CAPTCHA_REQUIRED';
  for (const m of source.matchAll(/\bjsVersion["']?\s*[:=]\s*["']([\d.]+)["']/gi)) {
    if (m[1] !== rule.protocol.jsVersion) return 'PORTAL_VERSION_UNRECOGNIZED';
  }
  for (const m of source.matchAll(/https?:\/\/[^\s"'<>]+\/eportal\/portal\/login\b/g)) {
    try { if (new URL(m[0]).origin !== rule.protocol.apiOrigin) return 'PORTAL_ENDPOINT_CHANGED'; } catch { return 'PORTAL_ENDPOINT_CHANGED'; }
  }
  if (rule.kind === 'drcom-query') return /\/eportal\/portal\/login/.test(source) ? 'PORTAL_VERSION_RECOGNIZED' : 'PORTAL_VERSION_UNRECOGNIZED';
  return /loadConfig/.test(source) && /\brcn\b/.test(source) && /AES|aes/.test(source) && source.includes(rule.protocol.aesKey)
    ? 'PORTAL_VERSION_RECOGNIZED' : 'PORTAL_VERSION_UNRECOGNIZED';
}
// GET-only current-page discovery. Sources are inspected as text, never executed.
export async function inspectDrcomPortal(inputRule, { request = directPortalRequest, portalUrl, totalMs = 15000, maxRequests = 10 } = {}) {
  const rule = validateSchoolRule(inputRule); validateDrcomProfile(rule);
  const until = Date.now() + totalMs; let count = 0, last = 'PORTAL_UNREACHABLE';
  const finish = (Code, extra = {}) => ({ Code, ReadOnly: true, CredentialSubmission: false, Requests: count, ...extra });
  if (portalUrl && !readable(rule, portalUrl)) return finish('UNTRUSTED_PORTAL');
  const roots = [...new Set([portalUrl, ...rule.protocol.roots].filter(Boolean))];
  async function get(url) {
    if (count >= maxRequests || Date.now() >= until) throw new Error('PREFLIGHT_BUDGET_EXHAUSTED');
    count++; return request(url, { method: 'GET', timeoutMs: Math.min(2500, until - Date.now()) });
  }
  for (const probe of probes) {
    try { const r = await get(probe); const raw = r.headers?.location || (r.status === 200 ? redirect(decodePortalBody(r.body, r.headers?.['content-type'], 'utf-8')) : null);
      if (raw) { const u = new URL(raw, probe).href; if (readable(rule, u)) roots.unshift(u); }
    } catch { /* Normal external connectivity probes may be blocked. */ }
  }
  for (const root of roots) {
    let url = root; const seen = new Set();
    for (let hop = 0; hop < 4; hop++) {
      if (!readable(rule, url)) return finish('UNTRUSTED_REDIRECT');
      if (seen.has(url)) { last = 'REDIRECT_LOOP'; break; } seen.add(url);
      let r;
      try { r = await get(url); } catch (error) { if (error.message === 'PREFLIGHT_BUDGET_EXHAUSTED') return finish(error.message); break; }
      let html = decodePortalBody(r.body, r.headers?.['content-type'], 'utf-8');
      const next = r.status >= 300 && r.status < 400 ? r.headers?.location : (r.status === 200 ? redirect(html) : null);
      if (next) { try { url = new URL(next.replace(/&amp;/g, '&'), url).href; } catch { return finish('UNTRUSTED_REDIRECT'); } continue; }
      if (r.status !== 200) { last = 'PORTAL_HTTP_ERROR'; break; }
      let source = html, scripts = 0;
      const assets = [...html.matchAll(/<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/gi)]
        .sort((a, b) => Number(/drcom|portal|auth|login|config/i.test(b[1])) - Number(/drcom|portal|auth|login|config/i.test(a[1])));
      for (const m of assets) {
        if (scripts++ >= 6) break;
        let target; try { target = new URL(m[1].replace(/&amp;/g, '&'), url); } catch { continue; }
        if (!readable(rule, target.href, true)) continue;
        try { const js = await get(target.href); if (js.status === 200) source += '\n' + decodePortalBody(js.body, js.headers?.['content-type'], 'utf-8'); }
        catch (error) { if (error.message === 'PREFLIGHT_BUDGET_EXHAUSTED') return finish(error.message); }
      }
      last = fingerprint(rule, source, html);
      if (['CAPTCHA_REQUIRED', 'PORTAL_ENDPOINT_CHANGED'].includes(last)) return finish(last);
      if (last === 'PORTAL_VERSION_RECOGNIZED') {
        const page = new URL(url); let ip = page.searchParams.get('wlanuserip') || page.searchParams.get('wlan_user_ip');
        if (!ip) ip = /\b(?:v46ip|wlan_user_ip)\s*=\s*["']([\d.]+)["']/i.exec(source)?.[1];
        return finish(last, { PortalOrigin: page.origin, PagePath: page.pathname, PortalIp: validIpv4(ip) ? ip : null });
      }
      break;
    }
  }
  return finish(last);
}
export function encryptDrcomParams(data, key) {
  const plaintext = Buffer.from(JSON.stringify(data), 'utf8');
  try { const cipher = createCipheriv('aes-128-ecb', Buffer.from(key, 'ascii'), null); return Buffer.concat([cipher.update(plaintext), cipher.final()]).toString('base64'); }
  finally { plaintext.fill(0); }
}
export async function authenticateDrcom(inputRule, payload, {
  request = directPortalRequest, probeInternet = testInternet, sleep = ms => new Promise(r => setTimeout(r, ms)),
  totalMs = 75000, verificationIntervalMs = 1200, maxVerificationChecks = 8
} = {}) {
  const rule = validateSchoolRule(inputRule), p = validateDrcomProfile(rule);
  let submitted = false, phase = 'INPUT', requests = 0, checks = 0; const until = Date.now() + totalMs;
  const finish = Code => ({ Code, Submitted: submitted, Phase: phase, Requests: requests, InternetChecks: checks, ...(['ONLINE', 'ONLINE_AFTER_AUTH'].includes(Code) ? { InternetVerified: true } : {}) });
  if (payload.mode && payload.mode !== 'authenticate') return finish('UNSUPPORTED_INSPECTION');
  if (typeof payload.username !== 'string' || !/^[^\s,@\u0000-\u001f]{1,64}$/.test(payload.username) || typeof payload.password !== 'string' || !payload.password || payload.password.length > 128) return finish('CREDENTIAL_INVALID');
  if (!p.services.some(s => typeof payload.service === 'string' && s.value === payload.service)) return finish('SERVICE_REQUIRED');
  async function online() { checks++; if (Date.now() >= until) return false; try { return !!await probeInternet({ timeoutMs: Math.min(8000, until - Date.now()) }); } catch { return false; } }
  if (await online()) return finish('ONLINE');
  const network = validateNetwork(payload.network); if (!network) return finish('CAMPUS_INTERFACE_REQUIRED');
  async function get(url, options = {}) {
    if (Date.now() >= until) { const e = new Error('TIMEOUT'); e.name = 'TimeoutError'; throw e; }
    requests++; return request(url, { ...options, timeoutMs: Math.min(options.timeoutMs || 8000, until - Date.now()), method: 'GET' });
  }
  phase = 'DISCOVERY';
  const inspection = await inspectDrcomPortal(rule, { request: get, portalUrl: payload.portalUrl, totalMs: Math.min(15000, Math.max(0, until - Date.now())) });
  if (inspection.Code !== 'PORTAL_VERSION_RECOGNIZED') return finish(inspection.Code);
  if (inspection.PortalIp && inspection.PortalIp !== network.ipv4) return finish('CAMPUS_IP_MISMATCH');
  const params = { login_method: 1, user_account: rule.kind === 'drcom-query' ? ',0,' + payload.username + (payload.service ? '@' + payload.service : '') : ',' + payload.service + ',' + payload.username,
    user_password: payload.password, wlan_user_ip: network.ipv4, wlan_user_ipv6: '', wlan_user_mac: network.mac, wlan_ac_ip: '', wlan_ac_name: '', jsVersion: p.jsVersion,
    terminal_type: 1, lang: 'zh-cn' };
  const target = new URL(p.loginPath, p.apiOrigin); const callback = rule.kind === 'drcom-aes' ? 'dr1006' : 'dr1003';
  try {
    if (rule.kind === 'drcom-aes') {
      phase = 'CONFIG'; const config = new URL(p.configPath, p.apiOrigin);
      const fields = { callback: 'dr1001', program_index: '', wlan_vlan_id: '1', wlan_user_ip: Buffer.from(network.ipv4).toString('base64'),
        wlan_user_ipv6: '', wlan_user_ssid: '', wlan_user_areaid: '', wlan_ac_ip: '', wlan_ap_mac: '', gw_id: '', jsVersion: p.jsVersion, v: String(randomInt(1000, 10000)), lang: 'zh' };
      config.search = new URLSearchParams(fields).toString(); const reply = await get(config.href);
      if (reply.status !== 200) return finish('PORTAL_HTTP_ERROR');
      const value = parseJsonp(decodePortalBody(reply.body, reply.headers?.['content-type'], 'utf-8'), 'dr1001');
      if (classifyDrcomResponse(value) === 'CAPTCHA_REQUIRED' || value.data?.captcha_required === true) return finish('CAPTCHA_REQUIRED');
      const rcn = value.data?.rcn;
      if (typeof rcn !== 'string' || !rcn || rcn.length > 128 || /[\u0000-\u001f]/.test(rcn)) return finish('PORTAL_CONFIG_UNRECOGNIZED');
      Object.assign(params, { login_t: '0', js_status: '0', is_page: '1', is_page_new: randomInt(1000, 10000), rcn });
      target.search = new URLSearchParams({ callback, params: encryptDrcomParams(params, p.aesKey), jsVersion: p.jsVersion, v: String(randomInt(1000, 10000)), lang: 'zh' }).toString();
    } else target.search = new URLSearchParams({ callback, ...params, v: String(randomInt(1000, 10000)) }).toString();
    phase = 'SUBMISSION'; submitted = true;
    const reply = await get(target.href); // Exactly one credential-bearing request; never follow its redirect.
    if (reply.status >= 300 && reply.status < 400) return finish('AUTH_REDIRECT_UNSUPPORTED');
    if (reply.status !== 200) return finish('PORTAL_HTTP_ERROR');
    const response = parseJsonp(decodePortalBody(reply.body, reply.headers?.['content-type'], 'utf-8'), callback);
    const failure = classifyDrcomResponse(response); if (failure) return finish(failure);
    if (![0, 1, '0', '1'].includes(response.result)) return finish('PORTAL_RESPONSE_UNRECOGNIZED');
    phase = 'VERIFICATION';
    for (let i = 0; i < maxVerificationChecks && Date.now() < until; i++) {
      if (await online()) return finish('ONLINE_AFTER_AUTH');
      if (i + 1 < maxVerificationChecks && Date.now() + verificationIntervalMs < until) await sleep(verificationIntervalMs);
    }
    return finish('LOGIN_SUBMITTED_OFFLINE');
  } catch (error) { return finish(error.name === 'TimeoutError' ? 'PORTAL_TIMEOUT' : error.message === 'INVALID_PORTAL_RESPONSE' || error instanceof SyntaxError ? 'PORTAL_RESPONSE_UNRECOGNIZED' : 'AUTH_TRANSPORT_ERROR'); }
  finally { params.user_password = ''; target.search = ''; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const id = process.argv[2]; if (!['hnust', 'hunnu'].includes(id)) throw new Error('INVALID_SCHOOL_ID');
    const rule = JSON.parse((await readFile(new URL('../adapters/' + id + '.json', import.meta.url), 'utf8')).replace(/^\uFEFF/, ''));
    const { PortalIp, ...result } = await inspectDrcomPortal({ ...rule, enabled: true }); console.log(JSON.stringify(result)); process.exitCode = result.Code === 'PORTAL_VERSION_RECOGNIZED' ? 0 : 2;
  } catch { console.log(JSON.stringify({ Code: 'PREFLIGHT_ERROR', ReadOnly: true, CredentialSubmission: false })); process.exitCode = 2; }
}
