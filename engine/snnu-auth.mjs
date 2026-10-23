import iconv from 'iconv-lite';
import { validateSchoolRule } from './school-rules.mjs';
import { testInternet } from './connectivity.mjs';
import { preflightSnnu, directPortalRequest, decodePortalBody, findSnnuLoginForm, inspectSnnuPage, portalText, portalAccount, trusted } from './snnu-preflight.mjs';

export function encodePortalForm(entries, encoding = 'gb2312') {
  function encode(value) {
    value = String(value);
    const bytes = iconv.encode(value, encoding);
    if (iconv.decode(bytes, encoding) !== value) throw new Error('CREDENTIAL_ENCODING_UNSUPPORTED');
    return [...bytes].map(b => (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || [45, 46, 95, 42].includes(b)
      ? String.fromCharCode(b) : b === 32 ? '+' : '%' + b.toString(16).toUpperCase().padStart(2, '0')).join('');
  }
  return Buffer.from(entries.map(([key, value]) => encode(key) + '=' + encode(value)).join('&'), 'ascii');
}
export function classifySnnuResponse(html) {
  const text = portalText(html);
  const markup = html.replace(/<!--[\s\S]*?-->/g, '').replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '');
  if (/验证码(?:错误|不正确|不能为空)|(?:请输入|需要|输入)验证码/i.test(text) || /name\s*=\s*["']checkcode["']/i.test(markup)) return 'CAPTCHA_REQUIRED';
  if (/(?:密码|口令)(?:错误|不正确)|(?:用户名|账号)或密码错误|账号不存在|用户不存在/i.test(text)) return 'LOGIN_REJECTED';
  if (/欠费|余额不足|流量(?:已)?(?:用尽|耗尽)|套餐(?:已)?到期/i.test(text)) return 'ACCOUNT_ARREARS';
  if (/非(?:允许|可认证|可登录)时间|当前(?:时间段|时段).*(?:禁止|不允许)|不在.*(?:认证|上网|登录)时间/i.test(text)) return 'AUTH_TIME_RESTRICTED';
  if (/在线(?:设备|终端|用户).*(?:上限|超限)|超过.*(?:设备|终端|连接).*数/i.test(text)) return 'DEVICE_LIMIT';
  if (/运营商.*(?:错误|未绑定|不匹配)|服务类型.*(?:错误|不匹配)|代拨.*(?:未开通|失败)/i.test(text)) return 'SERVICE_REJECTED';
  return null;
}
export async function authenticateSnnu(inputRule, payload, {
  request = directPortalRequest, probeInternet = testInternet, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  totalMs = 75000, verificationMs = 20000, verificationIntervalMs = 1200, maxVerificationChecks = 8
} = {}) {
  const rule = validateSchoolRule(inputRule), profile = rule.researchProfile;
  if (rule.kind !== 'snnu-jsp' || payload.mode && payload.mode !== 'authenticate') return { Code: 'UNSUPPORTED_INSPECTION', Submitted: false };
  let submitted = false, phase = 'INPUT', requestCount = 0, internetChecks = 0;
  const until = Date.now() + totalMs;
  const finish = (Code, extra = {}) => ({ Code, Submitted: submitted, Phase: phase, Requests: requestCount, InternetChecks: internetChecks, ...extra });
  if (typeof payload.username !== 'string' || !payload.username.trim() || typeof payload.password !== 'string' || !payload.password) return finish('CREDENTIAL_INVALID');
  if (typeof payload.service !== 'string' || !profile.services.some(s => s.value === payload.service)) return finish('SERVICE_REQUIRED');
  if (payload.password.includes(';')) return finish('CREDENTIAL_FORMAT_UNSUPPORTED');
  if (payload.portalUrl && !trusted(profile, payload.portalUrl)) return finish('UNTRUSTED_PORTAL');
  async function internet(end = until) {
    end = Math.min(end, until);
    if (Date.now() >= end) return false;
    internetChecks++;
    try { return !!(await probeInternet({ timeoutMs: Math.min(8000, end - Date.now()) })); } catch { return false; }
  }
  if (await internet()) return finish('ONLINE', { InternetVerified: true });
  const cookies = new Map(); let last;
  function remember(url, response) {
    const values = response.headers?.['set-cookie'];
    for (const value of values ? (Array.isArray(values) ? values : [values]) : []) {
      const m = /^JSESSIONID=[^;\r\n]+/i.exec(value); if (m) cookies.set(new URL(url).hostname, m[0]);
    }
    last = { url, html: decodePortalBody(response.body, response.headers?.['content-type'], profile.responseEncoding) };
  }
  phase = 'DISCOVERY';
  const inspection = await preflightSnnu(profile, { preferredPortal: payload.portalUrl, totalMs: Math.min(15000, Math.max(0, until - Date.now())), request: async (url, options) => {
    requestCount++;
    const response = await request(url, { ...options, method: 'GET' }); remember(url, response); return response;
  }});
  if (inspection.Code === 'PORTAL_SESSION_PRESENT') {
    const account = portalAccount(profile, last.html), username = payload.username.trim();
    if (account && account !== username && account.split('@')[0] !== username) return finish('OTHER_PORTAL_SESSION');
    const actualService = account.includes('@') ? account.slice(account.lastIndexOf('@') + 1) : '';
    if (actualService !== payload.service) return finish('SERVICE_MISMATCH');
    return await internet() ? finish('ONLINE', { InternetVerified: true }) : finish('PORTAL_SESSION_OFFLINE');
  }
  if (inspection.Code !== 'PORTAL_FORM_READY') return finish(inspection.Code);
  phase = 'FORM';
  const form = findSnnuLoginForm(profile, last.html);
  if (!form || form.hasBase) return finish('LOGIN_FORM_NOT_FOUND');
  const target = new URL(form.attributes.action, last.url);
  if (!trusted(profile, target.href) || target.origin !== new URL(last.url).origin || target.pathname !== profile.loginAction || target.search || target.hash) return finish('UNTRUSTED_FORM_ACTION');
  const accountInputs = form.fields.filter(f => f.name === profile.usernameField), passwordInputs = form.fields.filter(f => f.name === profile.passwordField);
  if (accountInputs.length !== 1 || passwordInputs.length !== 1 || accountInputs[0].disabled !== undefined || passwordInputs[0].disabled !== undefined) return finish('UNSUPPORTED_LOGIN_FORM');
  for (const [field, value] of [[accountInputs[0], payload.username.trim()], [passwordInputs[0], payload.password]]) {
    if (field.maxlength && /^\d+$/.test(field.maxlength) && value.length > Number(field.maxlength)) return finish('CREDENTIAL_LENGTH_UNSUPPORTED');
  }
  if (!form.fields.some(f => f.name === profile.serviceField && f.type === 'radio' && (f.value || '') === payload.service && f.disabled === undefined)) return finish('SERVICE_UNAVAILABLE');
  if (form.fields.some(f => f.type === 'checkbox' && f.required !== undefined && f.name !== profile.rememberPasswordField)) return finish('UNSUPPORTED_LOGIN_FORM');
  const entries = form.fields.filter(f => f.name && f.type === 'hidden' && f.disabled === undefined &&
    ![profile.usernameField, profile.passwordField, profile.serviceField, profile.rememberPasswordField].includes(f.name)).map(f => [f.name, f.value || '']);
  entries.push([profile.usernameField, payload.username.trim()], [profile.passwordField, payload.password], [profile.serviceField, payload.service]);
  let body;
  try { body = encodePortalForm(entries, profile.requestEncoding || 'gb2312'); }
  catch { return finish('CREDENTIAL_ENCODING_UNSUPPORTED'); }
  try {
    if (Date.now() >= until) return finish('PROVIDER_TIMEOUT');
    // A submitted request may have reached the server even if its response times out.
    submitted = true;
    phase = 'SUBMISSION'; requestCount++;
    let response = await request(target.href, { method: 'POST', body, cookie: cookies.get(target.hostname), timeoutMs: Math.min(8000, until - Date.now()),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': String(body.length), Origin: target.origin, Referer: last.url } });
    remember(target.href, response);
    for (let hops = 0; response.status >= 300 && response.status < 400; hops++) {
      phase = 'REDIRECT';
      if (hops >= 4 || ![301, 302, 303].includes(response.status) || !response.headers?.location) return finish('AUTH_REDIRECT_UNSUPPORTED');
      const next = new URL(response.headers.location, last.url);
      if (!trusted(profile, next.href) || next.origin !== target.origin || ![profile.statusPage, profile.loginPage].includes(next.pathname) || next.search || next.hash) return finish('UNTRUSTED_REDIRECT');
      if (Date.now() >= until) return finish('PROVIDER_TIMEOUT');
      requestCount++;
      response = await request(next.href, { method: 'GET', timeoutMs: Math.min(3000, until - Date.now()), cookie: cookies.get(next.hostname) });
      remember(next.href, response);
    }
    if (response.status !== 200) return finish('PORTAL_HTTP_ERROR');
    phase = 'RESPONSE';
    const failure = classifySnnuResponse(last.html);
    if (failure) return finish(failure);
    const account = portalAccount(profile, last.html);
    if (account && account !== payload.username.trim() && account.split('@')[0] !== payload.username.trim()) return finish('OTHER_PORTAL_SESSION');
    if (account && (account.includes('@') ? account.slice(account.lastIndexOf('@') + 1) : '') !== payload.service) return finish('SERVICE_MISMATCH');
    const verifyUntil = Math.min(until, Date.now() + verificationMs);
    phase = 'VERIFICATION';
    for (let count = 0; count < maxVerificationChecks && Date.now() <= verifyUntil; count++) {
      if (await internet(verifyUntil)) return finish('ONLINE_AFTER_AUTH', { InternetVerified: true, PortalSource: 'DYNAMIC_FORM', PortalOrigin: target.origin });
      if (count + 1 < maxVerificationChecks && Date.now() + verificationIntervalMs < verifyUntil) await sleep(verificationIntervalMs); else break;
    }
    return finish('LOGIN_SUBMITTED_OFFLINE');
  } catch (error) { return finish(error.name === 'TimeoutError' ? 'PORTAL_TIMEOUT' : 'AUTH_TRANSPORT_ERROR'); }
  finally { if (body) body.fill(0); entries.forEach(pair => { pair[1] = ''; }); cookies.clear(); last = null; }
}
