const modes = { hnust: 'drcom-query', hunnu: 'drcom-aes' };
export function validateDrcomProfile(rule) {
  const p = rule.protocol;
  if (!p || modes[rule.id] !== rule.kind || p.mode !== rule.kind || p.schemaVersion !== 1) throw new Error('INVALID_DRCOM_PROFILE');
  const origins = rule.id === 'hnust'
    ? ['http://login.hnust.cn', 'http://192.168.254.226', 'http://192.168.254.226:801']
    : ['http://192.168.250.250', 'http://192.168.250.250:801'];
  if (rule.trustedOrigins.length !== origins.length || origins.some(o => !rule.trustedOrigins.includes(o)) ||
      p.apiOrigin !== origins.at(-1) || p.loginPath !== '/eportal/portal/login' || p.jsVersion !== '4.2.1') throw new Error('INVALID_DRCOM_ENDPOINT');
  if (!Array.isArray(p.roots) || !p.roots.length || p.roots.length > 3 || p.roots.some(u => { const v = new URL(u); return !origins.includes(v.origin) || v.pathname !== '/' || v.search || v.hash || v.username || v.password; })) throw new Error('INVALID_DRCOM_ROOT');
  const services = rule.id === 'hnust' ? ['', 'telecom', 'cmcc', 'unicom'] : ['0', '1', '2', '3'];
  if (!Array.isArray(p.services) || p.services.length !== services.length || services.some(v => p.services.filter(s => s.value === v && typeof s.label === 'string' && s.label).length !== 1)) throw new Error('INVALID_DRCOM_SERVICES');
  if (rule.id === 'hunnu' && (p.configPath !== '/eportal/portal/page/loadConfig' || p.aesKey !== '5c1d5ad4dea0e8dd')) throw new Error('INVALID_DRCOM_CIPHER');
  return p;
}
