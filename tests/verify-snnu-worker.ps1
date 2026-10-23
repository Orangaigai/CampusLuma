$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('artifacts\snnu-worker-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $fixture 'data'
foreach($directory in @('engine','scripts','adapters','data')){$null=New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force}
Copy-Item -LiteralPath (Join-Path $root 'CampusLuma.Core.dll') -Destination $fixture
Copy-Item -LiteralPath (Join-Path $root 'scripts\run-once.ps1') -Destination (Join-Path $fixture 'scripts')
foreach($name in @('campus-auth.ps1','campus-auth-provider.ps1')){Copy-Item -LiteralPath (Join-Path $root ('engine\'+$name)) -Destination (Join-Path $fixture 'engine')}
$rule=Get-Content -LiteralPath (Join-Path $root 'adapters\snnu.json') -Raw -Encoding UTF8|ConvertFrom-Json
$rule.enabled=$true
$rule|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $fixture 'adapters\snnu.json') -Encoding UTF8
$mock=@'
function global:netsh {
    if(($args -join ' ') -like 'wlan show interfaces*'){'    Name : WLAN';'    SSID : SNNU'}
    elseif(($args -join ' ') -like 'wlan show networks*'){'SSID 1 : SNNU'}
    else{throw 'Fixture forbids native network mutation.'}
    $global:LASTEXITCODE=0
}
function global:curl.exe {
    if(Test-Path -LiteralPath (Join-Path $DataDirectory 'online.json')){$global:LASTEXITCODE=0;'Microsoft Connect Test'}else{$global:LASTEXITCODE=7}
}
'@
$engine=Get-Content -LiteralPath (Join-Path $root 'engine\campus-network-reconnect.ps1') -Raw -Encoding UTF8
$engine=$engine.Replace('Local\XTUCampusNetworkReconnect',('Local\SnnuFixture'+[guid]::NewGuid().ToString('N')))
$first=$engine.IndexOf("`n");$engine=$engine.Substring(0,$first+1)+$mock+"`n"+$engine.Substring($first+1)
$engine|Set-Content -LiteralPath (Join-Path $fixture 'engine\campus-network-reconnect.ps1') -Encoding UTF8
@'
param([string]$InterfaceName)
return 0
'@|Set-Content -LiteralPath (Join-Path $fixture 'engine\wifi-scan.ps1') -Encoding UTF8
$stub=@'
import fs from 'node:fs';
import { runProviderCli } from '__PROVIDER_URL__';
const state=process.env.CAMPUSLUMA_STATE_DIR;
let success=false,posts=0;
const rule=JSON.parse(fs.readFileSync(new URL('../adapters/snnu.json',import.meta.url),'utf8').replace(/^\uFEFF/,''));
const mode=fs.readFileSync(state+'/mode.txt','utf8').trim();
const page=`<form action="login" method="post"><input type="hidden" name="sourceurl" value="fixture">
<input name="account" type="text"><input name="password" type="password">
<input name="yys" type="radio" value=""><input name="yys" type="radio" value="unicom"><input name="yys" type="radio" value="mobile"><input name="yys" type="radio" value="telecom"></form>`;
await runProviderCli({loadRule:async()=>rule,sleep:async()=>{},maxVerificationChecks:1,
 probeInternet:async()=>success,
 request:async(url,options)=>{
  if(options.method==='POST'){
   posts++;
   const body=options.body.toString('ascii'),fields=new URLSearchParams(body);
   if(fields.get('account')!=='fixture-student'||!body.includes('password=%D6%D0%CE%C4%2B%26pw')||options.cookie!=='JSESSIONID=worker-fixture')throw Error('Fixture payload mismatch');
   const service=fields.get('yys');
   fs.writeFileSync(state+'/submitted.json',JSON.stringify({Service:service,Posts:posts,EncodingVerified:true,CookieVerified:true}));
   if(mode==='reject')return{status:200,headers:{},body:'<p>账号或密码错误</p>'};
   success=true;fs.writeFileSync(state+'/online.json','{}');
   return{status:200,headers:{},body:`<input type="hidden" id="account" value="fixture-student${service?'@'+service:''}"><p>当前登录账号</p>`};
  }
  if(url.endsWith('/'))return{status:200,headers:{},body:`<script>location.href='http://202.117.144.205:8609/snnuportal/login.jsp'</script>`};
  return{status:200,headers:{'set-cookie':['JSESSIONID=worker-fixture; Path=/snnuportal/']},body:page};
 }});
'@
$providerUrl=([Uri](Join-Path $root 'engine\auth-provider.mjs')).AbsoluteUri
$stub=$stub.Replace('__PROVIDER_URL__',$providerUrl)
[IO.File]::WriteAllText((Join-Path $fixture 'engine\auth-provider.mjs'),$stub,(New-Object Text.UTF8Encoding($false)))
Add-Type -Path (Join-Path $fixture 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=$data
$settings=[CampusLuma.SchoolRegistry]::Defaults('snnu');$settings.Username='fixture-student';$settings.Service='unicom'
[CampusLuma.Store]::Save($settings,'中文+&pw')
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cases=New-Object 'Collections.Generic.List[string]'
function Run-Case([string]$name,[string]$mode,[string]$expected,[bool]$submitted) {
    foreach($file in @('online.json','submitted.json')){$path=Join-Path $data $file;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
    $mode|Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Encoding ASCII
    $null=& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts\run-once.ps1') -DataDirectory $data
    $actual=Get-Content -LiteralPath (Join-Path $data 'last-run.json') -Raw|ConvertFrom-Json
    if($actual.Code -cne $expected -or [bool]$actual.AuthenticationAttempted -ne $submitted){throw ($name+': '+$actual.Code)}
    if((Test-Path -LiteralPath (Join-Path $data 'submitted.json')) -ne $submitted){throw ($name+': unexpected credential submission')}
    if($submitted){$body=Get-Content -LiteralPath (Join-Path $data 'submitted.json') -Raw|ConvertFrom-Json
        if(-not [object]::Equals($body.Service,$settings.Service) -or $body.Posts -ne 1 -or -not $body.EncodingVerified -or -not $body.CookieVerified){throw ($name+': incorrect service/encoding/cookie')}}
    $cases.Add($name);Write-Output ('PASS SNNU worker: '+$name)
}
Run-Case 'DPAPI-to-real-provider-and-HTTP-engine' 'success' 'ONLINE_AFTER_AUTH' $true
$settings.Service='';[CampusLuma.Store]::Save($settings,'')
Run-Case 'explicit-empty-campus-service-survives-PowerShell-and-JSON' 'success' 'ONLINE_AFTER_AUTH' $true
$settings.Service='mobile';[CampusLuma.Store]::Save($settings,'')
Run-Case 'password-rejection-submits-only-once' 'reject' 'LOGIN_REJECTED' $true
Run-Case 'same-rejected-service-is-paused' 'success' 'LOGIN_BLOCKED_AFTER_REJECTION' $false
$settings.Service='unicom';[CampusLuma.Store]::Save($settings,'')
Run-Case 'corrected-service-can-retry-with-unchanged-encrypted-password' 'success' 'ONLINE_AFTER_AUTH' $true
$missing=[CampusLuma.Store]::Json.Serialize($settings)|ConvertFrom-Json
$missing.Service=$null
$missing|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8
Run-Case 'missing-service-is-rejected-before-engine' 'success' 'SETTINGS_OR_RUNTIME_ERROR' $false
@{Passed=$true;Cases=$cases.ToArray();RealNetworkModified=$false;RealCredentialsUsed=$false;TaskRegistered=$false;ProviderAndHttpEngineReal=$true;HttpResponsesMocked=$true}|ConvertTo-Json -Depth 5|
    Set-Content -LiteralPath (Join-Path $root 'artifacts\snnu-worker-result.json') -Encoding UTF8
