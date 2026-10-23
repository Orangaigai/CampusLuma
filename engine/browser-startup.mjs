import { setTimeout as pause } from 'node:timers/promises';

// Retry initialization only. No page navigation or credential submission occurs here.
export async function prepareBrowserSession(launch, { delay = pause, retryDelayMs = 1500 } = {}) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    let browser;
    let stage = 'LAUNCH_BROWSER';
    try {
      browser = await launch();
      stage = 'CREATE_CONTEXT';
      const context = await browser.newContext({ serviceWorkers: 'block', locale: 'zh-CN' });
      stage = 'CREATE_PAGE';
      const page = await context.newPage();
      return { browser, context, page, StartupAttempts: attempt };
    } catch (cause) {
      if (browser) await browser.close().catch(() => {});
      if (attempt < 2) { await delay(retryDelayMs); continue; }
      const error = new Error('Browser initialization failed.');
      error.browserStartup = describeStartupFailure(cause, stage, attempt);
      throw error;
    }
  }
}

function describeStartupFailure(error, stage, attempts) {
  const message = String(error?.message || '');
  let code = 'EDGE_STARTUP_ERROR';
  if (/executable.*(?:doesn.t exist|not found)|ENOENT|distribution.*not found/i.test(message)) code = 'EDGE_NOT_FOUND';
  else if (/EACCES|EPERM|access.*denied/i.test(message)) code = 'EDGE_ACCESS_DENIED';
  else if (/timeout|timed out/i.test(message)) code = 'EDGE_STARTUP_TIMEOUT';
  else if (/closed|crashed|exited/i.test(message)) code = 'EDGE_PROCESS_CLOSED';
  const name = /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(error?.name || '') ? error.name : 'Error';
  // Keep typed metadata only: browser errors may contain command lines or URLs.
  return { Code: 'BROWSER_START_FAILED', Submitted: false, ErrorType: name,
    ErrorStage: stage, ErrorCode: code, StartupAttempts: attempts };
}
