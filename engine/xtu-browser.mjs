// Compatibility entry for existing XTU tests and local inspection helpers.
import { pathToFileURL } from 'node:url';
import { createBrowserAdapter, runBrowserCli } from './browser-auth.mjs';
import { loadSchoolRule } from './school-rules.mjs';
const adapter = createBrowserAdapter(await loadSchoolRule('xtu'));
export const { DEFAULT_LOGIN_URL, directEnvironment, trustedPortal, describePortalUrl, portalRedirects, testInternet, discoverPortal, launchBrowser, openPortal, findLoginForm, solveCaptcha, acceptAgreement, classifyMessage, classifyServerReply, submitLogin, inspectPage, authenticate } = adapter;
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await runBrowserCli();
