import { directEnvironment, curlDirect as curl, testInternet } from './connectivity.mjs';
import { pathToFileURL } from 'node:url';
import { loadSchoolRule, validateSchoolRule } from './school-rules.mjs';
import { writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { chromium } from 'playwright-core';
import { chooseBrowserService, browserServiceVisible } from './browser-service.mjs';
import { describeEntry, checkBrowserEntry } from './browser-entry.mjs';
import { prepareBrowserSession } from './browser-startup.mjs';

export function createBrowserAdapter(inputRule, options = {}) {
const RULE = validateSchoolRule(inputRule);
if (RULE.kind !== 'browser') throw new Error('UNSUPPORTED_BROWSER_RULE');
const DEFAULT_LOGIN_URL = RULE.fallbackPortal;
const SELF_SERVICE_URL = RULE.browser.selfServiceUrl;
const PROBES = RULE.browser.discoveryProbes;
const SELF = RULE.browser.selfService;
const internetProbe = options.probeInternet || testInternet;
function trustedPortal(url) {
  try { const u = new URL(url); return !u.username && !u.password && RULE.trustedOrigins.includes(u.origin); } catch { return false; }
}

function describePortalUrl(value) {
  try {
    const url = new URL(value);
    const [path, ...matrix] = url.pathname.split(';');
    const fields = [...url.searchParams, ...matrix.map(part => {
      const index = part.indexOf('=');
      return index < 0 ? [part, ''] : [part.slice(0, index), part.slice(index + 1)];
    })];
    return { Host: url.hostname, Path: path, Fields: fields.map(([key, data]) => ({
      Name: key, Present: !!data && !/^(undefined|null)$/i.test(data), Length: data.length,
    })) };
  } catch { return { InvalidUrl: true }; }
}

function safeServerReply(value, credential, depth = 0) {
  if (!value || typeof value !== 'object' || depth > 3) return undefined;
  const result = {};
  for (const key of ['code', 'status', 'message', 'msg', 'error', 'errorCode', 'success', 'verifySuccess', 'data']) {
    const data = value[key];
    if (typeof data === 'number' || typeof data === 'boolean') result[key] = data;
    else if (typeof data === 'string' && key !== 'data') {
      let safe = data;
      for (const secret of [credential.username, credential.password]) {
        if (secret) safe = safe.split(secret).join('[REDACTED]');
      }
      result[key] = safe.replace(/https?:\/\/[^\s<>"']+/gi, url => {
        try { const parsed = new URL(url); return parsed.origin + parsed.pathname.split(';')[0]; }
        catch { return '[URL]'; }
      }).replace(/\b\d{7,}\b/g, '[NUMBER]').slice(0, 250);
    } else if (data && typeof data === 'object') {
      const nested = safeServerReply(data, credential, depth + 1);
      if (nested && Object.keys(nested).length) result[key] = nested;
    }
  }
  return Object.keys(result).length ? result : undefined;
}

function decodeHtml(value) {
  return value.replace(/&amp;/g, '&').replace(/&#(\d+);/g, (_, code) => String.fromCharCode(+code))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCharCode(parseInt(code, 16)))
    .replace(/\\\//g, '/');
}

function portalRedirects(text, baseUrl) {
  const found = [];
  const candidates = [
    ...Array.from(text.matchAll(/^location:\s*(.+)$/gim), match => match[1].trim()),
    ...Array.from(text.matchAll(/(?:location(?:\.href)?\s*=|location\.(?:replace|assign)\s*\()\s*['"]([^'"]+)['"]/gi), match => match[1]),
    ...Array.from(text.matchAll(/content\s*=\s*['"][^'"]*?url\s*=\s*([^'"]+)['"]/gi), match => match[1]),
  ];
  for (const value of candidates) {
    try {
      const url = new URL(decodeHtml(value), baseUrl).href;
      if (trustedPortal(url) && !found.includes(url)) found.push(url);
    } catch { /* An incomplete redirect is not a usable login address. */ }
  }
  return found;
}

async function discoverPortal(probes = PROBES) {
  for (const probe of probes) {
    const result = await curl(['-L', '--max-redirs', '5', '-D', '-', probe]);
    const redirects = portalRedirects(result, probe);
    if (redirects.length) return redirects[0];
  }
  return null;
}

async function launchBrowser() {
  return chromium.launch({
    channel: 'msedge', headless: true, timeout: 20000,
    args: ['--no-proxy-server', '--disable-background-networking'],
    env: directEnvironment(),
  });
}

async function openPortal(page, discovered, probes = PROBES, fallbackUrl = DEFAULT_LOGIN_URL) {
  if (discovered) {
    await page.goto(discovered, { waitUntil: 'domcontentloaded', timeout: 25000 });
    return 'NETWORK_REDIRECT';
  }
  // Some gateways construct their redirect in JavaScript. Let the browser run
  // that page before resorting to the context-free account login address.
  for (const probe of probes) {
    try { await page.goto(probe, { waitUntil: 'domcontentloaded', timeout: 5000 }); }
    catch { /* A redirect may interrupt navigation; inspect the frames anyway. */ }
    if (await findLoginForm(page, 2000) || await browserServiceVisible(page, RULE)) return 'BROWSER_REDIRECT';
  }
  await page.goto(fallbackUrl, { waitUntil: 'domcontentloaded', timeout: 25000 });
  return 'SELF_SERVICE_FALLBACK';
}

async function firstVisible(frame, selectors) {
  for (const selector of selectors) {
    const list = frame.locator(selector);
    for (let index = 0, count = Math.min(await list.count(), 12); index < count; index++) {
      const locator = list.nth(index);
      if (await locator.isVisible().catch(() => false)) return locator;
    }
  }
  return null;
}

async function findLoginForm(page, timeout = 15000) {
  const deadline = Date.now() + timeout;
  const switchedTabs = new WeakMap();
  do {
    for (const frame of page.frames()) {
      if (!trustedPortal(frame.url())) continue;
      try {
      const password = await firstVisible(frame, RULE.browser.passwordSelectors);
      const username = await firstVisible(frame, RULE.browser.usernameSelectors);
      if (!username || !password) {
        if (RULE.browser.accountTabTexts && switchedTabs.get(frame) !== frame.url()) {
          const tabs = [];
          for (const text of RULE.browser.accountTabTexts) {
            const list = frame.getByText(text, { exact: true });
            for (let i = 0, n = Math.min(await list.count(), 8); i < n; i++) if (await list.nth(i).isVisible().catch(() => false)) tabs.push(list.nth(i));
          }
          if (tabs.length === 1) { switchedTabs.set(frame, frame.url()); await tabs[0].click({ timeout: 2000 }); }
        }
        continue;
      }
      const button = await firstVisible(frame, RULE.browser.submitSelectors);
      const captcha = await firstVisible(frame, RULE.browser.captchaSelectors);
      return { frame, username, password, button, captcha };
      } catch (error) {
        // CAS replaces its iframe during navigation. Inspect the new frame on
        // the next pass; unrelated selector errors still need a real fix.
        if (!frame.isDetached() && !/Execution context was destroyed|navigation/i.test(error.message)) throw error;
      }
    }
    await page.waitForTimeout(250);
  } while (Date.now() < deadline);
  return null;
}

async function findCaptchaImage(form) {
  const explicit = await firstVisible(form.frame, RULE.browser.captchaImageSelectors);
  if (explicit) return explicit;
  const inputsBox = await form.captcha.boundingBox();
  const images = form.frame.locator('img, canvas');
  for (let index = 0; index < await images.count(); index++) {
    const candidate = images.nth(index);
    const box = await candidate.boundingBox();
    if (box && inputsBox && box.width >= 50 && box.width <= 220 && box.height >= 20 &&
        box.height <= 100 && Math.abs(box.y - inputsBox.y) < 100) return candidate;
  }
  return null;
}

let ocrInstance;
async function solveCaptcha(image) {
  const { DdddOcr, CHARSET_RANGE } = await import('ddddocr-node');
  if (!ocrInstance) {
    ocrInstance = new DdddOcr();
    ocrInstance.setRanges(CHARSET_RANGE.NUM_CASE);
  }
  const text = await ocrInstance.classification(image);
  return String(text).replace(/[^a-zA-Z0-9]/g, '');
}

async function acceptAgreement(form) {
  const candidates = form.frame.locator('input[type="checkbox"], [role="checkbox"]');
  for (let index = 0; index < await candidates.count(); index++) {
    const candidate = candidates.nth(index);
    const agreement = await candidate.evaluate((element, pattern) => {
      const labels = Array.from(element.labels || []).map(label => label.textContent || '');
      const label = element.closest('label');
      const parent = element.parentElement;
      const nearby = labels.length ? labels.join(' ') : label?.textContent ||
        (parent && !/^(FORM|BODY|HTML)$/.test(parent.tagName) && parent.childElementCount < 8 ? parent.textContent : '');
      return new RegExp(pattern, 'i').test([
        element.getAttribute('aria-label') || '', element.id || '', element.getAttribute('name') || '',
        nearby,
      ].join(' '));
    }, RULE.browser.agreementPattern);
    if (!agreement || await candidate.isChecked().catch(() => false)) continue;
    try { await candidate.check({ timeout: 2500 }); }
    catch {
      const id = await candidate.getAttribute('id');
      const label = id ? form.frame.locator(`label[for="${id.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"]`) : null;
      if (label && await label.count()) await label.first().click({ timeout: 2500 });
      else {
        const wrapper = candidate.locator('xpath=ancestor::label[1]');
        if (await wrapper.count()) await wrapper.click({ timeout: 2500 });
        else await candidate.check({ force: true, timeout: 2500 });
      }
    }
    if (!await candidate.isChecked()) throw new Error('AGREEMENT_NOT_CHECKED');
  }
}

function classifyMessage(text) {
  // The portal can return HTTP 200 and a nested policy error after CAS login.
  // Check that policy before generic captcha text elsewhere in the response.
  if (/不在(?:允许的)?(?:认证|上网|使用)时段(?:内)?|not (?:within|in) (?:the )?(?:allowed )?(?:authentication|access) (?:time|period)/i.test(text)) return 'AUTH_TIME_RESTRICTED';
  if (/验证码|校验码|captcha/i.test(text) && /错误|不正确|失败|invalid|incorrect|error/i.test(text)) return 'CAPTCHA_REJECTED';
  if (/密码.{0,12}(错误|不正确)|账号.{0,12}(不存在|错误|禁用|锁定)|用户名.{0,12}(不存在|错误)|incorrect password|invalid credentials/i.test(text)) return 'LOGIN_REJECTED';
  if (/在线.{0,12}(上限|超限)|终端.{0,12}(上限|超限)|RD103|RD204/i.test(text)) return 'DEVICE_LIMIT';
  return null;
}

function classifyServerReply(value, depth = 0) {
  if (!value || typeof value !== 'object' || depth > 4) return null;
  const messages = ['message', 'msg', 'error', 'errorMessage', 'detail', 'failReason']
    .map(key => value[key]).filter(data => typeof data === 'string');
  const nested = classifyServerReply(value.data, depth + 1);
  // Translation/configuration dictionaries may contain "captcha error" strings
  // even when no authentication failed. Only inspect actual feedback fields.
  const direct = classifyMessage(messages.join('\n'));
  const priority = ['AUTH_TIME_RESTRICTED', 'LOGIN_REJECTED', 'DEVICE_LIMIT', 'CAPTCHA_REJECTED'];
  return priority.find(code => code === direct || code === nested) || null;
}

async function submitLogin(page, credential, {
  checkInternet = testInternet, captchaSolver = solveCaptcha, attempts = 3,
  formTimeout = 15000, resultWait = 1200, resultTimeout = 60000, onState = () => {},
} = {}) {
  let submitted = false;
  const needsService = !!RULE.browser.services;
  if (needsService && !RULE.browser.services.some(s => s.value === credential.service)) return { Code: 'SERVICE_REQUIRED', Submitted: false };
  let serviceSelected = false;
  const serviceFailure = code => ['SERVICE_REQUIRED', 'SERVICE_UNAVAILABLE', 'SERVICE_SELECTION_AMBIGUOUS'].includes(code);
  async function serviceChoice() {
    if (!needsService || serviceSelected) return null;
    const choice = await chooseBrowserService(page, RULE, credential.service);
    if (choice.Code === 'SERVICE_SELECTED') { serviceSelected = true; onState({ Type: 'ServiceSelected', Service: credential.service }); }
    return choice;
  }
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (await checkInternet()) return { Code: 'ONLINE', Submitted: submitted };
    // A valid CAS session can already have advanced to the service page.
    // Recover that stage without sending the account password again.
    const initialChoice = await serviceChoice();
    if (serviceFailure(initialChoice?.Code)) return { Code: initialChoice.Code, Submitted: false };
    if (initialChoice && initialChoice.Code !== 'NO_SERVICE_SELECTION') {
      const until = Date.now() + resultTimeout;
      do {
        const choice = await serviceChoice();
        if (serviceFailure(choice?.Code)) return { Code: choice.Code, Submitted: serviceSelected };
        if (await checkInternet()) return { Code: 'ONLINE_AFTER_AUTH', Submitted: serviceSelected };
        await page.waitForTimeout(resultWait);
      } while (Date.now() < until);
      return { Code: 'LOGIN_SUBMITTED_OFFLINE', Submitted: serviceSelected };
    }
    let form = await findLoginForm(page, formTimeout);
    if (!form) return { Code: 'LOGIN_FORM_NOT_FOUND', Submitted: submitted };
    // Angular can expose inputs before its asynchronous initialization has
    // restored the username and loaded the protocol controls.
    await form.frame.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
    form = await findLoginForm(page, formTimeout);
    if (!form) return { Code: 'LOGIN_FORM_NOT_FOUND', Submitted: submitted };
    const action = await form.password.evaluate(element => element.form?.action || location.href);
    if (!trustedPortal(action)) return { Code: 'UNTRUSTED_FORM_ACTION', Submitted: false };
    await form.username.fill(credential.username);
    await form.password.fill(credential.password);
    await form.password.blur();
    await acceptAgreement(form);
    let captchaImage = null;
    if (form.captcha) {
      captchaImage = await findCaptchaImage(form);
      if (!captchaImage) return { Code: 'CAPTCHA_IMAGE_NOT_FOUND', Submitted: false };
      let answer;
      try { answer = await captchaSolver(await captchaImage.screenshot()); }
      catch { return { Code: 'CAPTCHA_OCR_ERROR', Submitted: false }; }
      if (!/^[a-zA-Z0-9]{3,8}$/.test(answer)) return { Code: 'CAPTCHA_OCR_EMPTY', Submitted: false };
      await form.captcha.fill(answer);
    }
    const readyUntil = Date.now() + 8000;
    let ready = false;
    do {
      await acceptAgreement(form);
      const usernameMatches = await form.username.inputValue() === credential.username;
      const passwordMatches = await form.password.inputValue() === credential.password;
      const buttonReady = !form.button || await form.button.evaluate(element =>
        !element.disabled && element.getAttribute('aria-disabled') !== 'true' &&
        !element.classList.contains('disabled'));
      ready = usernameMatches && passwordMatches && buttonReady;
      if (ready) break;
      await page.waitForTimeout(200);
    } while (Date.now() < readyUntil);
    onState({ Type: 'FormReady', Ready: ready,
      UsernameMatches: await form.username.inputValue() === credential.username,
      PasswordMatches: await form.password.inputValue() === credential.password,
      AgreementChecked: await form.frame.locator('input[type="checkbox"]:checked').count() > 0 });
    if (!ready) return { Code: 'LOGIN_FORM_NOT_READY', Submitted: submitted };
    // Reset response feedback immediately before the submit, not while loading the page.
    let responseCode = null;
    const responseListener = async response => {
      if (!trustedPortal(response.url()) || !/json/i.test(response.headers()['content-type'] || '')) return;
      try {
        const body = await response.text();
        if (body.length <= 65536) {
          const next = classifyServerReply(JSON.parse(body));
          const priority = ['AUTH_TIME_RESTRICTED', 'LOGIN_REJECTED', 'DEVICE_LIMIT', 'CAPTCHA_REJECTED'];
          responseCode = priority.find(code => code === next || code === responseCode) || null;
        }
      } catch { /* A navigation may cancel an unrelated response. */ }
    };
    let attemptSubmitted = false;
    const requestListener = request => {
      if (trustedPortal(request.url()) && request.method() === 'POST') attemptSubmitted = true;
    };
    page.on('response', responseListener);
    page.on('request', requestListener);
    try {
      if (form.button) await form.button.click({ timeout: 5000 });
      else await form.password.press('Enter', { timeout: 5000 });
      const resultDeadline = Date.now() + resultTimeout;
      await page.waitForTimeout(resultWait);
      for (;;) {
        submitted ||= attemptSubmitted;
        if (await checkInternet()) return { Code: 'ONLINE_AFTER_AUTH', Submitted: submitted };
        const choice = await serviceChoice();
        if (serviceFailure(choice?.Code)) return { Code: choice.Code, Submitted: submitted };
        const texts = await Promise.all(page.frames().filter(frame => trustedPortal(frame.url()))
          .map(frame => frame.locator('body').innerText({ timeout: 1000 }).catch(() => '')));
        const feedback = responseCode || classifyMessage(texts.join('\n'));
        if (['AUTH_TIME_RESTRICTED', 'LOGIN_REJECTED', 'DEVICE_LIMIT'].includes(feedback)) return { Code: feedback, Submitted: submitted };
        if (feedback === 'CAPTCHA_REJECTED') break;
        if (Date.now() >= resultDeadline) {
          const isolatedSuccess = page.frames().some(frame =>
            trustedPortal(frame.url()) && new URL(frame.url()).pathname === RULE.browser.successPath);
          return { Code: !submitted ? 'LOGIN_NOT_SUBMITTED' :
            isolatedSuccess ? 'PORTAL_CONTEXT_MISSING' : 'LOGIN_SUBMITTED_OFFLINE', Submitted: submitted };
        }
        await page.waitForTimeout(resultWait);
      }
    } finally { page.off('response', responseListener); page.off('request', requestListener);
      onState({ Type: 'LoginRequest', Submitted: attemptSubmitted }); }
    if (attempt + 1 < attempts) {
      // Only captcha rejection reaches this branch; account failures never retry here.
      if (captchaImage) await captchaImage.click({ timeout: 1500 }).catch(() => {});
      await page.waitForTimeout(400);
    }
  }
  return { Code: 'CAPTCHA_RETRY_EXHAUSTED', Submitted: submitted };
}

async function inspectPage(page) {
  const frames = [];
  for (const frame of page.frames()) {
    const url = new URL(frame.url() === 'about:blank' ? 'about:blank' : frame.url());
    const item = { ...describePortalUrl(url.href), Trusted: trustedPortal(frame.url()) };
    if (item.Trusted) {
      item.Inputs = await frame.locator('input').evaluateAll(inputs => inputs.map(input => ({
        Type: input.type, Id: input.id, Name: input.name, Placeholder: input.placeholder,
        Visible: !!(input.getClientRects().length),
      })));
      item.Buttons = await frame.locator('button, input[type="submit"], [role="button"]').evaluateAll(buttons =>
        buttons.map(button => ({ Id: button.id, Type: button.getAttribute('type'),
          Disabled: button.disabled || button.classList.contains('disabled'),
          Text: (button.textContent || button.getAttribute('value') || '').trim().slice(0, 60) })));
      item.Agreements = await frame.locator('input[type="checkbox"]').evaluateAll(inputs => inputs.map(input => ({
        Checked: input.checked, Label: input.closest('label')?.textContent.trim().slice(0, 120),
      })));
      item.FormActions = await frame.locator('form').evaluateAll(forms => forms.map(form => form.action))
        .then(actions => actions.map(describePortalUrl));
      item.FlowState = RULE.browser.flowStorageKeys ? await frame.evaluate(keys => {
        const parse = key => { try { return JSON.parse(localStorage.getItem(key) || '{}'); } catch { return {}; } };
        const terminal = parse(keys.terminal);
        const flow = parse(keys.flow);
        const config = parse(keys.config);
        return { FlowParamPresent: !!flow?.flowParam, SessionIdPresent: !!config?.sessionId,
          TerminalFields: Object.keys(terminal || {}), FirstFlowParamPresent:
            !!localStorage.getItem(keys.first) && localStorage.getItem(keys.first) !== 'undefined' };
      }, RULE.browser.flowStorageKeys).catch(() => null) : null;
    }
    frames.push(item);
  }
  return frames;
}

async function authenticate(payload) {
  if (payload.portalUrl && !trustedPortal(payload.portalUrl)) return { Code: 'UNTRUSTED_PORTAL', Submitted: false };
  const inspect = payload.mode === 'inspect';
  if (['inspect_self','verify_login'].includes(payload.mode) && !SELF_SERVICE_URL) return { Code: 'UNSUPPORTED_INSPECTION', Submitted: false };
  const inspectSelf = payload.mode === 'inspect_self';
  const verifyLogin = payload.mode === 'verify_login' || inspectSelf;
  if (!inspect && (typeof payload.username !== 'string' || !payload.username ||
      typeof payload.password !== 'string' || !payload.password)) return { Code: 'CREDENTIAL_INVALID' };
  if (!inspect && !verifyLogin && await internetProbe()) return { Code: 'ONLINE', Submitted: false };
  if (!inspect && !verifyLogin && RULE.browser.services && !RULE.browser.services.some(s => s.value === payload.service)) return { Code: 'SERVICE_REQUIRED', Submitted: false };
  const discovered = (inspect || verifyLogin) ? null : await (options.discoverPortal || discoverPortal)();
  let session;
  try { session = await prepareBrowserSession(options.browserFactory || launchBrowser); }
  catch (error) { if (error.browserStartup) return error.browserStartup; throw error; }
  const { browser, context, page, StartupAttempts } = session;
  const blockedHosts = new Set();
  const trace = [], pendingResponses = [], entryEvidence = [];
  context.on('request', request => {
    if (request.isNavigationRequest()) trace.push({ Type: 'Navigation', ...describePortalUrl(request.url()) });
    if (request.isNavigationRequest() && trustedPortal(request.url())) entryEvidence.push(describeEntry(request.url()));
  });
  context.on('response', response => {
    if (inspectSelf && trustedPortal(response.url()) && /\.js$/.test(new URL(response.url()).pathname)) {
      pendingResponses.push((async () => {
        const text = await response.text();
        if (!RULE.browser.diagnosticScriptPattern || !new RegExp(RULE.browser.diagnosticScriptPattern).test(text)) return;
        await mkdir(new URL('./vendor-review/self-live/', import.meta.url), { recursive: true });
        const name = new URL(response.url()).pathname.split('/').pop().replace(/[^a-zA-Z0-9._-]/g, '_');
        await writeFile(new URL('./vendor-review/self-live/' + name, import.meta.url), text);
      })().catch(() => {}));
    }
    if (!trustedPortal(response.url()) || !/json/i.test(response.headers()['content-type'] || '')) return;
    pendingResponses.push((async () => {
      const text = await response.text();
      if (text.length > 65536) return;
      const reply = safeServerReply(JSON.parse(text), payload);
      if (reply) trace.push({ Type: 'Response', ...describePortalUrl(response.url()), Status: response.status(), Reply: reply });
    })().catch(() => {}));
  });
  let discoveryPhase = !inspect && !verifyLogin;
  const probeHosts = new Set(PROBES.map(url => new URL(url).hostname));
  await context.route('**/*', route => {
    const url = route.request().url();
    if (trustedPortal(url)) return route.fallback();
    if (/^https?:/.test(url)) {
      const parsed = new URL(url);
      const privateGateway = /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(parsed.hostname);
      if (discoveryPhase && route.request().method() === 'GET' && route.request().isNavigationRequest() &&
          (probeHosts.has(parsed.hostname) || privateGateway)) return route.fallback();
      blockedHosts.add(parsed.hostname);
      return route.abort('blockedbyclient');
    }
    return route.continue();
  });
  page.setDefaultTimeout(5000);
  let result;
  try {
    let portalSource;
    if (inspect || verifyLogin) {
      await page.goto(inspectSelf ? SELF_SERVICE_URL : DEFAULT_LOGIN_URL, { waitUntil: 'domcontentloaded', timeout: 25000 });
      portalSource = 'ACCOUNT_PAGE';
    } else portalSource = await openPortal(page, discovered, PROBES, payload.portalUrl || DEFAULT_LOGIN_URL);
    discoveryPhase = false;
    if (!inspect && !verifyLogin && RULE.browser.requireNetworkRedirect && portalSource === 'SELF_SERVICE_FALLBACK') {
      return { Code: 'PORTAL_CONTEXT_MISSING', Submitted: false, PortalSource: portalSource };
    }
    if (!inspect && !verifyLogin) {
      let blocked=checkBrowserEntry(RULE,[...entryEvidence,...page.frames().map(frame=>describeEntry(frame.url()))]);
      // A new SAM page can load its CAS iframe and flow ID asynchronously.
      // Wait for initialization while there is no visible password form;
      // a complete context-free form must still stop before credential fill.
      const entryUntil=Date.now()+8000;
      const initializingRoot=()=>{try{return /^\/(?:index\.html|portal\/?|portal\/index\.html)?$/.test(new URL(page.url()).pathname);}catch{return false;}};
      while((blocked==='PORTAL_CONTEXT_MISSING'||blocked==='PORTAL_VERSION_UNVERIFIED'&&initializingRoot())&&Date.now()<entryUntil&&!await findLoginForm(page,250)){
        blocked=checkBrowserEntry(RULE,[...entryEvidence,...page.frames().map(frame=>describeEntry(frame.url()))]);
      }
      blocked=checkBrowserEntry(RULE,[...entryEvidence,...page.frames().map(frame=>describeEntry(frame.url()))]);
      if(blocked)return {Code:blocked,Submitted:false,PortalSource:portalSource};
    }
    if (inspect || verifyLogin) await findLoginForm(page, 15000);
    if (inspect) result = { Code: 'INSPECTED', Frames: await inspectPage(page) };
    else if (verifyLogin) {
      const checkSession = async () => {
        for (const frame of page.frames()) {
          if (!trustedPortal(frame.url())) continue;
          const body = await frame.locator('body').innerText({ timeout: 1000 }).catch(() => '');
          const callbackSuccess = new URL(frame.url()).pathname === RULE.browser.successPath &&
            await frame.evaluate(key => localStorage.getItem(key) === 'true', RULE.browser.successStorageKey).catch(() => false);
          if ((!inspectSelf && callbackSuccess) || (SELF && SELF.readyTexts.every(text => body.includes(text)) &&
              !await frame.locator('input[type="password"]').isVisible().catch(() => false))) return true;
        }
        return false;
      };
      result = await submitLogin(page, payload, { checkInternet: checkSession, onState: state => trace.push(state) });
      if (['ONLINE', 'ONLINE_AFTER_AUTH'].includes(result.Code)) result.Code = 'CREDENTIAL_LOGIN_VERIFIED';
      if (inspectSelf && result.Code === 'CREDENTIAL_LOGIN_VERIFIED') {
        for (const frame of page.frames().filter(frame => trustedPortal(frame.url()))) {
          const link = frame.getByText(SELF.devicesLinkText, { exact: true });
          for (let index = 0; index < await link.count(); index++) {
            if (await link.nth(index).isVisible()) { await link.nth(index).click(); break; }
          }
        }
        await page.waitForTimeout(5000);
        result.TargetDevice = { Ready: false };
        for (const frame of page.frames().filter(frame => trustedPortal(frame.url()))) {
          const summary = await frame.evaluate(({ mac, spec }) => {
            const expected = String(mac || '').replace(/[:-]/g, '').toUpperCase();
            if (!/^[0-9A-F]{12}$/.test(expected)) return { Ready: false };
            const leaves = [...document.querySelectorAll('*')].filter(element => !element.children.length &&
              element.textContent?.replace(/[:-]/g, '').toUpperCase().includes(expected));
            const candidates = [...new Set((document.body.innerText.match(/(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}/gi) || [])
              .map(value => value.replace(/[:-]/g, '').toUpperCase().slice(-4)))];
            for (const leaf of leaves) {
              let card = leaf;
              for (let depth = 0; card && depth < 10; depth++, card = card.parentElement) {
                const controls = [...card.querySelectorAll('button,a,[role="button"]')]
                  .filter(button => button.textContent.trim() === spec.offlineButtonText);
                if (controls.length === 1) {
                  return { Ready: true, MatchedCurrentTerminal: card.textContent.includes(spec.currentTerminalText), OfflineControlCount: 1,
                    MacSuffix: expected.slice(-4), CanDisableNoSense: card.textContent.includes(spec.disableNoSenseText),
                    RecentOnline: card.textContent.match(new RegExp(spec.recentOnlinePattern))?.[0] };
                }
              }
            }
            return { Ready: false, ExpectedMacValid: true, ExpectedMacSuffix: expected.slice(-4),
              MatchingMacElements: leaves.length, DeviceMacSuffixes: candidates,
              OfflineControls: [...document.querySelectorAll('button,a,[role="button"]')]
                .filter(button => button.textContent.trim() === spec.offlineButtonText).length };
          }, { mac: payload.targetMac, spec: SELF });
          result.TargetDevice = summary;
          if (summary.Ready) break;
        }
        result.Code = result.TargetDevice.Ready ? 'SELF_DEVICE_READY' : 'SELF_DEVICE_NOT_FOUND';
      }
    } else result = await submitLogin(page, payload, { checkInternet: internetProbe, onState: state => trace.push(state) });
    result.PortalSource = portalSource;
    result.StartupAttempts = StartupAttempts;
    if (inspectSelf) await Promise.allSettled(pendingResponses);
    result.BlockedHosts = [...blockedHosts];
    if (!inspect && !['ONLINE', 'ONLINE_AFTER_AUTH', 'CREDENTIAL_LOGIN_VERIFIED', 'SELF_DEVICE_READY'].includes(result.Code)) {
      await Promise.allSettled(pendingResponses);
      const diagnostic = { Time: new Date().toISOString(), Code: result.Code,
        PortalSource: result.PortalSource, Frames: await inspectPage(page), BlockedHosts: result.BlockedHosts,
        Trace: trace.slice(-60) };
      const diagnosticPath = process.env.CAMPUSLUMA_STATE_DIR
        ? join(process.env.CAMPUSLUMA_STATE_DIR, 'portal-diagnostic.json') : new URL('./portal-diagnostic.json', import.meta.url);
      await writeFile(diagnosticPath, JSON.stringify(diagnostic, null, 2));
    }
    return result;
  } catch (error) {
    return { Code: error.name === 'TimeoutError' ? 'PORTAL_TIMEOUT' : 'BROWSER_AUTH_ERROR',
      ErrorType: error.name, BlockedHosts: [...blockedHosts] };
  } finally { await browser.close().catch(() => {}); }
}

return { DEFAULT_LOGIN_URL, directEnvironment, trustedPortal, describePortalUrl, portalRedirects, testInternet, discoverPortal, launchBrowser, openPortal, findLoginForm, solveCaptcha, acceptAgreement, classifyMessage, classifyServerReply, submitLogin, inspectPage, authenticate, chooseService: (page, service) => chooseBrowserService(page, RULE, service) };
}

export async function runBrowserCli() {
  let input = '';
  for await (const chunk of process.stdin) input += chunk.toString('utf8');
  let result;
  try {
    const payload = JSON.parse(input.replace(/^\uFEFF/, ''));
    input = '';
    const adapter = createBrowserAdapter(await loadSchoolRule(payload.schoolId || 'xtu'));
    result = await adapter.authenticate(payload);
    payload.password = '';
  } catch (error) { result = { Code: 'SCHOOL_OR_BROWSER_PROVIDER_ERROR', ErrorType: error.name }; }
  process.stdout.write(JSON.stringify(result) + '\n');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await runBrowserCli();
