// Only structural evidence is retained: no URL query or matrix values.
export function describeEntry(value) {
  try {
    const u=new URL(value),[path,...matrix]=u.pathname.split(';');
    const fields=[...u.searchParams,...matrix.map(v=>{const i=v.indexOf('=');return [i<0?v:v.slice(0,i),i<0?'':v.slice(i+1)];})];
    return {Origin:u.origin,Path:path,HasUrlCredential:!!(u.username||u.password),Fields:fields.map(([Name,v])=>({Name,Present:!!v&&!/^(undefined|null)$/i.test(v)}))};
  }catch{return {InvalidUrl:true};}
}
export function checkBrowserEntry(rule,evidence) {
  if(!rule.browser.entryPathPatterns)return null;
  const trusted=evidence.filter(e=>!e.InvalidUrl&&!e.HasUrlCredential&&rule.trustedOrigins.includes(e.Origin));
  if(!trusted.some(e=>rule.browser.entryPathPatterns.some(p=>new RegExp(p).test(e.Path))))return 'PORTAL_VERSION_UNVERIFIED';
  if(rule.browser.requireGatewayParameters&&!trusted.some(e=>e.Fields?.some(f=>f.Present&&/^(sessionId|flowSessionId|flowParams|wlanparameter)$/i.test(f.Name))))return 'PORTAL_CONTEXT_MISSING';
  return null;
}
