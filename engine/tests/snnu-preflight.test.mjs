import test from 'node:test';
import assert from 'node:assert/strict';
import { loadSnnuResearchProfile, trusted, inspectSnnuPage, decodePortalBody, preflightSnnu } from '../snnu-preflight.mjs';
import { loadSchoolRule } from '../school-rules.mjs';

const profile = await loadSnnuResearchProfile();
const origin = 'http://202.117.144.205:8609';
const pageUrl = origin + profile.loginPage;
// Original synthetic markup using publicly documented field names; no copied page.
const form = `<form method='post' action='login'>
<input name='sourceurl' type='hidden' value='fixture-hidden'>
<input name='account' type='text'><input type='password' name='password'>
<input type='radio' name='yys' value=''><input type='radio' name='yys' value='unicom'>
<input type='radio' name='yys' value='mobile'><input type='radio' name='yys' value='telecom'>
<input name='issave' type='checkbox'><input type='button' value='连接'></form>`;
const online = `<input type='hidden' id='account' value='fixture-user@unicom'><p>当前登录账号</p>`;
const response = (body, status = 200, headers = {}) => ({ body, status, headers });

test('SNNU public research stays disabled in the actual executable registry', async () => {
  assert.equal(profile.ssid, 'SNNU');
  assert.deepEqual(profile.observedPorts, [8601, 8602, 8603, 8605, 8609]);
  await assert.rejects(loadSchoolRule('snnu'), /SCHOOL_NOT_ENABLED/);
});
test('explicit origins permit documented ports and reject spoofed hosts or URL credentials', () => {
  assert.equal(trusted(profile, pageUrl), true);
  for (const value of ['http://202.117.144.205.evil.invalid:8609/snnuportal/login.jsp',
    'http://user:secret@202.117.144.205:8609/snnuportal/login.jsp', 'http://202.117.144.205:8607/snnuportal/login.jsp']) assert.equal(trusted(profile, value), false);
});
test('GB2312 bytes are decoded using the portal charset', () => {
  assert.equal(decodePortalBody(Uint8Array.from([0xd6, 0xd0, 0xce, 0xc4]), 'text/html;charset=GB2312'), '中文');
});
test('form inspection recognizes services and hidden field names without exposing field values', () => {
  const result = inspectSnnuPage(profile, pageUrl, form);
  assert.equal(result.Code, 'PORTAL_FORM_READY');
  assert.equal(result.SubmitPath, '/snnuportal/login');
  assert.deepEqual(result.ServiceValues, ['', 'unicom', 'mobile', 'telecom']);
  assert.deepEqual(result.HiddenFieldNames, ['sourceurl']);
  assert.equal(JSON.stringify(result).includes('fixture-hidden'), false);
});
test('a static captcha image does not imply that the conditional captcha input is required', () => {
  assert.equal(inspectSnnuPage(profile, pageUrl, form + '<img src="imageServlet">').Code, 'PORTAL_FORM_READY');
});
test('the actual captcha input reports manual intervention without attempting a submission', async () => {
  let calls = 0;
  const result = await preflightSnnu(profile, { request: async () => ++calls === 1 ? response('', 302, { location: pageUrl }) :
    response(form.replace('</form>', '<input name="checkcode"></form>')) });
  assert.equal(result.Code, 'CAPTCHA_REQUIRED'); assert.equal(result.CredentialSubmission, false);
});
test('discovers a current JS-selected port, keeps the session through HTTP redirects and redacts it', async () => {
  const calls = [];
  const result = await preflightSnnu(profile, { request: async (url, options) => {
    calls.push([url, options.cookie]);
    if (calls.length === 1) return response(`<script>window.location.href='${pageUrl}';</script>`);
    if (calls.length === 2) return response('', 302, { location: profile.statusPage, 'set-cookie': ['JSESSIONID=fixture-session; Path=/snnuportal/; HttpOnly'] });
    return response(online);
  }});
  assert.equal(result.Code, 'PORTAL_SESSION_PRESENT');
  assert.equal(calls[1][0], pageUrl); assert.equal(calls[2][1], 'JSESSIONID=fixture-session');
  assert.equal(result.ReadOnly, true); assert.equal(result.CredentialSubmission, false);
  assert.equal(JSON.stringify(result).includes('fixture-user'), false);
  assert.equal(JSON.stringify(result).includes('fixture-session'), false);
  assert.equal(result.Success, undefined); // Portal state is not external Internet verification.
});
test('meta refresh and relative navigation discover the documented form', async () => {
  let calls = 0;
  const result = await preflightSnnu(profile, { request: async () => ++calls === 1 ?
    response('<meta http-equiv="refresh" content="0;url=/snnuportal/login.jsp">') : response(form) });
  assert.equal(result.Code, 'PORTAL_FORM_READY'); assert.equal(calls, 2);
});
test('unreachable roots use only registered login pages and still submit nothing', async () => {
  const calls = [];
  const result = await preflightSnnu(profile, { request: async url => {
    calls.push(url); if (calls.length < 3) throw new Error('fictional timeout'); return response(form);
  }});
  assert.equal(result.Code, 'PORTAL_FORM_READY');
  assert.equal(calls[2], 'http://202.117.144.205:8601/snnuportal/login.jsp');
  assert.equal(result.CredentialSubmission, false);
});
for (const [name, location] of [
  ['another host', 'http://outside.invalid/collect'],
  ['an unregistered port', 'http://202.117.144.205:8607/snnuportal/login.jsp'],
  ['logout', '/snnuportal/logoff'],
  ['binding changes', '/snnuportal/bind'],
  ['an authentication action', '/snnuportal/login']
]) test('never follows a read-only redirect to ' + name, async () => {
  let calls = 0;
  const result = await preflightSnnu(profile, { request: async () => { calls++; return response('', 302, { location }); } });
  assert.equal(result.Code, 'UNTRUSTED_REDIRECT'); assert.equal(calls, 1);
});
test('form action to a different host is rejected before any request there', async () => {
  let calls = 0;
  const result = await preflightSnnu(profile, { request: async () => { calls++; return response(form.replace("action='login'", "action='http://outside.invalid/collect'")); } });
  assert.equal(result.Code, 'UNTRUSTED_FORM_ACTION'); assert.equal(calls, 1);
});
test('synthetic plain carrier value is not silently treated as the observed empty campus value', () => {
  assert.equal(inspectSnnuPage(profile, pageUrl, form.replace("name='yys' value=''", "name='yys' value='plain'")).Code, 'UNKNOWN_SERVICE_VALUES');
});
test('unexpected GET form or base element stops inspection as unsupported', () => {
  assert.equal(inspectSnnuPage(profile, pageUrl, form.replace("method='post'", "method='get'")).Code, 'UNEXPECTED_FORM_METHOD');
  assert.equal(inspectSnnuPage(profile, pageUrl, '<base href="http://outside.invalid">' + form).Code, 'UNSUPPORTED_BASE_ELEMENT');
});
test('login page wording and JS markers alone cannot claim a portal session', () => {
  assert.equal(inspectSnnuPage(profile, pageUrl, '<script>const label="当前登录账号";</script>' + form).Code, 'PORTAL_FORM_READY');
  assert.equal(inspectSnnuPage(profile, pageUrl, '<p>当前登录账号</p><input type="hidden" id="account" value="">').Code, 'PORTAL_PAGE_UNRECOGNIZED');
});
test('loops and transport failures are bounded by the request budget', async () => {
  let calls = 0;
  const result = await preflightSnnu(profile, { maxRequests: 2, request: async () => { calls++; throw new Error('fictional timeout'); } });
  assert.equal(result.Code, 'PREFLIGHT_BUDGET_EXHAUSTED'); assert.equal(calls, 2);
  const loop = await preflightSnnu(profile, { maxRequests: 2, request: async url => response('', 302, { location: url }) });
  assert.equal(loop.Code, 'PREFLIGHT_BUDGET_EXHAUSTED'); assert.equal(loop.Requests, 2);
});

test('Changan supplied submission URL reads its fresh 8605 form first within a one-request budget', async () => {
  const calls = [];
  const result = await preflightSnnu(profile, { preferredPortal:'http://202.117.144.205:8605/snnuportal/login', maxRequests:1,
    request:async (url, options)=>{calls.push([url,options.method||'GET']);return response(form);} });
  assert.equal(result.Code,'PORTAL_FORM_READY');
  assert.deepEqual(calls,[['http://202.117.144.205:8605/snnuportal/login.jsp','GET']]);
  assert.equal(result.CredentialSubmission,false);
});

test('configured entry removes stale query and fragment values before reading a new form', async () => {
  const calls = [];
  const result = await preflightSnnu(profile, { preferredPortal:pageUrl+'?sourceurl=fixture-stale-session#fixture-old',
    request:async url=>{calls.push(url);return response(form);} });
  assert.deepEqual(calls,[pageUrl]);assert.equal(result.Code,'PORTAL_FORM_READY');
  assert.equal(JSON.stringify(result).includes('fixture-stale-session'),false);
});

test('an unavailable preferred port falls back to the current root-selected port without duplicate candidates', async () => {
  const calls = [];
  const result = await preflightSnnu(profile, { preferredPortal:'http://202.117.144.205:8605/snnuportal/login',
    request:async url=>{calls.push(url);if(calls.length===1)throw Error('fixture unreachable');
      return calls.length===2?response('',302,{location:pageUrl}):response(form);} });
  assert.deepEqual(calls,['http://202.117.144.205:8605/snnuportal/login.jsp',profile.roots[0],pageUrl]);
  assert.equal(result.Code,'PORTAL_FORM_READY');assert.equal(result.CredentialSubmission,false);
});

test('preferred origin or mutating path is rejected before requests', async () => {
  for(const preferredPortal of ['http://202.117.144.205:8607/snnuportal/login','http://outside.invalid/login',
    'http://202.117.144.205:8605/snnuportal/logoff','http://user:fixture@202.117.144.205:8605/snnuportal/login']){
    const result=await preflightSnnu(profile,{preferredPortal,request:async()=>assert.fail('must not request')});
    assert.equal(result.Code,'UNTRUSTED_PORTAL');assert.equal(result.Requests,0);
  }
});
