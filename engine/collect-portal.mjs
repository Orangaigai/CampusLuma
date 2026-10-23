import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {join} from 'node:path';
import {createBrowserAdapter} from './browser-auth.mjs';
import {validateSchoolRule} from './school-rules.mjs';
import {testInternet} from './connectivity.mjs';
import {describeEntry,checkBrowserEntry} from './browser-entry.mjs';

const privateHost=h=>/^(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(h);
const mutation=/(?:^|[\/?&=._-])(logout|logoff|offline|disconnect|unbind|delete|remove|disable|terminate|kick)(?:$|[\/?&=._-])/i;
function safeEntry(raw) {
 const e=describeEntry(raw);if(e.InvalidUrl)return e;
 return {Origin:e.Origin,Path:e.Path.split('/').map(s=>s.length>60||/\d{7,}/.test(s)?'[redacted]':s).join('/'),
  Fields:e.Fields.filter(f=>/^[A-Za-z][A-Za-z0-9_.-]{0,40}$/.test(f.Name)&&!/[0-9]{7,}/.test(f.Name)),HasUrlCredential:e.HasUrlCredential};
}
export async function collectPortal(input,{onTargetWifi=false,probeInternet=()=>testInternet({timeoutMs:4000}),browserFactory,getResponse,timeoutMs=22000}={}) {
 const rule=validateSchoolRule({...input,enabled:true});
 const report={SchemaVersion:1,SchoolId:rule.id,Time:new Date().toISOString(),Mode:'read-only',CredentialRead:false,CredentialSubmission:false,Requests:0,BlockedWrites:0,BlockedActions:0,Entries:[],Forms:[]};
 if(!onTargetWifi)return {...report,Code:'NOT_TARGET_WIFI'};
 if(await probeInternet())return {...report,Code:'ALREADY_ONLINE',InternetVerified:true};
 const browser=await (browserFactory||createBrowserAdapter(rule).launchBrowser)();
 const deadline=Date.now()+Math.min(Math.max(timeoutMs,1000),30000),seen=new Set();
 try {
  const context=await browser.newContext({serviceWorkers:'block',locale:'zh-CN'}),page=await context.newPage();
  const probes=new Set(rule.browser.discoveryProbes.map(v=>new URL(v).origin)),visited=new Set(rule.trustedOrigins);
  context.on('request',request=>{
   if(!request.isNavigationRequest()||!/^https?:/.test(request.url()))return;
   const e=safeEntry(request.url());const key=JSON.stringify(e);
   if(!probes.has(e.Origin)&&!seen.has(key)&&report.Entries.length<24){seen.add(key);report.Entries.push(e);}
  });
  let redirects=0;
  await context.route('**/*',async route=>{
   const request=route.request();report.Requests++;
   if(request.method()!=='GET'){report.BlockedWrites++;return route.abort('blockedbyclient');}
   if(Date.now()>deadline||report.Requests>120)return route.abort('blockedbyclient');
   if(/^(data:|about:)/.test(request.url()))return route.fallback();
   let u;try{u=new URL(request.url());}catch{return route.abort('blockedbyclient');}
   if(!['http:','https:'].includes(u.protocol)||u.username||u.password)return route.abort('blockedbyclient');
   if(mutation.test(u.pathname+u.search)){report.BlockedActions++;return route.abort('blockedbyclient');}
   const schoolHost=rule.trustedOrigins.some(o=>{const h=new URL(o).hostname;return !privateHost(h)&&h.split('.').length>=3&&u.hostname.endsWith('.'+h.split('.').slice(-3).join('.'));});
   if(request.isNavigationRequest()&&(privateHost(u.hostname)||schoolHost)&&['','80','443','8080','801'].includes(u.port))visited.add(u.origin);
   if(!visited.has(u.origin)&&!probes.has(u.origin))return route.abort('blockedbyclient');
   try {
    // A native HTTP redirect can escape the original route handler. Read it
    // without following, then start a fresh GET navigation through our policy.
    const response=getResponse?await getResponse(route):await (async()=>{const r=await route.fetch({maxRedirects:0,timeout:Math.max(1,Math.min(5000,deadline-Date.now()))});return {status:r.status(),headers:r.headers(),body:await r.body()};})();
    if([301,302,303,307,308].includes(response.status)&&response.headers?.location){
     if(++redirects>8||!request.isNavigationRequest())return route.abort('blockedbyclient');
     const target=new URL(response.headers.location,u).href;
     const headers={'content-type':'text/html;charset=utf-8','cache-control':'no-store'};
     if(response.headers['set-cookie'])headers['set-cookie']=response.headers['set-cookie'];
     return route.fulfill({status:200,headers,body:'<script>location.replace('+JSON.stringify(target).replace(/</g,'\\u003c')+')</script>'});
    }
    return route.fulfill(response);
   }catch{return route.abort('failed').catch(()=>{});}
  });
  for(const url of rule.browser.discoveryProbes){
   if(Date.now()>deadline)break;
   try{await page.goto(url,{waitUntil:'domcontentloaded',timeout:Math.max(1,Math.min(5000,deadline-Date.now()))});}catch{}
   const settle=Math.min(deadline,Date.now()+2000);
   do {
    await page.waitForTimeout(Math.min(150,Math.max(0,settle-Date.now())));
    if(await Promise.all(page.frames().map(f=>f.locator('input[type=password]').count().catch(()=>0))).then(a=>a.some(n=>n>0)))break;
   }while(Date.now()<settle);
   if(report.Entries.length)break;
  }
  for(const frame of page.frames()){
   let u;try{u=new URL(frame.url());}catch{continue;}
   if(!visited.has(u.origin)||!/^https?:/.test(frame.url()))continue;
   const inputs=await frame.locator('input,select').evaluateAll(xs=>xs.slice(0,25).map(x=>({Type:x.tagName==='SELECT'?'select':x.type,
    Id:/^[A-Za-z_][A-Za-z0-9_-]{0,60}$/.test(x.id)?x.id:'',Name:/^[A-Za-z_][A-Za-z0-9_-]{0,60}$/.test(x.name)?x.name:'',Visible:!!(x.offsetWidth||x.offsetHeight)}))).catch(()=>[]);
   report.Forms.push({Entry:safeEntry(frame.url()),Trusted:rule.trustedOrigins.includes(u.origin),Inputs:inputs});
  }
  const trusted=report.Entries.filter(e=>rule.trustedOrigins.includes(e.Origin)&&!e.HasUrlCredential);
  report.Code=!report.Entries.length?'NO_GATEWAY_ENTRY':!trusted.length?'UNREGISTERED_PORTAL_ENTRY':checkBrowserEntry(rule,trusted)||'ENTRY_STRUCTURE_RECOGNIZED';
  if(report.Forms.some(f=>!f.Trusted)||report.Entries.some(e=>!rule.trustedOrigins.includes(e.Origin)))report.Code='UNREGISTERED_PORTAL_ENTRY';
  if(report.Code==='ENTRY_STRUCTURE_RECOGNIZED'&&!report.Forms.some(f=>f.Trusted&&f.Inputs.some(i=>i.Type==='password'&&i.Visible)))report.Code='ENTRY_PAGE_NOT_READY';
  if(report.BlockedActions)report.Code='NON_READ_ONLY_ACTION_BLOCKED';
  report.AuthenticationVerified=false;return report;
 }finally{await browser.close();}
}
export async function runCollectionCli(args=process.argv.slice(2)) {
 const id=args[0],directory=args[1];if(!/^[a-z][a-z0-9_-]{0,47}$/.test(id||'')||!directory)throw Error('INVALID_COLLECTION_ARGUMENT');
 const rule=JSON.parse((await readFile(new URL('../adapters/'+id+'.json',import.meta.url),'utf8')).replace(/^\uFEFF/,''));
 const report=await collectPortal(rule,{onTargetWifi:args[2]==='on-target'});
 await mkdir(directory,{recursive:true});await writeFile(join(directory,'入口-'+id+'.json'),JSON.stringify(report,null,2));
 console.log(JSON.stringify({Code:report.Code,CredentialSubmission:false,AuthenticationVerified:false}));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await runCollectionCli();
