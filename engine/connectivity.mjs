import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execFileAsync = promisify(execFile);
export function directEnvironment() {
  return Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(https?_proxy|all_proxy|no_proxy)$/i.test(key)));
}
export async function curlDirect(args, { timeoutMs = 7000 } = {}) {
  if (timeoutMs <= 0) return '';
  try {
    return (await execFileAsync(process.platform === 'win32' ? 'curl.exe' : 'curl', [
      '-4', '--noproxy', '*', '--connect-timeout', '3', '--max-time', String(Math.min(5, timeoutMs / 1000)), '-s', ...args
    ], { env: directEnvironment(), windowsHide: true, timeout: timeoutMs, maxBuffer: 1024 * 1024 })).stdout;
  } catch (error) { return typeof error.stdout === 'string' ? error.stdout : ''; }
}
export async function testInternet({ timeoutMs = 14000 } = {}) {
  const until = Date.now() + timeoutMs;
  const text = await curlDirect(['http://www.msftconnecttest.com/connecttest.txt'], { timeoutMs: Math.min(7000, timeoutMs) });
  if (text.trim() === 'Microsoft Connect Test') return true;
  const status = await curlDirect(['-o', process.platform === 'win32' ? 'NUL' : '/dev/null', '-w', '%{http_code}',
    'https://connectivitycheck.platform.hicloud.com/generate_204'], { timeoutMs: Math.min(7000, until - Date.now()) });
  return status.trim() === '204';
}
