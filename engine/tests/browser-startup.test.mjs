import test from 'node:test';
import assert from 'node:assert/strict';
import { prepareBrowserSession } from '../browser-startup.mjs';
import { createBrowserAdapter } from '../browser-auth.mjs';
import { loadSchoolRule } from '../school-rules.mjs';

function fixture(failureStage) {
  let closed = 0;
  const page = {};
  const context = { async newPage() { if (failureStage === 'CREATE_PAGE') throw new Error('Target closed'); return page; } };
  const browser = { async newContext(options) {
    assert.deepEqual(options, { serviceWorkers: 'block', locale: 'zh-CN' });
    if (failureStage === 'CREATE_CONTEXT') throw new Error('Target closed'); return context;
  }, async close() { closed++; } };
  return { browser, page, closed: () => closed };
}

test('a healthy browser starts once without a retry', async () => {
  const f = fixture(); let launches = 0;
  const result = await prepareBrowserSession(async () => { launches++; return f.browser; }, { delay() { throw new Error('Unexpected retry'); } });
  assert.equal(result.page, f.page); assert.equal(result.StartupAttempts, 1); assert.equal(launches, 1);
});

for (const stage of ['LAUNCH_BROWSER', 'CREATE_CONTEXT', 'CREATE_PAGE']) {
  test(`initial ${stage} failure is cleaned up and retried before navigation`, async () => {
    const failed = fixture(stage); const healthy = fixture(); let launches = 0, delays = 0;
    const result = await prepareBrowserSession(async () => {
      launches++; if (launches === 1 && stage === 'LAUNCH_BROWSER') throw new Error('Browser closed');
      return launches === 1 ? failed.browser : healthy.browser;
    }, { async delay(ms) { assert.equal(ms, 1500); delays++; } });
    assert.equal(launches, 2); assert.equal(delays, 1); assert.equal(result.StartupAttempts, 2);
    assert.equal(failed.closed(), stage === 'LAUNCH_BROWSER' ? 0 : 1);
    assert.equal(healthy.closed(), 0);
  });
}

test('permanent failure stops at two attempts and excludes raw error secrets', async () => {
  let launches = 0;
  await assert.rejects(prepareBrowserSession(async () => {
    launches++; throw new Error('spawn EPERM password=fixture-secret https://example.test/?token=fixture-token');
  }, { async delay() {} }), error => {
    assert.deepEqual(error.browserStartup, { Code: 'BROWSER_START_FAILED', Submitted: false, ErrorType: 'Error',
      ErrorStage: 'LAUNCH_BROWSER', ErrorCode: 'EDGE_ACCESS_DENIED', StartupAttempts: 2 });
    assert.doesNotMatch(JSON.stringify(error.browserStartup), /fixture-secret|fixture-token|example/);
    return true;
  });
  assert.equal(launches, 2);
});

for (const stage of ['CREATE_CONTEXT', 'CREATE_PAGE']) {
  test(`permanent ${stage} failure closes both failed browsers`, async () => {
    const f = fixture(stage); let launches = 0;
    await assert.rejects(prepareBrowserSession(async () => { launches++; return f.browser; }, { async delay() {} }),
      error => error.browserStartup.ErrorStage === stage && error.browserStartup.Submitted === false);
    assert.equal(launches, 2); assert.equal(f.closed(), 2);
  });
}

test('the authentication adapter reports startup failure without opening a login page', async () => {
  let launches = 0;
  const adapter = createBrowserAdapter(await loadSchoolRule('xtu'), {
    probeInternet: async () => false, discoverPortal: async () => null,
    browserFactory: async () => { launches++; throw new Error('Target closed before login'); },
  });
  const result = await adapter.authenticate({ username: 'fixture-student', password: 'fixture-password' });
  assert.equal(result.Code, 'BROWSER_START_FAILED'); assert.equal(result.ErrorCode, 'EDGE_PROCESS_CLOSED');
  assert.equal(result.Submitted, false); assert.equal(result.StartupAttempts, 2); assert.equal(launches, 2);
});
