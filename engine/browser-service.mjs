function compact(text) { return String(text || '').replace(/\s/g, ''); }
export async function browserServiceVisible(page, rule) {
  if (!rule.browser.services) return false;
  for (const frame of page.frames()) {
    try { const u = new URL(frame.url()); if (u.username || u.password || !rule.trustedOrigins.includes(u.origin)) continue; } catch { continue; }
    try {
    const containers = frame.locator(rule.browser.serviceSelection.containerSelectors.join(','));
    for (let i = 0, n = Math.min(await containers.count(), 12); i < n; i++) {
      if (await containers.nth(i).isVisible().catch(() => false) && new RegExp(rule.browser.serviceSelection.promptPattern, 'i').test(await containers.nth(i).innerText().catch(() => ''))) return true;
    }
    } catch(error) { if(!frame.isDetached()&&!/Execution context was destroyed|Frame was detached|navigation/i.test(error.message))throw error; }
  }
  return false;
}
export async function chooseBrowserService(page, rule, service) {
  const services = rule.browser.services;
  if (!services) return { Code: 'NO_SERVICE_SELECTION' };
  const selected = services.find(s => s.value === service);
  if (!selected) return { Code: 'SERVICE_REQUIRED' };
  const config = rule.browser.serviceSelection, aliases = new Set(selected.aliases.map(compact));
  for (const frame of page.frames()) {
    try { const u = new URL(frame.url()); if (u.username || u.password || !rule.trustedOrigins.includes(u.origin)) continue; } catch { continue; }
    try {
    const containers = frame.locator(config.containerSelectors.join(','));
    for (let index = 0, count = Math.min(await containers.count(), 12); index < count; index++) {
      const container = containers.nth(index);
      if (!await container.isVisible().catch(() => false)) continue;
      const text = await container.innerText().catch(() => '');
      if (!new RegExp(config.promptPattern, 'i').test(text)) continue;
      const candidates = container.locator(config.optionSelectors.join(','));
      const matches = []; let visible = 0;
      for (let i = 0, n = Math.min(await candidates.count(), 32); i < n; i++) {
        const option = candidates.nth(i);
        if (!await option.isVisible().catch(() => false)) continue;
        visible++;
        const labels = await option.evaluate(element => [element.getAttribute('aria-label'), element.textContent,
          ...(element.labels ? Array.from(element.labels).map(l => l.textContent) : [])]);
        if (labels.some(label => aliases.has(compact(label)))) {
          const containsMatchingOption = await option.evaluate((element, args) => Array.from(element.querySelectorAll(args.selector)).some(child =>
            args.aliases.includes(String(child.getAttribute('aria-label') || child.textContent || '').replace(/\s/g, ''))),
          { selector: config.optionSelectors.join(','), aliases: [...aliases] });
          if (!containsMatchingOption) matches.push(option);
        }
      }
      if (!visible) return { Code: 'SERVICE_SELECTION_PENDING' };
      if (matches.length !== 1) return { Code: matches.length ? 'SERVICE_SELECTION_AMBIGUOUS' : 'SERVICE_UNAVAILABLE' };
      const confirm = container.locator(config.confirmSelectors.join(','));
      const buttons = [];
      for (let i = 0, n = Math.min(await confirm.count(), 12); i < n; i++) if (await confirm.nth(i).isVisible().catch(() => false)) buttons.push(confirm.nth(i));
      if (buttons.length !== 1) return { Code: buttons.length ? 'SERVICE_SELECTION_AMBIGUOUS' : 'SERVICE_SELECTION_PENDING' };
      // Do not choose a service when its confirmation action is still unavailable.
      await matches[0].click({ timeout: 3000 });
      const until = Date.now() + 2000;
      while (!await buttons[0].isEnabled().catch(() => false) && Date.now() < until) await page.waitForTimeout(100);
      if (!await buttons[0].isEnabled().catch(() => false)) return { Code: 'SERVICE_SELECTION_PENDING' };
      await buttons[0].click({ timeout: 3000 });
      return { Code: 'SERVICE_SELECTED', Service: service };
    }
    } catch(error) { if(!frame.isDetached()&&!/Execution context was destroyed|Frame was detached|navigation/i.test(error.message))throw error; }
  }
  return { Code: 'NO_SERVICE_SELECTION' };
}
