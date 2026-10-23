// Publication hygiene, not a substitute for reviewing the diff and screenshots.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const files = execFileSync('git', ['ls-files', '-z', '--cached'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
if (!files.length) throw new Error('Stage the intended source files before auditing.');
const failures = [];
const forbiddenPath = /(^|\/)(node_modules|artifacts|reports|data|runtime|\.codex-remote-attachments)\/|(^|\/)(credential|settings|local-settings|data-location|last-run|run-history|schedule-receipt|campus-settings|last-auth-result)\.json$|\.(exe|dll|pdb|har|dmp|log|recovery)$|(^|\/)\.env(\.|$)/i;
const rules = [
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ['github-token', /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b/],
  ['personal-windows-path', /[A-Z]:\\Users\\(?!Public\b|Default\b)[^\\\s]+\\/i],
  ['personal-sid', /S-1-5-21-\d+-\d+-\d+-\d+/],
  ['numeric-account-literal', /(?:Username|username|account|userId)\s*[=:]\s*["']\d{6,20}["']/],
];
for (const file of files) {
  if (forbiddenPath.test(file)) failures.push({ file, rule: 'private-or-generated-path' });
  const full = resolve(root, file);
  if (!existsSync(full)) { failures.push({ file, rule: 'missing-tracked-file' }); continue; }
  if (/\.(png|jpg|jpeg|ico)$/i.test(file)) continue;
  const content = execFileSync('git', ['show', ':' + file], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  for (const [rule, pattern] of rules) if (pattern.test(content)) failures.push({ file, rule });
  if (file.endsWith('.md')) {
    const links = [...content.matchAll(/\[[^\]]*\]\(([^)]+)\)|<img\s+[^>]*src="([^"]+)"/g)];
    for (const match of links) {
      const target = (match[1] || match[2]).split('#')[0];
      if (!target || /^[a-z]+:/i.test(target)) continue;
      if (!existsSync(resolve(dirname(full), decodeURIComponent(target)))) failures.push({ file, rule: 'broken-local-link', target });
    }
  }
}
for (const required of ['README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md', 'VERSION', 'docs/images/window.png', '.github/workflows/ci.yml']) {
  if (!files.includes(required)) failures.push({ file: required, rule: 'required-file-not-tracked' });
}
if (failures.length) { console.error(JSON.stringify({ Passed: false, Failures: failures }, null, 2)); process.exitCode = 1; }
else console.log(JSON.stringify({ Passed: true, Files: files.length, Checks: 'tracked paths, secret patterns, required files and local documentation links' }));
