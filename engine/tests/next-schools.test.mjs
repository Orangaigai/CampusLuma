import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createBrowserAdapter} from '../browser-auth.mjs';
import {authenticateSchool} from '../auth-provider.mjs';
import {loadSchoolRule,validateSchoolRule} from '../school-rules.mjs';
import {describeEntry,checkBrowserEntry} from '../browser-entry.mjs';
import {collectPortal} from '../collect-portal.mjs';
const ids=['qlu','dlut-panjin','mnnu-yuanshan'],rules={};
for(const id of ids)rules[id]=validateSchoolRule({...JSON.parse((await readFile(new URL('../../adapters/'+id+'.json',import.meta.url),'utf8')).replace(/^\uFEFF/,'')),enabled:true});
let browser;
before(async()=>{browser=await createBrowserAdapter(await loadSchoolRule('xtu')).launchBrowser();});
after(async()=>{await browser?.close();});
const credential={username:'fixture-student',password:'中文+&pw'};
function fixture(id,{legacy=false,noContext=false,offline=false,unknown=false,write=false,logout=false,lateSession=false}={}){
 const rule=rules[id],origin=rule.trustedOrigins[0],session=noContext?'undefined':'fixture-session-secret';
 const entry=lateSession?origin+'/portal/entry/pc/authenticate;flowParams=undefined':origin+(legacy?'/eportal/InterFace.do':'/portal/portal-main')+'?sessionId='+session+'&userip=10.22.99.55&usermac=02-11-22-33-44-55';
 let online=false,submissions=0,selections=0,writeHits=0;
 const form=`<form><input id="nameInput" name="username" value="private-account-value"><input id="password" type="password" value="private-password-value">
 ${id==='dlut-panjin'?'<input id="captcha" name="captcha_code"><div id="captchaImage"><canvas id="captcha-canvas" width="120" height="40"></canvas></div>':''}
 <label><input id="agreement" type="checkbox">同意用户协议</label><button type="submit">立即登录</button></form>
 <script>${id==='dlut-panjin'?`const ctx=document.getElementById('captcha-canvas').getContext('2d');ctx.fillStyle='white';ctx.fillRect(0,0,120,40);ctx.fillStyle='black';ctx.font='28px Arial';ctx.fillText('1234',8,30);`:''}
 document.querySelector('form').onsubmit=async e=>{e.preventDefault();await fetch('/fixture-login',{method:'POST',body:JSON.stringify({username:document.querySelector('[name=username]').value,password:password.value,agreement:agreement.checked,captcha:document.querySelector('[name=captcha_code]')?.value})});${id==='qlu'?`top.location.href='${origin}/portal/entry/pc/serviceSelection?sessionId=${session}';`:''}};
 ${write?`fetch('/fixture-write',{method:'POST',body:'private-password-value'}).catch(()=>{});`:''}
 ${logout?`top.location.href='${origin}/eportal/network/offline?sessionId=${session}';`:''}
 </script>`;
 const services=`<section data-service-selection><h2>请选择服务</h2><button class="service">互联网</button><button class="service">校园网</button><button id="confirm">确定</button></section>
 <script>let picked='';document.querySelectorAll('button.service').forEach(b=>b.onclick=()=>picked=b.textContent);document.getElementById('confirm').onclick=()=>fetch('/fixture-service',{method:'POST',body:picked});</script>`;
 return {entry,origin,get online(){return online;},get submissions(){return submissions;},get selections(){return selections;},get writeHits(){return writeHits;},
 route:async route=>{
  const request=route.request(),u=new URL(request.url());
  if(request.method()!=='GET'){
   if(u.pathname==='/fixture-write'){writeHits++;return route.fulfill({body:'ok'});}
   if(u.pathname==='/fixture-login'){const p=JSON.parse(request.postData());assert.equal(p.username,credential.username);assert.equal(p.password,credential.password);assert.equal(p.agreement,true);if(id==='dlut-panjin')assert.equal(p.captcha,'1234');submissions++;if(id!=='qlu')online=!offline;}
   if(u.pathname==='/fixture-service'){assert.equal(request.postData(),'互联网');selections++;online=!offline;}
   return route.fulfill({contentType:'application/json',body:'{"success":true}'});
  }
  if(u.pathname==='/eportal/network/offline'){writeHits++;return route.fulfill({body:'should never execute'});}
  if(u.hostname==='www.msftconnecttest.com'||u.hostname==='1.1.1.1'||u.hostname==='www.163.com')return route.fulfill({status:302,headers:{location:unknown?'http://10.254.1.77/portal/portal-main?sessionId='+session:entry}});
  const body=u.pathname.includes('serviceSelection')?services:legacy||u.pathname==='/cas-sso/login'?form:lateSession?`<p>初始化中</p><script>setTimeout(()=>{const f=document.createElement('iframe');f.src='${origin}/cas-sso/login?flowSessionId=${session}';document.body.append(f);},600);</script>`:`<iframe src="${u.origin}/cas-sso/login?flowSessionId=${session}"></iframe>`;
  return route.fulfill({contentType:'text/html;charset=utf-8',body});
 }};
}
async function factory(f){const b=await createBrowserAdapter(rules.qlu).launchBrowser(),make=b.newContext.bind(b);b.newContext=async options=>{const c=await make(options);await c.route('**/*',f.route);return c;};return b;}
const collectOptions=f=>({onTargetWifi:true,probeInternet:async()=>false,browserFactory:()=>factory(f),getResponse:async route=>{
 let response;await f.route({request:()=>route.request(),fulfill:r=>{response={status:r.status||200,headers:{'content-type':r.contentType||'text/plain',...r.headers},body:r.body||''};}});return response;
}});
for(const id of ids){
 test(id+': source remains disabled and cannot send credentials',async()=>{await assert.rejects(loadSchoolRule(id),/SCHOOL_NOT_ENABLED/);});
 test(id+': full provider completes its own fresh flow and verifies external connectivity',async()=>{
  const f=fixture(id),r=await authenticateSchool(rules[id],{...credential,schoolId:id,service:id==='qlu'?'internet':null},{probeInternet:async()=>f.online,discoverPortal:async()=>f.entry,browserFactory:()=>factory(f)});
  assert.equal(r.Code,'ONLINE_AFTER_AUTH');assert.equal(f.submissions,1);assert.equal(f.selections,id==='qlu'?1:0);
 });
 test(id+': old portal paths stop before password submission',async()=>{
  const f=fixture(id,{legacy:true}),r=await authenticateSchool(rules[id],{...credential,service:id==='qlu'?'internet':null},{probeInternet:async()=>false,discoverPortal:async()=>f.entry,browserFactory:()=>factory(f)});
  assert.equal(r.Code,'PORTAL_VERSION_UNVERIFIED');assert.equal(r.Submitted,false);assert.equal(f.submissions,0);
 });
 test(id+': undefined gateway parameters cannot count as a fresh terminal session',async()=>{
  const f=fixture(id,{noContext:true}),r=await authenticateSchool(rules[id],{...credential,service:id==='qlu'?'internet':null},{probeInternet:async()=>false,discoverPortal:async()=>f.entry,browserFactory:()=>factory(f)});
  assert.equal(r.Code,'PORTAL_CONTEXT_MISSING');assert.equal(r.Submitted,false);assert.equal(f.submissions,0);
 });
 test(id+': already online does not start a browser or resubmit the account',async()=>{
  let launched=false;const r=await authenticateSchool(rules[id],credential,{probeInternet:async()=>true,browserFactory:()=>{launched=true;throw Error('unexpected launch');}});
  assert.equal(r.Code,'ONLINE');assert.equal(launched,false);
 });
 test(id+': portal success while offline is never reported as connectivity restored',async()=>{
  const f=fixture(id,{offline:true}),c=await browser.newContext();await c.route('**/*',f.route);const p=await c.newPage();await p.goto(f.entry);
  try{const r=await createBrowserAdapter(rules[id]).submitLogin(p,{...credential,service:id==='qlu'?'internet':null},{checkInternet:async()=>false,captchaSolver:async()=> '1234',resultWait:20,resultTimeout:100});assert.equal(r.Code,'LOGIN_SUBMITTED_OFFLINE');assert.equal(f.submissions,1);}finally{await c.close();}
 });
}
test('QLU requires internet selection and never guesses another service',async()=>{
 let launched=false;const r=await authenticateSchool(rules.qlu,credential,{probeInternet:async()=>false,browserFactory:()=>{launched=true;}});assert.equal(r.Code,'SERVICE_REQUIRED');assert.equal(launched,false);
});
test('a SAM shell with undefined parameters waits for its late initialized CAS iframe before deciding context is missing',async()=>{
 const f=fixture('qlu',{lateSession:true});
 const r=await authenticateSchool(rules.qlu,{...credential,service:'internet'},{probeInternet:async()=>f.online,discoverPortal:async()=>f.entry,browserFactory:()=>factory(f)});
 assert.equal(r.Code,'ONLINE_AFTER_AUTH');assert.equal(f.submissions,1);assert.equal(f.selections,1);
});
test('entry evidence excludes query and matrix values; lookalike or wrong-origin evidence does not qualify',()=>{
 const e=describeEntry(rules.qlu.trustedOrigins[0]+'/portal/entry/pc/authenticate;flowParams=secret-matrix?sessionId=secret-query');
 assert.ok(!JSON.stringify(e).includes('secret'));assert.equal(checkBrowserEntry(rules.qlu,[e]),null);
 assert.equal(checkBrowserEntry(rules.qlu,[{...e,Origin:'https://swrz.qlu.edu.cn.evil.invalid'}]),'PORTAL_VERSION_UNVERIFIED');
 assert.equal(checkBrowserEntry(rules.qlu,[{...e,HasUrlCredential:true}]),'PORTAL_VERSION_UNVERIFIED');
});
test('entry rule configuration requires anchored patterns and a parameter policy tied to paths',()=>{
 const invalid=structuredClone(rules.qlu);invalid.browser.entryPathPatterns=['.*'];assert.throws(()=>validateSchoolRule(invalid),/INVALID_ENTRY_PATH_RULE/);
 delete invalid.browser.entryPathPatterns;assert.throws(()=>validateSchoolRule(invalid),/INVALID_ENTRY_PATH_RULE/);
});
test('collection on another Wi-Fi reads no page and does not probe Internet',async()=>{
 let touched=false;const r=await collectPortal(rules.qlu,{probeInternet:async()=>{touched=true;},browserFactory:()=>{touched=true;}});assert.equal(r.Code,'NOT_TARGET_WIFI');assert.equal(touched,false);
});
test('collection while online exits without logging out or opening a browser',async()=>{
 const r=await collectPortal(rules.qlu,{onTargetWifi:true,probeInternet:async()=>true,browserFactory:()=>{throw Error('unexpected browser');}});assert.equal(r.Code,'ALREADY_ONLINE');assert.equal(r.CredentialSubmission,false);
});
test('read-only collection records structural evidence, blocks POST and excludes account/session/address values',async()=>{
 const f=fixture('qlu',{write:true}),r=await collectPortal(rules.qlu,collectOptions(f));
 assert.equal(r.Code,'ENTRY_STRUCTURE_RECOGNIZED');assert.ok(r.BlockedWrites>0,JSON.stringify(r));assert.equal(f.writeHits,0);assert.equal(f.submissions,0);
 const text=JSON.stringify(r);for(const value of ['fixture-session-secret','10.22.99.55','02-11-22-33-44-55','private-account-value','private-password-value'])assert.ok(!text.includes(value));
});
test('an unregistered new campus gateway is reported and is not silently trusted for authentication',async()=>{
 const f=fixture('mnnu-yuanshan',{unknown:true}),r=await collectPortal(rules['mnnu-yuanshan'],collectOptions(f));
 assert.equal(r.Code,'UNREGISTERED_PORTAL_ENTRY');assert.equal(r.AuthenticationVerified,false);assert.equal(f.submissions,0);assert.equal(r.CredentialSubmission,false);
});
test('read-only collection blocks an automatic GET logout before it reaches the gateway',async()=>{
 const f=fixture('qlu',{logout:true}),r=await collectPortal(rules.qlu,collectOptions(f));
 assert.equal(r.Code,'NON_READ_ONLY_ACTION_BLOCKED',JSON.stringify(r));assert.equal(f.writeHits,0);assert.equal(f.submissions,0);
});
test('default collector transport handles a real loopback HTTP redirect without sending POST or logout',async()=>{
 const seen=[];let port;
 const server=createServer((req,res)=>{
  seen.push({method:req.method,path:req.url.split('?')[0]});
  if(req.url.startsWith('/probe')){res.writeHead(302,{location:'http://127.0.0.1:'+port+'/portal/portal-main?sessionId=private-session','set-cookie':'fixture_sid=private-cookie'});res.end();return;}
  res.writeHead(200,{'content-type':'text/html;charset=utf-8'});res.end('<input id="username" value="private-user"><input type="password" value="private-pass"><script>fetch("/login",{method:"POST",body:"private-pass"}).catch(()=>{});setTimeout(()=>location.href="/eportal/network/offline",40);</script>');
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));port=server.address().port;
 const rule=structuredClone(rules['dlut-panjin']);rule.trustedOrigins=['http://127.0.0.1:'+port];rule.fallbackPortal=rule.trustedOrigins[0]+'/';rule.browser.discoveryProbes=['http://localhost:'+port+'/probe'];
 try{
  const r=await collectPortal(rule,{onTargetWifi:true,probeInternet:async()=>false});
  assert.equal(r.Code,'NON_READ_ONLY_ACTION_BLOCKED',JSON.stringify(r));assert.ok(r.BlockedWrites>0);
  assert.ok(seen.some(x=>x.path==='/portal/portal-main'));assert.ok(seen.every(x=>x.method==='GET'&&x.path!=='/eportal/network/offline'));
  const text=JSON.stringify(r);for(const value of ['private-session','private-cookie','private-user','private-pass'])assert.ok(!text.includes(value));
 }finally{await new Promise(resolve=>server.close(resolve));}
});
