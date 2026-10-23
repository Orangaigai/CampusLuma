import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import { createDecipheriv } from 'node:crypto';
import { authenticateSchool } from '../auth-provider.mjs';
import { validateSchoolRule } from '../school-rules.mjs';
import { authenticateDrcom, inspectDrcomPortal, parseJsonp, validateNetwork, classifyDrcomResponse, encryptDrcomParams } from '../drcom-auth.mjs';
import { directPortalRequest } from '../snnu-preflight.mjs';

const candidates = {};
for (const id of ['hnust', 'hunnu']) candidates[id] = JSON.parse(await readFile(new URL('../../adapters/' + id + '.json', import.meta.url), 'utf8'));
const rules = Object.fromEntries(Object.entries(candidates).map(([id, r]) => [id, { ...r, enabled: true }]));
const base = { username: 'fixture-student', password: '中文+&pw', network: { ipv4: '10.24.3.45', mac: '02-11-22-33-44-55' } };
const pages = { hnust: `<script src="/drcom.js"></script>`, hunnu: `<script src="/js/portal.js"></script>` };
const scripts = { hnust: `var url='/eportal/portal/login';var jsVersion='4.2.1';`, hunnu: `var endpoint='loadConfig';var rcn='from-server';var AES='5c1d5ad4dea0e8dd';` };
function flow(id, { page = pages[id], script = scripts[id], response = { result: 1 }, rcn = 'fixture-fresh-rcn', checks = [false, true], redirect, failAuth = false, port = 801 } = {}) {
  const rule = rules[id], calls = []; let count = 0;
  return { calls, options: { maxVerificationChecks: 2, sleep: async () => {}, probeInternet: async () => checks[Math.min(count++, checks.length - 1)],
    request: async (raw, options = {}) => {
      const url = new URL(raw); calls.push({ url, ...options });
      if (url.pathname === '/eportal/portal/login') {
        if (failAuth) { const e = new Error('fixture timeout'); e.name = 'TimeoutError'; throw e; }
        return { status: redirect ? 302 : 200, headers: redirect ? { location: redirect } : {}, body: 'dr' + (id === 'hunnu' ? '1006' : '1003') + '(' + JSON.stringify(response) + ');' };
      }
      if (url.pathname.endsWith('/loadConfig')) return { status: 200, headers: {}, body: 'dr1001(' + JSON.stringify({ data: rcn ? { rcn } : {} }) + ');' };
      if (!rule.trustedOrigins.includes(url.origin)) return { status: 302, headers: { location: rule.fallbackPortal + '?wlanuserip=' + base.network.ipv4 }, body: '' };
      if (url.pathname.endsWith('.js')) return { status: 200, headers: {}, body: script };
      return { status: 200, headers: {}, body: page };
    } } };
}
function payload(id, service) { return { ...base, schoolId: id, service: service ?? (id === 'hnust' ? 'telecom' : '0'), mode: 'authenticate' }; }
function decrypt(value, key) { const d = createDecipheriv('aes-128-ecb', Buffer.from(key), null); return JSON.parse(Buffer.concat([d.update(Buffer.from(value, 'base64')), d.final()]).toString('utf8')); }
for (const id of ['hnust', 'hunnu']) {
  test(id + ': dispatcher discovers current page and performs exactly one credential request', async () => {
    const f = flow(id); const result = await authenticateSchool(rules[id], payload(id), f.options);
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH'); assert.equal(result.InternetVerified, true);
    const login = f.calls.filter(c => c.url.pathname === '/eportal/portal/login'); assert.equal(login.length, 1);
    assert.equal(login[0].url.origin, rules[id].protocol.apiOrigin);
    let data;
    if (id === 'hnust') data = Object.fromEntries(login[0].url.searchParams);
    else { data = decrypt(login[0].url.searchParams.get('params'), rules[id].protocol.aesKey); assert.equal(data.rcn, 'fixture-fresh-rcn'); }
    assert.equal(data.user_account, id === 'hnust' ? ',0,fixture-student@telecom' : ',0,fixture-student');
    assert.equal(data.user_password, base.password); assert.equal(String(data.terminal_type), '1'); assert.equal(data.wlan_user_ip, base.network.ipv4); assert.equal(data.wlan_user_mac, '021122334455');
    for (const secret of [base.username, base.password, base.network.ipv4, 'fixture-fresh-rcn', 'params=']) assert.ok(!JSON.stringify(result).includes(secret));
  });
  test(id + ': online skips every portal request', async () => { const f = flow(id, { checks: [true] }); assert.equal((await authenticateDrcom(rules[id], payload(id), f.options)).Code, 'ONLINE'); assert.equal(f.calls.length, 0); });
  test(id + ': service is explicit and unknown choices are rejected', async () => { for (const service of [null, undefined, 'unknown']) { const f = flow(id); assert.equal((await authenticateDrcom(rules[id], { ...payload(id), service }, f.options)).Code, 'SERVICE_REQUIRED'); assert.equal(f.calls.length, 0); } });
  test(id + ': missing and virtual NICs are rejected before any request', async () => { for (const network of [undefined, { ...base.network, ipv4: '198.18.0.1' }, { ...base.network, ipv4: '127.0.0.1' }]) { const f = flow(id); assert.equal((await authenticateDrcom(rules[id], { ...payload(id), network }, f.options)).Code, 'CAMPUS_INTERFACE_REQUIRED'); assert.equal(f.calls.length, 0); } });
  test(id + ': old or unrelated login page cannot receive the password', async () => { const f = flow(id, { page: '<form>CAS 身份认证</form><script src="/drcom.js"></script>', script: "var old='/eportal/InterFace.do';" }); assert.equal((await authenticateDrcom(rules[id], payload(id), f.options)).Code, 'PORTAL_VERSION_UNRECOGNIZED'); assert.ok(!f.calls.some(c => c.url.pathname.endsWith('/login'))); });
  test(id + ': incorrect password is not retried', async () => { const f = flow(id, { response: { result: 0, msg: 'userid error2' } }); const r = await authenticateDrcom(rules[id], payload(id), f.options); assert.equal(r.Code, 'LOGIN_REJECTED'); assert.equal(r.Submitted, true); assert.equal(f.calls.filter(c => c.url.pathname.endsWith('/login')).length, 1); });
  test(id + ': portal success and result zero alone do not prove Internet access', async () => { for (const result of [0, 1]) { const f = flow(id, { response: { result }, checks: [false] }); assert.equal((await authenticateDrcom(rules[id], payload(id), f.options)).Code, 'LOGIN_SUBMITTED_OFFLINE'); } });
  test(id + ': interrupted submission is recorded and never resent', async () => { const f = flow(id, { failAuth: true }); const r = await authenticateDrcom(rules[id], payload(id), f.options); assert.equal(r.Code, 'PORTAL_TIMEOUT'); assert.equal(r.Submitted, true); assert.equal(f.calls.filter(c => c.url.pathname.endsWith('/login')).length, 1); });
  test(id + ': submission redirect is not followed to logout or another host', async () => { for (const redirect of ['http://outside.invalid/collect', '/eportal/portal/logout']) { const f = flow(id, { redirect }); assert.equal((await authenticateDrcom(rules[id], payload(id), f.options)).Code, 'AUTH_REDIRECT_UNSUPPORTED'); assert.ok(!f.calls.some(c => c.url.hostname === 'outside.invalid' || c.url.pathname.endsWith('/logout'))); } });
  test(id + ': disabled candidate and cross-school credential cannot authenticate', async () => { const f = flow(id); await assert.rejects(authenticateSchool(candidates[id], payload(id), f.options), /SCHOOL_NOT_ENABLED/); assert.equal((await authenticateSchool(rules[id], { ...payload(id), schoolId: 'xtu' }, f.options)).Code, 'CREDENTIAL_SCHOOL_MISMATCH'); assert.equal(f.calls.length, 0); });
  test(id + ': discovery follows fresh query and detects a stale client IP', async () => { const f = flow(id); const r = await authenticateDrcom(rules[id], { ...payload(id), network: { ...base.network, ipv4: '10.24.3.46' } }, f.options); assert.equal(r.Code, 'CAMPUS_IP_MISMATCH'); assert.equal(r.Submitted, false); });
  test(id + ': readonly preflight does not call login, config, logout or execute scripts', async () => { const f = flow(id); const r = await inspectDrcomPortal(rules[id], f.options); assert.equal(r.Code, 'PORTAL_VERSION_RECOGNIZED'); assert.equal(r.CredentialSubmission, false); assert.ok(f.calls.every(c => c.method === 'GET' && !/\/(login|loadConfig|logout)$/.test(c.url.pathname))); });
  test(id + ': native HTTP roundtrip reaches loopback portal despite proxy environment', async () => {
    const before = { HTTP_PROXY: process.env.HTTP_PROXY, HTTPS_PROXY: process.env.HTTPS_PROXY, ALL_PROXY: process.env.ALL_PROXY };
    let submissions = 0; let seen;
    const server = http.createServer((req, res) => { const u = new URL(req.url, 'http://fixture.invalid'); res.setHeader('Content-Type', 'application/json;charset=utf-8');
      if (u.pathname.endsWith('/loadConfig')) { res.end('dr1001({"data":{"rcn":"loopback-rcn"}});'); return; }
      if (u.pathname.endsWith('/login')) { submissions++; seen = id === 'hunnu' ? decrypt(u.searchParams.get('params'), rules[id].protocol.aesKey) : Object.fromEntries(u.searchParams); res.end((id === 'hunnu' ? 'dr1006' : 'dr1003') + '({"result":1});'); return; }
      res.end(u.pathname.endsWith('.js') ? scripts[id] : pages[id]); });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try { for (const k of Object.keys(before)) process.env[k] = 'http://127.0.0.1:1';
      const result = await authenticateDrcom(rules[id], payload(id), { probeInternet: async () => submissions > 0,
        request: (raw, options) => { const u = new URL(raw); return directPortalRequest('http://127.0.0.1:' + server.address().port + u.pathname + u.search, options); } });
      assert.equal(result.Code, 'ONLINE_AFTER_AUTH'); assert.equal(submissions, 1); assert.equal(seen.user_password, base.password);
    } finally { for (const [k, value] of Object.entries(before)) value === undefined ? delete process.env[k] : process.env[k] = value; await new Promise(resolve => server.close(resolve)); }
  });
}
test('HNUST explicit campus selection keeps an empty suffix', async () => { const f = flow('hnust'); assert.equal((await authenticateDrcom(rules.hnust, payload('hnust', ''), f.options)).Code, 'ONLINE_AFTER_AUTH'); assert.equal(f.calls.find(c => c.url.pathname.endsWith('/login')).url.searchParams.get('user_account'), ',0,fixture-student'); });
test('HUNNU service selection is encoded without guessing from account suffix', async () => { const f = flow('hunnu'); await authenticateDrcom(rules.hunnu, payload('hunnu', '2'), f.options); const u = f.calls.find(c => c.url.pathname.endsWith('/login')).url; assert.equal(decrypt(u.searchParams.get('params'), rules.hunnu.protocol.aesKey).user_account, ',2,fixture-student'); });
test('HUNNU requires a fresh server nonce and refuses a guessed fallback', async () => { const f = flow('hunnu', { rcn: null }); const r = await authenticateDrcom(rules.hunnu, payload('hunnu'), f.options); assert.equal(r.Code, 'PORTAL_CONFIG_UNRECOGNIZED'); assert.equal(r.Submitted, false); });
test('HUNNU new encryption key stops before sending credentials', async () => { const f = flow('hunnu', { script: "var loadConfig='';var rcn='';var AES='differentkey1234';" }); assert.equal((await authenticateDrcom(rules.hunnu, payload('hunnu'), f.options)).Code, 'PORTAL_VERSION_UNRECOGNIZED'); });
test('authentication assets after vendor bundles are inspected within the same request budget', async () => { for(const id of ['hnust','hunnu']){const f=flow(id,{page:'<script src="/jquery.js"></script><script src="/vue.js"></script><script src="/vendor.js"></script>'+pages[id]});const request=f.options.request;f.options.request=(url,options)=>/jquery|vue|vendor/.test(url)?Promise.resolve({status:200,headers:{},body:'/* unrelated vendor */'}):request(url,options);const r=await authenticateDrcom(rules[id],payload(id),f.options);assert.equal(r.Code,'ONLINE_AFTER_AUTH');assert.ok(r.Requests<=10);}});
test('shared captcha JS code does not imply a required captcha but a real input stops submission', async () => { for (const id of ['hnust','hunnu']) { const ordinary=flow(id,{script:scripts[id]+";var captcha='optional';"});assert.equal((await authenticateDrcom(rules[id],payload(id),ordinary.options)).Code,'ONLINE_AFTER_AUTH');const required=flow(id,{page:pages[id]+'<input name="checkcode">'});const r=await authenticateDrcom(rules[id],payload(id),required.options);assert.equal(r.Code,'CAPTCHA_REQUIRED');assert.equal(r.Submitted,false); } });
test('newly advertised gateway stops before posting to an old fixed server', async () => { const f=flow('hnust',{script:scripts.hnust+";var login='http://192.168.254.227:801/eportal/portal/login';"});const r=await authenticateDrcom(rules.hnust,payload('hnust'),f.options);assert.equal(r.Code,'PORTAL_ENDPOINT_CHANGED');assert.equal(r.Submitted,false); });
test('changed frontend version cannot reuse old fields even with the same API path', async () => { for (const id of ['hnust','hunnu']) { const f=flow(id,{script:scripts[id]+";var jsVersion='5.0.0';"});const r=await authenticateDrcom(rules[id],payload(id),f.options);assert.equal(r.Code,'PORTAL_VERSION_UNRECOGNIZED');assert.equal(r.Submitted,false); } });
test('malformed JSONP is parsed without evaluating JavaScript', () => { for (const value of ['evil({"result":1})', 'dr1003({"result":1});alert(1)', 'dr1003({result:1})', '[]']) assert.throws(() => parseJsonp(value, 'dr1003')); assert.deepEqual(parseJsonp('dr1003({"result":1});', 'dr1003'), { result: 1 }); });
test('network input excludes unspecified, loopback, multicast, public and TUN addresses', () => { for (const ip of ['0.0.0.0', '127.0.0.1', '224.0.0.1', '8.8.8.8', '169.254.1.1', '198.18.0.1']) assert.equal(validateNetwork({ ...base.network, ipv4: ip }), null); assert.ok(validateNetwork({ ...base.network, ipv4: '172.18.10.0' })); });
test('carrier errors, quota, captcha and device limits have distinct outcomes', () => { for (const [msg, expected] of [['109026001', 'SERVICE_REJECTED'], ['109026002', 'ACCOUNT_ARREARS'], ['109026004', 'DEVICE_LIMIT'], ['验证码错误', 'CAPTCHA_REQUIRED'], [Buffer.from('userid error2').toString('base64'), 'LOGIN_REJECTED']]) assert.equal(classifyDrcomResponse({ msg }), expected); });
test('rules cannot add a private collection host or change cipher/endpoint', () => { for (const id of ['hnust', 'hunnu']) { for (const change of [r => r.trustedOrigins.push('http://collector.invalid'), r => r.protocol.apiOrigin = 'http://collector.invalid', r => r.protocol.services[0].value = 'unknown']) { const r = structuredClone(rules[id]); change(r); assert.throws(() => validateSchoolRule(r)); } } });
test('AES serialization matches a vector independently computed by Windows .NET AES', () => { assert.equal(encryptDrcomParams({ a: 1 }, '5c1d5ad4dea0e8dd'), 'LrzOaRNV4PCVDAXDXFgBnw=='); });
