import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  launchBrowser, submitLogin, trustedPortal, portalRedirects, classifyMessage,
  directEnvironment, solveCaptcha, openPortal, classifyServerReply, authenticate,
} from '../xtu-browser.mjs';

let browser;
before(async () => { browser = await launchBrowser(); });
after(async () => { await browser?.close(); });
const account = { username: 'fixture-user', password: 'fixture-password' };
const root = 'https://zz.xtu.edu.cn';

test('rejects an untrusted configured fallback before opening a browser', async () => {
  const result = await authenticate({ ...account, portalUrl: 'https://zz.xtu.edu.cn.evil.test/' });
  assert.equal(result.Code, 'UNTRUSTED_PORTAL');
  assert.equal(result.Submitted, false);
});

test('uses the configured fallback URL when no discovery probes are supplied', async () => {
  const context = await browser.newContext();
  await context.route('**/*', route => route.fulfill({ contentType: 'text/html', body: '<input name="username"><input type="password">' }));
  try {
    const page = await context.newPage();
    const source = await openPortal(page, null, [], root + '/portal/configured-fallback');
    assert.equal(source, 'SELF_SERVICE_FALLBACK');
    assert.equal(page.url(), root + '/portal/configured-fallback');
  } finally { await context.close(); }
});

function formHtml({ captcha = false, action = '/api/login' } = {}) {
  return `<!doctype html><meta charset="UTF-8"><form action="${action}">
    <input type="hidden" id="userId" value="unrelated">
    <input id="nameInput" name="username"><input type="password" id="pwd">
    <input type="checkbox" id="remember"><label for="remember">记住我</label>
    <input type="checkbox" id="agreement" style="display:none"><label for="agreement">我已阅读并同意用户协议</label>
    ${captcha ? '<input name="captcha_code"><img id="captchaImage" width="120" height="40" src="/captcha.svg">' : ''}
    <button id="submitBtn" type="submit">立即登录</button><p id="feedback"></p>
    </form><script>
    document.querySelector('form').addEventListener('submit',async event=>{
      event.preventDefault();
      const response=await fetch(document.querySelector('form').action,{method:'POST',body:JSON.stringify({
        username:document.querySelector('#nameInput').value,password:document.querySelector('#pwd').value,
        agreement:document.querySelector('#agreement').checked,remember:document.querySelector('#remember').checked,
        captcha:document.querySelector('[name=captcha_code]')?.value
      })});
      const data=await response.json();document.querySelector('#feedback').textContent=data.message;
    });</script>`;
}

async function fixture(html, onSubmit) {
  const context = await browser.newContext({ serviceWorkers: 'block' });
  await context.route('**/*', async route => {
    const request = route.request();
    const pathname = new URL(request.url()).pathname;
    if (request.method() === 'POST') {
      const result = await onSubmit(JSON.parse(request.postData()));
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify(result) });
    }
    if (pathname === '/frame') return route.fulfill({ contentType: 'text/html', body: html });
    if (pathname === '/captcha.svg') return route.fulfill({ contentType: 'image/svg+xml',
      body: '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><rect width="120" height="40" fill="white"/><text x="4" y="30" font-size="28">1234</text></svg>' });
    return route.fulfill({ contentType: 'text/html', body: '<!doctype html><iframe src="/frame" width="800" height="600"></iframe>' });
  });
  const page = await context.newPage();
  await page.goto(`${root}/portal?wlanuserip=fixture`);
  return { context, page };
}

test('recognizes current portal redirects and rejects lookalike hosts', () => {
  const redirect = `${root}/portal?terminal=a&amp;ap=b`;
  assert.deepEqual(portalRedirects(`<script>top.self.location.href='${redirect}'</script>`, 'http://1.2.3.4/'),
    [`${root}/portal?terminal=a&ap=b`]);
  assert.deepEqual(portalRedirects('HTTP/1.1 302\r\nLocation: https://zz.xtu.edu.cn/portal?a=b\r\n', 'http://1.2.3.4/'),
    [`${root}/portal?a=b`]);
  assert.equal(trustedPortal('https://zz.xtu.edu.cn.evil.test/'), false);
  assert.equal(trustedPortal('https://zz.xtu.edu.cn@evil.test/'), false);
});

test('fills an iframe form, accepts only the agreement, verifies actual connectivity', async () => {
  let online = false, submissions = 0;
  const { context, page } = await fixture(formHtml(), data => {
    submissions++;
    assert.equal(data.username, account.username);
    assert.equal(data.password, account.password);
    assert.equal(data.agreement, true);
    assert.equal(data.remember, false);
    online = true;
    return { message: '登录成功' };
  });
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => online, resultWait: 20 });
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH');
    assert.equal(submissions, 1);
  } finally { await context.close(); }
});

test('browser discovery executes a generated redirect and preserves terminal parameters', async () => {
  const context = await browser.newContext();
  const target = `${root}/portal?terminal=fixture&ap=abc`;
  await context.route('**/*', route => {
    if (new URL(route.request().url()).hostname === 'www.baidu.com') {
      return route.fulfill({ contentType: 'text/html',
        body: `<script>const target='${root}'+'/portal?terminal=fixture&ap=abc';location.href=target</script>` });
    }
    return route.fulfill({ contentType: 'text/html', body: formHtml() });
  });
  try {
    const page = await context.newPage();
    const source = await openPortal(page, null, ['http://www.baidu.com/']);
    assert.equal(source, 'BROWSER_REDIRECT');
    assert.equal(page.url(), target);
  } finally { await context.close(); }
});

test('retries captcha rejection and stops on account rejection', async () => {
  let online = false, submissions = 0;
  const { context, page } = await fixture(formHtml({ captcha: true }), data => {
    submissions++;
    if (submissions === 1) return { message: '验证码错误' };
    online = data.captcha === '1234';
    return { message: '登录成功' };
  });
  let solves = 0;
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => online,
      captchaSolver: async () => (++solves === 1 ? '9999' : '1234'), resultWait: 20 });
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH');
    assert.equal(submissions, 2);
  } finally { await context.close(); }

  let rejectedSubmissions = 0;
  const rejected = await fixture(formHtml(), () => {
    rejectedSubmissions++;
    return { message: '账号或密码错误' };
  });
  try {
    const result = await submitLogin(rejected.page, account, { checkInternet: async () => false, resultWait: 20, resultTimeout: 150 });
    assert.equal(result.Code, 'LOGIN_REJECTED');
    assert.equal(rejectedSubmissions, 1);
  } finally { await rejected.context.close(); }
});

test('a success message without Internet access is a failure', async () => {
  const { context, page } = await fixture(formHtml(), () => ({ message: '登录成功' }));
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => false, resultWait: 20, resultTimeout: 150 });
    assert.equal(result.Code, 'LOGIN_SUBMITTED_OFFLINE');
  } finally { await context.close(); }
});

test('waits for asynchronous initialization before filling credentials and accepting protocols', async () => {
  let online = false;
  const context = await browser.newContext();
  const html = formHtml().replace('<script>', `<script>
    const agreement = document.querySelector('#agreement');
    const agreementLabel = document.querySelector('label[for=agreement]');
    agreement.remove(); agreementLabel.remove();
    fetch('/initial-state').then(() => {
      document.querySelector('#nameInput').value = '';
      document.querySelector('form').append(agreement, agreementLabel);
    });
  </script><script>`);
  await context.route('**/*', async route => {
    const request = route.request();
    if (new URL(request.url()).pathname === '/initial-state') {
      await new Promise(resolve => setTimeout(resolve, 900));
      return route.fulfill({ body: 'ready' });
    }
    if (request.method() === 'POST') {
      const data = JSON.parse(request.postData());
      assert.equal(data.username, account.username);
      assert.equal(data.agreement, true);
      online = true;
      return route.fulfill({ contentType: 'application/json', body: '{"message":"登录成功"}' });
    }
    return route.fulfill({ contentType: 'text/html', body: html });
  });
  try {
    const page = await context.newPage();
    await page.goto(`${root}/pc/center`);
    const result = await submitLogin(page, account, { checkInternet: async () => online, resultWait: 20 });
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH');
    assert.equal(result.Submitted, true);
  } finally { await context.close(); }
});

test('waits for delayed network authorization after a successful login request', async () => {
  let online = false;
  const { context, page } = await fixture(formHtml(), () => {
    setTimeout(() => { online = true; }, 300);
    return { message: '登录成功' };
  });
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => online,
      resultWait: 20, resultTimeout: 1000 });
    assert.equal(result.Code, 'ONLINE_AFTER_AUTH');
  } finally { await context.close(); }
});

test('an ineffective click is not reported as a submitted login', async () => {
  const { context, page } = await fixture(formHtml().replace('id="submitBtn" type="submit"',
    'id="submitBtn" type="button"'), () => { throw new Error('No login should be submitted'); });
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => false,
      resultWait: 20, resultTimeout: 100 });
    assert.equal(result.Code, 'LOGIN_NOT_SUBMITTED');
    assert.equal(result.Submitted, false);
  } finally { await context.close(); }
});

test('refuses to fill a form that submits to another host', async () => {
  let submitted = false;
  const { context, page } = await fixture(formHtml({ action: 'https://evil.test/login' }), () => {
    submitted = true;
    return {};
  });
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => false });
    assert.equal(result.Code, 'UNTRUSTED_FORM_ACTION');
    assert.equal(submitted, false);
  } finally { await context.close(); }
});

test('already connected skips form submission', async () => {
  const page = await browser.newPage();
  try {
    const result = await submitLogin(page, account, { checkInternet: async () => true });
    assert.equal(result.Code, 'ONLINE');
    assert.equal(result.Submitted, false);
  } finally { await page.close(); }
});

test('message classification and direct environment', () => {
  assert.equal(classifyMessage('portal认证失败，失败原因：不在认证时段内!'), 'AUTH_TIME_RESTRICTED');
  assert.equal(classifyServerReply({ code: 200, data: {
    message: 'portal认证失败，失败原因：不在认证时段内!',
  } }), 'AUTH_TIME_RESTRICTED');
  assert.equal(classifyServerReply({ message: '消息', captchaErrorMessage: '验证码错误' }), null);
  assert.equal(classifyMessage('验证码错误'), 'CAPTCHA_REJECTED');
  assert.equal(classifyMessage('用户名不存在'), 'LOGIN_REJECTED');
  assert.equal(classifyMessage('在线终端数量达到上限'), 'DEVICE_LIMIT');
  assert.equal(Object.keys(directEnvironment()).some(key => /^(https?_proxy|all_proxy|no_proxy)$/i.test(key)), false);
});

test('a nested authentication time restriction after CAS navigation stops without another login', async () => {
  let submissions = 0;
  const context = await browser.newContext();
  const html = formHtml().replace("document.querySelector('#feedback').textContent=data.message;",
    "location.href='/portal/entry/pc/finish';");
  await context.route('**/*', async route => {
    const request = route.request();
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/eportal/network/userOnline') {
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({
        code: 200, data: { message: 'portal认证失败，失败原因：不在认证时段内!' },
      }) });
    }
    if (pathname === '/portal/assets/tmp/i18n/zh-CN.json') {
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({
        message: '消息', captchaErrorMessage: '验证码错误',
      }) });
    }
    if (request.method() === 'POST') {
      submissions++;
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({
        message: '登录成功',
      }) });
    }
    if (pathname === '/portal/entry/pc/finish') {
      return route.fulfill({ contentType: 'text/html', body:
        '<button>重试</button><script>fetch("/eportal/network/userOnline",{method:"POST"})' +
        '.then(r=>r.json()).then(()=>fetch("/portal/assets/tmp/i18n/zh-CN.json"));</script>' });
    }
    return route.fulfill({ contentType: 'text/html', body: html });
  });
  try {
    const page = await context.newPage();
    await page.goto(root + '/cas-sso/login');
    const result = await submitLogin(page, account, { checkInternet: async () => false,
      resultWait: 20, resultTimeout: 5000, formTimeout: 100 });
    assert.equal(result.Code, 'AUTH_TIME_RESTRICTED');
    assert.equal(result.Submitted, true);
    assert.equal(submissions, 1);
  } finally { await context.close(); }
});

test('OCR model runs locally on a rendered image', { timeout: 60000 }, async () => {
  const page = await browser.newPage();
  try {
    await page.setContent('<div id="sample" style="width:120px;height:40px;background:white;color:black;font:28px Arial;letter-spacing:3px;line-height:40px">1234</div>');
    const answer = await solveCaptcha(await page.locator('#sample').screenshot());
    assert.equal(answer, '1234');
  } finally { await page.close(); }
});
