export function validateBrowserExtensions(rule) {
  const p = rule.browser;
  if (p.requireNetworkRedirect !== undefined && typeof p.requireNetworkRedirect !== 'boolean') throw new Error('INVALID_BROWSER_CONTEXT_RULE');
  if (p.requireGatewayParameters !== undefined && typeof p.requireGatewayParameters !== 'boolean') throw new Error('INVALID_BROWSER_CONTEXT_RULE');
  if (p.entryPathPatterns !== undefined && (!Array.isArray(p.entryPathPatterns) || !p.entryPathPatterns.length || p.entryPathPatterns.length > 8 || p.entryPathPatterns.some(s => typeof s !== 'string' || !s.startsWith('^/') || s.length > 300))) throw new Error('INVALID_ENTRY_PATH_RULE');
  for (const pattern of p.entryPathPatterns || []) new RegExp(pattern);
  if (p.requireGatewayParameters && !p.entryPathPatterns) throw new Error('INVALID_ENTRY_PATH_RULE');
  if (p.accountTabTexts !== undefined && (!Array.isArray(p.accountTabTexts) || !p.accountTabTexts.length || p.accountTabTexts.length > 8 || p.accountTabTexts.some(t => typeof t !== 'string' || !t.trim() || t.length > 40))) throw new Error('INVALID_ACCOUNT_TAB');
  const services = p.services;
  if (services === undefined) return;
  if (!Array.isArray(services) || !services.length || services.length > 8 || new Set(services.map(s => s.value)).size !== services.length) throw new Error('INVALID_BROWSER_SERVICES');
  const aliases = new Set();
  for (const s of services) {
    if (!s || typeof s.value !== 'string' || !/^[a-z][a-z0-9_-]{0,31}$/.test(s.value) || typeof s.label !== 'string' || !s.label ||
        !Array.isArray(s.aliases) || !s.aliases.length || s.aliases.length > 8) throw new Error('INVALID_BROWSER_SERVICES');
    for (const text of s.aliases) {
      if (typeof text !== 'string' || !text.trim() || text.length > 80 || aliases.has(text.replace(/\s/g, ''))) throw new Error('AMBIGUOUS_BROWSER_SERVICES');
      aliases.add(text.replace(/\s/g, ''));
    }
  }
  const choice = p.serviceSelection;
  if (!choice || typeof choice.promptPattern !== 'string' || !choice.promptPattern || choice.promptPattern.length > 300) throw new Error('INVALID_SERVICE_SELECTION');
  new RegExp(choice.promptPattern, 'i');
  for (const key of ['containerSelectors', 'optionSelectors', 'confirmSelectors']) {
    if (!Array.isArray(choice[key]) || !choice[key].length || choice[key].length > 16 || choice[key].some(v => typeof v !== 'string' || !v.trim() || v.length > 512)) throw new Error('INVALID_SERVICE_SELECTION');
  }
}
