param([string]$PackageDirectory='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $PackageDirectory){$PackageDirectory=(Get-Content -LiteralPath (Join-Path $root 'artifacts\snnu-trial-package.json') -Raw|ConvertFrom-Json).Directory}
$manifest=Get-Content -LiteralPath (Join-Path $PackageDirectory 'build-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($file in $manifest.Files){if((Get-FileHash -LiteralPath (Join-Path $PackageDirectory $file.File)).Hash -cne $file.Sha256){throw ('Package hash mismatch: '+$file.File)}}
$settings=Get-Content -LiteralPath (Join-Path $PackageDirectory 'data\settings.json') -Raw|ConvertFrom-Json
if($settings.Username -ne '' -or $null -ne $settings.Service -or (Test-Path -LiteralPath (Join-Path $PackageDirectory 'data\credential.json'))){throw 'Trial contains configured credentials or a default carrier.'}
Add-Type -Path (Join-Path $PackageDirectory 'CampusLuma.Core.dll')
if(-not [CampusLuma.Store]::SnnuTrial -or [CampusLuma.Store]::TaskPrefix -cne 'CampusLuma Trial-snnu'){throw 'Trial is not isolated from the developer or stable tasks.'}
Write-Output 'PASS trial manifest, empty credentials, no assumed carrier and isolated namespace.'
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldPath=$env:PATH
$fixture=Join-Path $root ('artifacts\trial-check-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $fixture 'engine'),(Join-Path $fixture 'runtime'),(Join-Path $fixture 'data') -Force
Copy-Item -LiteralPath (Join-Path $PackageDirectory 'runtime\node.exe') -Destination (Join-Path $fixture 'runtime')
Copy-Item -LiteralPath (Join-Path $PackageDirectory 'engine\campus-auth-provider.ps1') -Destination (Join-Path $fixture 'engine')
@'
let text='';for await(const b of process.stdin)text+=b;
const p=JSON.parse(text.replace(/^\uFEFF/,''));
if(p.username!=='fixture-user'||p.password!=='fixture-password'||p.service!=='unicom')process.exit(2);
console.log(JSON.stringify({Code:'ONLINE_AFTER_AUTH',Submitted:true}));
'@|Set-Content -LiteralPath (Join-Path $fixture 'engine\auth-provider.mjs') -Encoding UTF8
try {
    $env:PATH=''
    $raw=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PackageDirectory 'scripts\run-once.ps1') -DataDirectory (Join-Path $PackageDirectory 'data') -CheckOnly)
    if($LASTEXITCODE -ne 0){throw 'Bundled-runtime environment check failed without PATH.'}
    $check=($raw -join "`n")|ConvertFrom-Json
    if(-not $check.Success -or $check.BrowserRequired){throw 'SNNU trial unnecessarily requires a browser.'}
    Write-Output 'PASS trial environment check with an empty PATH and no browser requirement.'
    $authUrl=([Uri](Join-Path $PackageDirectory 'engine\auth-provider.mjs')).AbsoluteUri.Replace("'",'%27')
    $rulesUrl=([Uri](Join-Path $PackageDirectory 'engine\school-rules.mjs')).AbsoluteUri.Replace("'",'%27')
    $formUrl=([Uri](Join-Path $PackageDirectory 'engine\snnu-auth.mjs')).AbsoluteUri.Replace("'",'%27')
    $moduleCheck=@'
import assert from 'node:assert/strict';
const {loadSchoolRule}=await import('__RULES__');
const {authenticateSchool}=await import('__AUTH__');
const {encodePortalForm}=await import('__FORM__');
assert.equal(encodePortalForm([['fixture','中文']]).toString(),'fixture=%D6%D0%CE%C4');
assert.equal(new TextDecoder('gb2312').decode(Uint8Array.from([0xd6,0xd0])),'中');
const result=await authenticateSchool(await loadSchoolRule('snnu'),{schoolId:'snnu',username:'fixture-user',password:'fixture-password',service:'unicom'},{probeInternet:async()=>true});
assert.equal(result.Code,'ONLINE');assert.equal(result.Submitted,false);
const preferred='__PREFERRED__',calls=[];let checks=0;
const fresh=await authenticateSchool(await loadSchoolRule('snnu'),{schoolId:'snnu',username:'fixture-user',password:'fixture-password',service:'unicom',portalUrl:preferred},{
 probeInternet:async()=>checks++>0,
 request:async(url,options)=>{calls.push({url,method:options.method,cookie:options.cookie});
  return options.method==='POST'?{status:200,headers:{},body:'<input type="hidden" id="account" value="fixture-user@unicom"><p>当前登录账号</p>'}:
   {status:200,headers:{'set-cookie':['JSESSIONID=fixture-fresh; Path=/snnuportal/']},body:'<form method="POST" action="/snnuportal/login"><input name="sourceurl" type="hidden" value="fixture-hidden"><input name="account"><input name="password" type="password"><input name="yys" type="radio" value="unicom"></form>'};}
});
assert.equal(fresh.Code,'ONLINE_AFTER_AUTH');assert.equal(fresh.Submitted,true);
const u=new URL(preferred);assert.equal(calls[0].url,u.origin+(u.pathname==='/'?'/':'/snnuportal/login.jsp'));
const posts=calls.filter(c=>c.method==='POST');assert.equal(posts.length,1);assert.equal(posts[0].cookie,'JSESSIONID=fixture-fresh');
'@
    $moduleCheck=$moduleCheck.Replace('__RULES__',$rulesUrl).Replace('__AUTH__',$authUrl).Replace('__FORM__',$formUrl).Replace('__PREFERRED__',$settings.Portal.Replace("'",'%27'))
    & (Join-Path $PackageDirectory 'runtime\node.exe') --input-type=module -e $moduleCheck
    if($LASTEXITCODE -ne 0){throw 'Bundled authentication modules or GB2312 codec are incomplete.'}
    Write-Output 'PASS actual bundled authentication modules and GB2312 codec load without global dependencies.'
    Write-Output 'PASS configured preferred entry, fresh session and one authentication POST in the bundled engine with mocked responses.'
    $credential=New-Object Management.Automation.PSCredential('fixture-user',(ConvertTo-SecureString 'fixture-password' -AsPlainText -Force))
    $reply=& (Join-Path $fixture 'engine\campus-auth-provider.ps1') -Credential $credential -SchoolId snnu -Service unicom -DataDirectory (Join-Path $fixture 'data')
    if($reply.Code -cne 'ONLINE_AFTER_AUTH' -or -not $reply.Submitted){throw 'Provider did not use its bundled Node runtime.'}
    Write-Output 'PASS provider launches bundled Node with no installed runtime on PATH.'
    $fake=[CampusLuma.SchoolRegistry]::Defaults('snnu');$fake.Username='fixture-user';$fake.Service='unicom'
    [CampusLuma.Store]::Json.Serialize($fake)|Set-Content -LiteralPath (Join-Path $fixture 'data\settings.json') -Encoding UTF8
    $raw=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PackageDirectory 'scripts\schedule.ps1') -Action Preview -DataDirectory (Join-Path $fixture 'data'))
    if($LASTEXITCODE -ne 0 -or (($raw -join "`n")|ConvertFrom-Json).Code -cne 'SCHEDULE_PREVIEW'){throw 'Trial schedule namespace did not pass validation.'}
    Write-Output 'PASS trial schedule preview uses its own namespace without registering a task.'
}finally{$env:PATH=$oldPath}
$preview=Start-Process -FilePath (Join-Path $PackageDirectory 'CampusLuma.exe') -ArgumentList @('--render-preview','--data-directory',('"'+(Join-Path $PackageDirectory 'data')+'"'),'--output',('"'+(Join-Path $root 'artifacts\snnu-trial-window.png')+'"')) -WindowStyle Hidden -PassThru
if(-not $preview.WaitForExit(15000) -or $preview.ExitCode -ne 0){throw 'Unconfigured trial window did not render.'}
Write-Output 'PASS unconfigured portable trial window renders with the SNNU form.'
@{Passed=$true;Cases=7;Package=$PackageDirectory;PreferredPortal=$settings.Portal;BundledRuntimeVerified=$true;NamespaceIsolated=$true;TaskRegistered=$false;RealCampusVerified=$false;RealCredentialsUsed=$false;PortalResponsesMocked=$true}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'artifacts\snnu-trial-check-result.json') -Encoding UTF8
