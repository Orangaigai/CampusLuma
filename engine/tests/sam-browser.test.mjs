import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBrowserAdapter } from '../browser-auth.mjs';
import { validateSchoolRule, loadSchoolRule } from '../school-rules.mjs';
import { authenticateSchool } from '../auth-provider.mjs';

const rules = {}, candidates = {};
for (const id of ['cuit', 'scit', 'ysu', 'uestc-telecom']) {
  candidates[id] = JSON.parse((await readFile(new URL('../../adapters/' + id + '.json', import.meta.url), 'utf8')).replace(/^\uFEFF/, ''));
  rules[id] = validateSchoolRule({ ...candidates[id], enabled: true });
}
let browser;
before(async () => { browser = await createBrowserAdapter(await loadSchoolRule('xtu')).launchBrowser(); });
after(async () => { await browser?.close(); });
const credential = { username: 'fixture-student', password: '中文+&pw' };
function fixture(id, { missing = false, duplicate = false, delay = 0, offline = false, otherFrame = false, qr = false } = {}) {
  const rule = rules[id], service = id === 'uestc-telecom' ? 'telecom' : 'mobile';
  const portal = rule.trustedOrigins[0], cas = id === 'ysu' ? 'https://cer.ysu.edu.cn' : portal;
  let online = false, passwords = 0, choices = 0;
  const labels = missing ? ['中国联通'] : duplicate ? ['中国移动', '中国移动'] : ['中国移动', '中国联通', '中国电信', '校园网'];
  const selection = `<!doctype html><section data-service-selection><h2>请选择服务</h2>
    ${labels.map(label => `<div class="service-box"><span class="service">${label}</span></div>`).join('')}
    <button id="confirm" ${delay ? 'disabled' : ''}>确定</button></section><script>
    let selected='';const confirmButton=document.getElementById('confirm');for(const item of document.querySelectorAll('.service-box'))item.onclick=()=>{selected=item.textContent.trim();${delay ? `setTimeout(()=>confirmButton.disabled=false,${delay});` : ''}};
    confirmButton.onclick=()=>fetch('/fixture-service',{method:'POST',body:JSON.stringify({service:selected})});</script>`;
  return { service, portal, cas, selection, get online() { return online; }, get passwords() { return passwords; }, get choices() { return choices; },
    route: async route => {
      const request = route.request(), url = new URL(request.url());
      if (url.pathname === '/fixture-login') {
        assert.deepEqual(JSON.parse(request.postData()), credential); passwords++;
        return route.fulfill({ contentType: 'application/json', body: '{"message":"ok"}' });
      }
      if (url.pathname === '/fixture-service') {
        const value = JSON.parse(request.postData()).service;
        assert.equal(value, service === 'telecom' ? '中国电信' : '中国移动'); choices++; online = !offline;
        return route.fulfill({ contentType: 'application/json', body: '{"message":"ok"}' });
      }
      if (url.pathname.includes('serviceSelection')) return route.fulfill({ contentType: 'text/html;charset=utf-8', body: selection });
      if (url.pathname === '/pc/center' || url.pathname === '/authserver/login') return route.fulfill({ contentType: 'text/html;charset=utf-8', body: `<!doctype html>${qr ? '<button id="account-tab" onclick="document.querySelector(\'form\').hidden=false;this.hidden=true">账号</button>' : ''}<form ${qr ? 'hidden' : ''}>
        <input id="${id === 'ysu' ? 'username' : 'nameInput'}" name="username"><input id="password" type="password">
        <label><input id="agreement" type="checkbox">同意用户协议</label><button id="submitBtn">登录</button></form>
        <script>document.querySelector('form').onsubmit=async e=>{e.preventDefault();await fetch('/fixture-login',{method:'POST',body:JSON.stringify({username:document.querySelector('[name=username]').value,password:password.value})});top.location.href='${portal}/portal/serviceSelection?sessionId=fixture';};</script>` });
      return route.fulfill({ contentType: 'text/html;charset=utf-8', body: `<!doctype html><iframe src="${otherFrame ? 'https://outside.invalid' : cas}${id === 'ysu' ? '/authserver/login' : '/pc/center'}?flowSessionId=fixture"></iframe>` });
    }
  };
}
async function pageFor(id, config = {}, startAtServices = false) {
  const f = fixture(id, config), context = await browser.newContext({ serviceWorkers: 'block' });
  await context.route('**/*', f.route);
  const page = await context.newPage(); await page.goto(f.portal + (startAtServices ? '/portal/serviceSelection' : '/portal/entry/pc/authenticate?sessionId=fixture'));
  return { f, page, context, adapter: createBrowserAdapter(rules[id]) };
}
for (const id of Object.keys(rules)) {
  test(id + ': actual iframe login, agreement, nested service card and confirmation restore connectivity', async () => {
    const { f, page, context, adapter } = await pageFor(id);
    try {
      const result = await adapter.submitLogin(page, { ...credential, service: f.service }, { checkInternet: async () => f.online, resultWait: 40, resultTimeout: 5000 });
      assert.equal(result.Code, 'ONLINE_AFTER_AUTH'); assert.equal(result.Submitted, true); assert.equal(f.passwords, 1); assert.equal(f.choices, 1);
    } finally { await context.close(); }
  });
  test(id + ': an existing CAS session completes service selection without resending a password', async () => {
    const { f, page, context, adapter } = await pageFor(id, {}, true);
    try { assert.equal((await adapter.submitLogin(page, { ...credential, service: f.service }, { checkInternet: async () => f.online, resultWait: 20, resultTimeout: 1000 })).Code, 'ONLINE_AFTER_AUTH'); assert.equal(f.passwords, 0); assert.equal(f.choices, 1); }
    finally { await context.close(); }
  });
  test(id + ': already online does not switch the selected carrier', async () => {
    const { f, page, context, adapter } = await pageFor(id, {}, true);
    try { const r = await adapter.submitLogin(page, { ...credential, service: f.service }, { checkInternet: async () => true }); assert.equal(r.Code, 'ONLINE'); assert.equal(f.passwords + f.choices, 0); }
    finally { await context.close(); }
  });
  test(id + ': missing carrier stops before account or service submission', async () => {
    const { f, page, context, adapter } = await pageFor(id);
    try { assert.equal((await adapter.submitLogin(page, credential, { checkInternet: async () => false })).Code, 'SERVICE_REQUIRED'); assert.equal(f.passwords + f.choices, 0); }
    finally { await context.close(); }
  });
  test(id + ': gateway-like page and service success without Internet cannot report success', async () => {
    const { f, page, context, adapter } = await pageFor(id, { offline: true }, true);
    try { const r = await adapter.submitLogin(page, { ...credential, service: f.service }, { checkInternet: async () => false, resultWait: 20, resultTimeout: 100 }); assert.equal(r.Code, 'LOGIN_SUBMITTED_OFFLINE'); assert.equal(f.choices, 1); }
    finally { await context.close(); }
  });
  test(id + ': actual disabled source rule remains unselectable and cannot authenticate', async () => {
    await assert.rejects(loadSchoolRule(id), /SCHOOL_NOT_ENABLED/);
    await assert.rejects(authenticateSchool(candidates[id], { ...credential, service: 'mobile' }), /SCHOOL_NOT_ENABLED/);
  });
  test(id + ': full provider follows fresh gateway entry through password and service to verified Internet', async () => {
    const rule = rules[id], f = fixture(id);
    const result = await authenticateSchool(rule, { ...credential, schoolId: id, service: f.service }, {
      probeInternet: async () => f.online, discoverPortal: async () => f.portal + '/portal/entry/pc/authenticate?sessionId=fixture',
      browserFactory: async () => { const b = await createBrowserAdapter(rule).launchBrowser(); const create = b.newContext.bind(b); b.newContext = async options => { const c = await create(options); await c.route('**/*', f.route); return c; }; return b; }
    });
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH'); assert.equal(result.PortalSource, 'NETWORK_REDIRECT'); assert.equal(f.passwords, 1); assert.equal(f.choices, 1);
  });
}

test('YSU switches its exact account tab when the CAS page starts at QR login', async () => {
  const { f, page, context, adapter } = await pageFor('ysu', { qr: true });
  try { const r = await adapter.submitLogin(page, { ...credential, service: f.service }, { checkInternet: async () => f.online, resultWait: 20, resultTimeout: 3000 }); assert.equal(r.Code, 'ONLINE_AFTER_AUTH'); assert.equal(f.passwords, 1); }
  finally { await context.close(); }
});
test('fresh browser redirect reaching service selection is retained when CAS is already authenticated', async () => {
  const { f, page, context, adapter } = await pageFor('ysu', {}, true);
  try { const source = await adapter.openPortal(page, null, [f.portal + '/portal/serviceSelection'], f.portal + '/account-only'); assert.equal(source, 'BROWSER_REDIRECT'); assert.equal(f.passwords + f.choices, 0); }
  finally { await context.close(); }
});
test('missing service is not replaced with another operator', async () => {
  const { f, page, context, adapter } = await pageFor('cuit', { missing: true }, true);
  try { assert.equal((await adapter.chooseService(page, 'mobile')).Code, 'SERVICE_UNAVAILABLE'); assert.equal(f.choices, 0); }
  finally { await context.close(); }
});
test('two distinct equally named options stop as ambiguous', async () => {
  const { f, page, context, adapter } = await pageFor('cuit', { duplicate: true }, true);
  try { assert.equal((await adapter.chooseService(page, 'mobile')).Code, 'SERVICE_SELECTION_AMBIGUOUS'); assert.equal(f.choices, 0); }
  finally { await context.close(); }
});
test('delayed confirmation is awaited without clicking the service repeatedly', async () => {
  const { f, page, context, adapter } = await pageFor('cuit', { delay: 500 }, true);
  try { assert.equal((await adapter.chooseService(page, 'mobile')).Code, 'SERVICE_SELECTED'); assert.equal(f.choices, 1); }
  finally { await context.close(); }
});
test('same-looking form in an unrelated SSO origin is not filled', async () => {
  const { f, page, context, adapter } = await pageFor('ysu', { otherFrame: true });
  try { assert.equal(await adapter.findLoginForm(page, 100), null); assert.equal(f.passwords, 0); }
  finally { await context.close(); }
});
test('ambiguous aliases and missing selector configuration are rejected before execution', () => {
  const duplicate = structuredClone(rules.cuit); duplicate.browser.services[1].aliases.push('电信');
  assert.throws(() => validateSchoolRule(duplicate), /AMBIGUOUS_BROWSER_SERVICES/);
  const missing = structuredClone(rules.cuit); missing.browser.serviceSelection.confirmSelectors = [];
  assert.throws(() => validateSchoolRule(missing), /INVALID_SERVICE_SELECTION/);
});
test('the complete provider refuses an account-only fallback without a fresh gateway entry', async () => {
  const rule = structuredClone(rules.cuit); rule.browser.discoveryProbes = [];
  const f = fixture('cuit'); const state = await mkdtemp(join(tmpdir(), 'campus-sam-context-'));
  const previous = process.env.CAMPUSLUMA_STATE_DIR; process.env.CAMPUSLUMA_STATE_DIR = state;
  try {
    const result = await authenticateSchool(rule, { ...credential, schoolId: 'cuit', service: f.service }, {
      probeInternet: async () => false, discoverPortal: async () => null,
      browserFactory: async () => { const b = await createBrowserAdapter(rule).launchBrowser(); const create = b.newContext.bind(b); b.newContext = async options => { const c = await create(options); await c.route('**/*', f.route); return c; }; return b; }
    });
    assert.equal(result.Code, 'PORTAL_CONTEXT_MISSING'); assert.equal(result.Submitted, false); assert.equal(f.passwords + f.choices, 0);
  } finally { previous === undefined ? delete process.env.CAMPUSLUMA_STATE_DIR : process.env.CAMPUSLUMA_STATE_DIR = previous; }
});
