import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import iconv from 'iconv-lite';
import { authenticateSnnu, encodePortalForm, classifySnnuResponse } from '../snnu-auth.mjs';
import { authenticateSchool } from '../auth-provider.mjs';
import { directPortalRequest } from '../snnu-preflight.mjs';

const candidate = JSON.parse(await readFile(new URL('../../adapters/snnu.json', import.meta.url), 'utf8'));
const rule = { ...candidate, enabled: true }; // Isolated fixture; never rewrites the real disabled rule.
const origin = 'http://202.117.144.205:8605', login = origin + '/snnuportal/login.jsp', action = origin + '/snnuportal/login';
const payload = { schoolId: 'snnu', mode: 'authenticate', username: 'fixture-student', password: '中文+&pw', service: 'unicom' };
const form = `<form action="login" method="POST"><input name="sourceurl" TYPE="hidden" value="fixture-token">
<input type="text" name="account" maxlength="25"><input TYPE="PASSWORD" name="password" maxlength="25">
<input type="radio" name="yys" value="" checked><input type="radio" name="yys" value="unicom">
<input type="radio" name="yys" value="mobile"><input type="radio" name="yys" value="telecom">
<input type="checkbox" name="issave" checked><input type="button" value="连接"></form>`;
const online = account => `<input type="hidden" id="account" value="${account}"><p>当前登录账号</p>`;
function flow({ page = form, post = online('fixture-student@unicom'), status = 200, location, checks = [false, true], failPost = false } = {}) {
  const calls = [], sleeps = []; let probes = 0;
  return { calls, sleeps, get probes() { return probes; }, options: {
    maxVerificationChecks: 3, sleep: async ms => { sleeps.push(ms); }, probeInternet: async () => checks[Math.min(probes++, checks.length - 1)],
    request: async (url, options = {}) => {
      calls.push({ url, ...options, body: options.body ? Buffer.from(options.body) : undefined });
      if (options.method === 'POST') {
        if (failPost) { const error = new Error('fictional timeout'); error.name = 'TimeoutError'; throw error; }
        return { status, body: post, headers: { ...(location ? { location } : {}), 'set-cookie': ['JSESSIONID=fixture-session-2; Path=/snnuportal/'] } };
      }
      if (url.endsWith('/')) return { status: 200, headers: {}, body: `<script>document.location='${login}'</script>` };
      if (url.endsWith('userstatus.jsp')) return { status: 200, headers: {}, body: online('fixture-student@unicom') };
      return { status: 200, headers: { 'set-cookie': ['JSESSIONID=fixture-session-1; Path=/snnuportal/'] }, body: page };
    }
  }};
}
test('dynamic port, session, selected service and GB2312 form really reach a single POST', async () => {
  const f = flow(); const result = await authenticateSnnu(rule, payload, f.options);
  assert.equal(result.Code, 'ONLINE_AFTER_AUTH'); assert.equal(result.InternetVerified, true);
  const posts = f.calls.filter(c => c.method === 'POST'); assert.equal(posts.length, 1);
  assert.equal(posts[0].url, action); assert.equal(posts[0].cookie, 'JSESSIONID=fixture-session-1');
  assert.equal(posts[0].body.toString(), 'sourceurl=fixture-token&account=fixture-student&password=%D6%D0%CE%C4%2B%26pw&yys=unicom');
  assert.equal(posts[0].headers['Content-Length'], String(posts[0].body.length));
  assert.equal(posts[0].headers.Origin, origin); assert.equal(posts[0].headers.Referer, login);
  for (const secret of ['fixture-student', 'fixture-token', 'fixture-session', payload.password]) assert.equal(JSON.stringify(result).includes(secret), false);
});
test('full provider uses the configured Changan entry before other roots and keeps its fresh session', async () => {
  const f = flow();
  const result=await authenticateSchool(rule,{...payload,portalUrl:action},f.options);
  assert.equal(result.Code,'ONLINE_AFTER_AUTH');assert.equal(result.Submitted,true);
  assert.equal(f.calls[0].url,login);assert.equal(f.calls.filter(c=>c.method!=='POST').length,1);
  const posts=f.calls.filter(c=>c.method==='POST');assert.equal(posts.length,1);
  assert.equal(posts[0].url,action);assert.equal(posts[0].cookie,'JSESSIONID=fixture-session-1');
});
test('campus service is an explicit empty string and does not become missing or an account suffix', async () => {
  const f = flow({ post: online('fixture-student') });
  assert.equal((await authenticateSnnu(rule, { ...payload, service: '' }, f.options)).Code, 'ONLINE_AFTER_AUTH');
  assert.ok(f.calls.find(c => c.method === 'POST').body.toString().endsWith('&yys='));
});
test('missing or unknown service prevents all portal requests', async () => {
  for (const service of [undefined, null, 'unknown']) {
    const f = flow(); assert.equal((await authenticateSnnu(rule, { ...payload, service }, f.options)).Code, 'SERVICE_REQUIRED');
    assert.equal(f.calls.length, 0);
  }
});
test('already online performs no portal request or credential submission', async () => {
  const f = flow({ checks: [true] }); const result = await authenticateSnnu(rule, payload, f.options);
  assert.equal(result.Code, 'ONLINE'); assert.equal(result.Submitted, false); assert.equal(f.calls.length, 0);
});
test('a success or status page without external connectivity never reports success or submits twice', async () => {
  const f = flow({ checks: [false] }); const result = await authenticateSnnu(rule, payload, f.options);
  assert.equal(result.Code, 'LOGIN_SUBMITTED_OFFLINE'); assert.equal(result.Submitted, true);
  assert.equal(f.calls.filter(c => c.method === 'POST').length, 1);
});
test('delayed external authorization is awaited after the one submission', async () => {
  const f = flow({ checks: [false, false, true] });
  assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, 'ONLINE_AFTER_AUTH');
  assert.equal(f.sleeps.length, 1); assert.equal(f.calls.filter(c => c.method === 'POST').length, 1);
});
test('password rejection stops immediately with no second submission or fallback account format', async () => {
  const f = flow({ post: '<p>账号或密码错误</p>', checks: [false] });
  assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, 'LOGIN_REJECTED');
  assert.equal(f.probes, 1); assert.equal(f.calls.filter(c => c.method === 'POST').length, 1);
});
for (const [text, code] of [['需要输入验证码', 'CAPTCHA_REQUIRED'], ['用户已欠费', 'ACCOUNT_ARREARS'],
  ['非可认证时间', 'AUTH_TIME_RESTRICTED'], ['在线设备超过上限', 'DEVICE_LIMIT'], ['运营商未绑定', 'SERVICE_REJECTED']]) {
  test('classifies the server outcome: ' + code, async () => {
    const f = flow({ post: `<p>${text}</p>`, checks: [false] });
    assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, code);
    assert.equal(f.calls.filter(c => c.method === 'POST').length, 1);
  });
}
test('script strings and HTML comments cannot become server errors', () => {
  assert.equal(classifySnnuResponse('<script>const label="密码错误，请输入验证码";</script><!-- 密码错误 --><p>状态</p>'), null);
});
test('conditional captcha stops before sending credentials', async () => {
  const f = flow({ page: form.replace('</form>', '<input name="checkcode"></form>') });
  const result = await authenticateSnnu(rule, payload, f.options);
  assert.equal(result.Code, 'CAPTCHA_REQUIRED'); assert.equal(result.Submitted, false);
});
test('unsupported password characters, semicolons and maxlength never cause silent truncation', async () => {
  for (const [password, code] of [['🪄pw', 'CREDENTIAL_ENCODING_UNSUPPORTED'], ['bad;pw', 'CREDENTIAL_FORMAT_UNSUPPORTED'], ['x'.repeat(26), 'CREDENTIAL_LENGTH_UNSUPPORTED']]) {
    const f = flow(); assert.equal((await authenticateSnnu(rule, { ...payload, password }, f.options)).Code, code);
    assert.equal(f.calls.some(c => c.method === 'POST'), false);
  }
});
test('encoding handles special characters and rejects unrepresentable characters', () => {
  assert.equal(encodePortalForm([['k', 'a b+&=中']]).toString(), 'k=a+b%2B%26%3D%D6%D0');
  assert.throws(() => encodePortalForm([['k', '🪄']]), /CREDENTIAL_ENCODING_UNSUPPORTED/);
});
test('form actions to another host or registered port are refused', async () => {
  for (const url of ['http://outside.invalid/login', 'http://202.117.144.205:8609/snnuportal/login']) {
    const f = flow({ page: form.replace('action="login"', `action="${url}"`) });
    const result = await authenticateSnnu(rule, payload, f.options);
    assert.equal(result.Code, 'UNTRUSTED_FORM_ACTION'); assert.equal(result.Submitted, false);
  }
});
test('POST redirect retains the new cookie and becomes a GET to the same-origin status page', async () => {
  const f = flow({ post: '', status: 302, location: '/snnuportal/userstatus.jsp' });
  assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, 'ONLINE_AFTER_AUTH');
  const last = f.calls.at(-1); assert.equal(last.method, 'GET'); assert.equal(last.cookie, 'JSESSIONID=fixture-session-2');
});
for (const location of ['http://outside.invalid/collect', '/snnuportal/logoff', '/snnuportal/bind']) {
  test('does not follow a credential-response redirect to ' + location, async () => {
    const f = flow({ post: '', status: 302, location });
    assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, 'UNTRUSTED_REDIRECT');
    assert.equal(f.calls.length, 3);
  });
}
test('307 does not automatically resend the password', async () => {
  const f = flow({ status: 307, location: '/snnuportal/login' });
  assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, 'AUTH_REDIRECT_UNSUPPORTED');
  assert.equal(f.calls.filter(c => c.method === 'POST').length, 1);
});
test('POST timeout remains a submitted attempt and is not retried', async () => {
  const f = flow({ failPost: true }); const result = await authenticateSnnu(rule, payload, f.options);
  assert.equal(result.Code, 'PORTAL_TIMEOUT'); assert.equal(result.Submitted, true);
  assert.equal(f.calls.filter(c => c.method === 'POST').length, 1);
});
test('portal-only online, another account and service mismatch do not trigger logout or relogin', async () => {
  for (const [account, code] of [['fixture-student@unicom', 'PORTAL_SESSION_OFFLINE'], ['another-fixture@unicom', 'OTHER_PORTAL_SESSION'], ['fixture-student@mobile', 'SERVICE_MISMATCH']]) {
    const f = flow({ page: online(account), checks: [false] });
    assert.equal((await authenticateSnnu(rule, payload, f.options)).Code, code);
    assert.equal(f.calls.some(c => c.method === 'POST' || /logoff|bind/.test(c.url)), false);
  }
});
test('the real disabled rule and mismatched school cannot enter authentication', async () => {
  const f = flow(); await assert.rejects(authenticateSchool(candidate, payload, f.options), /SCHOOL_NOT_ENABLED/);
  assert.equal((await authenticateSchool(rule, { ...payload, schoolId: 'xtu' }, f.options)).Code, 'CREDENTIAL_SCHOOL_MISMATCH');
  assert.equal(f.calls.length, 0);
});
test('real HTTP transport carries the intended body and cookie through a local mock portal', async () => {
  let posts = 0, postedBody = '', postedCookie = '';
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html;charset=GB2312');
    if (req.url === '/') { res.end(`<script>location.href='${login}'</script>`); return; }
    if (req.method === 'POST') {
      posts++; const chunks = []; req.on('data', b => chunks.push(b));
      req.on('end', () => { postedBody = Buffer.concat(chunks).toString(); postedCookie = req.headers.cookie;
        res.end(iconv.encode(online('fixture-student@unicom'), 'gb2312')); }); return;
    }
    res.setHeader('Set-Cookie', 'JSESSIONID=local-fixture; Path=/snnuportal/'); res.end(iconv.encode(form, 'gb2312'));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const result = await authenticateSnnu(rule, payload, { probeInternet: async () => posts > 0,
      request: (url, options) => directPortalRequest(`http://127.0.0.1:${server.address().port}${new URL(url).pathname}`, options) });
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH'); assert.equal(posts, 1); assert.equal(postedCookie, 'JSESSIONID=local-fixture');
    assert.ok(postedBody.includes('password=%D6%D0%CE%C4%2B%26pw')); assert.ok(postedBody.includes('yys=unicom'));
  } finally { await new Promise(resolve => server.close(resolve)); }
});
test('native transport timeouts have the same typed outcome as an interrupted authentication', async () => {
  const server = http.createServer(() => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    await assert.rejects(directPortalRequest(`http://127.0.0.1:${server.address().port}/fixture`,
      { method: 'POST', body: Buffer.from('fixture=only'), timeoutMs: 30 }), error => error.name === 'TimeoutError');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});
