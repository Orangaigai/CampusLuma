import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { loadSchoolRule, validateSchoolRule } from '../school-rules.mjs';
import { createBrowserAdapter } from '../browser-auth.mjs';

let browser, rule;
before(async () => { rule = await loadSchoolRule('xtu'); browser = await createBrowserAdapter(rule).launchBrowser(); });
after(async () => { await browser?.close(); });
function betaRule() {
  const second = structuredClone(rule);
  Object.assign(second, { id: 'fixture-b', name: '模拟乙校', defaultSsid: 'Fixture-B', fallbackPortal: 'https://portal.beta.invalid/login', trustedOrigins: ['https://portal.beta.invalid/'] });
  Object.assign(second.browser, { selfServiceUrl: 'https://portal.beta.invalid/self', usernameSelectors: ['#betaAccount'], passwordSelectors: ['#betaSecret'], submitSelectors: ['#betaSubmit'], agreementPattern: 'School consent' });
  return second;
}
test('only enabled registered rule identifiers can load', async () => {
  await assert.rejects(loadSchoolRule('../xtu'), /INVALID_SCHOOL_ID/);
  assert.throws(() => validateSchoolRule({ ...rule, enabled: false }), /SCHOOL_NOT_ENABLED/);
  assert.throws(() => validateSchoolRule({ ...rule, schemaVersion: 9 }), /INVALID_SCHOOL_RULE/);
  assert.throws(() => validateSchoolRule({ ...rule, entry: '../../other.ps1' }), /UNSUPPORTED_SCHOOL_ENGINE/);
});
test('school origins, ports and dynamic redirects are isolated between instances', () => {
  const alpha = createBrowserAdapter(rule), beta = createBrowserAdapter(betaRule());
  const url = 'https://portal.beta.invalid/login?terminal=dynamic&session=current';
  assert.equal(alpha.trustedPortal(url), false);
  assert.equal(beta.trustedPortal(url), true);
  assert.equal(beta.trustedPortal('https://portal.beta.invalid.evil.invalid/'), false);
  assert.equal(beta.trustedPortal('https://portal.beta.invalid:8443/'), false);
  assert.equal(beta.trustedPortal('https://user:pass@portal.beta.invalid/'), false);
  const html = `<script>location.href='${url}'</script>`;
  assert.deepEqual(beta.portalRedirects(html, 'http://gateway.invalid/'), [url]);
  assert.deepEqual(alpha.portalRedirects(html, 'http://gateway.invalid/'), []);
});
test('a second school really fills different selectors and its agreement with the shared browser engine', async () => {
  const alpha = createBrowserAdapter(rule), beta = createBrowserAdapter(betaRule());
  const context = await browser.newContext({ serviceWorkers: 'block' });
  let online = false, requests = 0;
  await context.route('**/*', async route => {
    if (route.request().method() === 'POST') {
      const values = JSON.parse(route.request().postData());
      assert.deepEqual(values, { account: 'fixture-beta-user', secret: 'fixture-beta-password-not-real', consent: true, remember: false });
      online = true; requests++;
      return route.fulfill({ contentType: 'application/json', body: '{"message":"ok"}' });
    }
    return route.fulfill({ contentType: 'text/html', body: `<!doctype html><form>
      <input id="betaAccount"><input id="betaSecret" type="password">
      <label><input id="consent" type="checkbox">School consent</label>
      <label><input id="remember" type="checkbox">Remember me</label><button id="betaSubmit">Connect</button>
      </form><script>document.querySelector('form').onsubmit=async event=>{event.preventDefault();await fetch('/login',{method:'POST',body:JSON.stringify({account:betaAccount.value,secret:betaSecret.value,consent:consent.checked,remember:remember.checked})})}</script>` });
  });
  try {
    const page = await context.newPage();
    const source = await beta.openPortal(page, 'https://portal.beta.invalid/login?terminal=fresh', []);
    assert.equal(source, 'NETWORK_REDIRECT');
    assert.equal(await alpha.findLoginForm(page, 10), null);
    assert.equal(await page.locator('#betaAccount').inputValue(), '');
    const reply = await beta.submitLogin(page, { username: 'fixture-beta-user', password: 'fixture-beta-password-not-real' }, { checkInternet: async () => online, resultWait: 20 });
    assert.equal(reply.Code, 'ONLINE_AFTER_AUTH');
    assert.equal(reply.Submitted, true);
    assert.equal(requests, 1);
  } finally { await context.close(); }
});
test('a rule cannot inject untrusted entry addresses or non-web discovery protocols', () => {
  const second = betaRule();
  assert.throws(() => validateSchoolRule({ ...second, fallbackPortal: 'https://zz.xtu.edu.cn/' }), /UNTRUSTED_SCHOOL_ENTRY/);
  second.browser.discoveryProbes = ['file:///C:/private'];
  assert.throws(() => validateSchoolRule(second), /INVALID_DISCOVERY_PROBE/);
});
