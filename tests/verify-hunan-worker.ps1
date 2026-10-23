$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$cases=New-Object 'Collections.Generic.List[string]'
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($id in @('hnust','hunnu')) {
    $fixture=Join-Path $root ('artifacts\'+$id+'-worker-'+[guid]::NewGuid().ToString('N'));$data=Join-Path $fixture 'data'
    foreach($directory in @('engine','scripts','adapters','data')){$null=New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force}
    Copy-Item -LiteralPath (Join-Path $root 'CampusLuma.Core.dll') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $root 'scripts\run-once.ps1') -Destination (Join-Path $fixture 'scripts')
    Copy-Item -LiteralPath (Join-Path $root 'engine\campus-auth.ps1') -Destination (Join-Path $fixture 'engine')
    $provider=Get-Content -LiteralPath (Join-Path $root 'engine\campus-auth-provider.ps1') -Raw -Encoding UTF8
    $nic=@'
function Get-NetAdapter { [pscustomobject]@{Name='WLAN';HardwareInterface=$true;Status='Up';ifIndex=42;MacAddress='02-11-22-33-44-55'} }
function Get-NetIPAddress { [pscustomobject]@{AddressState='Preferred';IPAddress='10.24.3.45'} }
'@
    $provider=$provider.Replace('$request = @{',$nic+"`n"+'$request = @{');$provider|Set-Content -LiteralPath (Join-Path $fixture 'engine\campus-auth-provider.ps1') -Encoding UTF8
    $rule=Get-Content -LiteralPath (Join-Path $root ('adapters\'+$id+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json;$rule.enabled=$true
    $rule|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $fixture ('adapters\'+$id+'.json')) -Encoding UTF8
    $mock=@'
function global:netsh {
    if(($args -join ' ') -like 'wlan show interfaces*'){'    Name : WLAN';'    SSID : __SSID__'}
    else{throw 'Fixture forbids native network mutation.'}
    $global:LASTEXITCODE=0
}
function global:curl.exe {
    if(Test-Path -LiteralPath (Join-Path $DataDirectory 'online.json')){$global:LASTEXITCODE=0;'Microsoft Connect Test'}else{$global:LASTEXITCODE=7}
}
'@
    $engine=Get-Content -LiteralPath (Join-Path $root 'engine\campus-network-reconnect.ps1') -Raw -Encoding UTF8
    $engine=$engine.Replace('Local\XTUCampusNetworkReconnect',('Local\HunanFixture'+[guid]::NewGuid().ToString('N')))
    $first=$engine.IndexOf("`n");$engine=$engine.Substring(0,$first+1)+$mock.Replace('__SSID__',$rule.defaultSsid)+"`n"+$engine.Substring($first+1)
    $engine|Set-Content -LiteralPath (Join-Path $fixture 'engine\campus-network-reconnect.ps1') -Encoding UTF8
    $stub=@'
import fs from 'node:fs';
import {createDecipheriv} from 'node:crypto';
import {runProviderCli} from '__PROVIDER__';
const state=process.env.CAMPUSLUMA_STATE_DIR;
const rule=JSON.parse(fs.readFileSync(new URL('../adapters/__ID__.json',import.meta.url),'utf8').replace(/^\uFEFF/,''));
const mode=fs.readFileSync(state+'/mode.txt','utf8').trim();let online=false;
await runProviderCli({loadRule:async()=>rule,sleep:async()=>{},maxVerificationChecks:1,probeInternet:async()=>online,
 request:async(raw,options)=>{
  const url=new URL(raw);
  if(url.pathname.endsWith('/loadConfig'))return{status:200,headers:{},body:'dr1001({"data":{"rcn":"worker-rcn"}});'};
  if(url.pathname==='/eportal/portal/login'){
   let p;if(rule.id==='hnust')p=Object.fromEntries(url.searchParams);else{const d=createDecipheriv('aes-128-ecb',Buffer.from(rule.protocol.aesKey),null);p=JSON.parse(Buffer.concat([d.update(Buffer.from(url.searchParams.get('params'),'base64')),d.final()]).toString('utf8'));}
   if(p.user_password!=='中文+&pw'||p.wlan_user_ip!=='10.24.3.45'||p.wlan_user_mac!=='021122334455'||String(p.terminal_type)!=='1')throw Error('Fixture provider payload mismatch');
   fs.writeFileSync(state+'/submitted.json',JSON.stringify({AccountCorrect:p.user_account===(rule.id==='hnust'?',0,fixture-student@telecom':',2,fixture-student'),NetworkCorrect:true}));
   online=mode==='success';if(online)fs.writeFileSync(state+'/online.json','{}');
   return{status:200,headers:{},body:(rule.id==='hnust'?'dr1003':'dr1006')+'('+JSON.stringify(online?{result:1}:{result:0,msg:'userid error2'})+');'};
  }
  return{status:200,headers:{},body:rule.id==='hnust'?"<script>var url='/eportal/portal/login';</script>":"<script>var loadConfig='';var rcn='';var AES='5c1d5ad4dea0e8dd';</script>"};
 }});
'@
    $stub=$stub.Replace('__ID__',$id).Replace('__PROVIDER__',([Uri](Join-Path $root 'engine\auth-provider.mjs')).AbsoluteUri)
    [IO.File]::WriteAllText((Join-Path $fixture 'engine\auth-provider.mjs'),$stub,(New-Object Text.UTF8Encoding($false)))
    # Separate process prevents the first fixture's loaded assembly from binding the second school's registry.
    $save=@'
param($Directory,$School)
Add-Type -Path (Join-Path $Directory 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=Join-Path $Directory 'data'
$s=[CampusLuma.SchoolRegistry]::Defaults($School);$s.Username='fixture-student';$s.Service=if($School -eq 'hnust'){'telecom'}else{'2'}
[CampusLuma.Store]::Save($s,'中文+&pw')
'@
    $save|Set-Content -LiteralPath (Join-Path $fixture 'save.ps1') -Encoding UTF8
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'save.ps1') $fixture $id
    if($LASTEXITCODE -ne 0){throw 'Fixture credential save failed.'}
    foreach($mode in @('success','reject','paused')) {
        foreach($name in @('online.json','submitted.json')){$path=Join-Path $data $name;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
        $mode|Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Encoding ASCII
        $null=& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts\run-once.ps1') -DataDirectory $data
        $actual=Get-Content -LiteralPath (Join-Path $data 'last-run.json') -Raw|ConvertFrom-Json
        $expected=if($mode -eq 'success'){'ONLINE_AFTER_AUTH'}elseif($mode -eq 'reject'){'LOGIN_REJECTED'}else{'LOGIN_BLOCKED_AFTER_REJECTION'}
        if($actual.Code -cne $expected){throw ($id+' '+$mode+': '+$actual.Code)}
        if($mode -ne 'paused'){$sent=Get-Content -LiteralPath (Join-Path $data 'submitted.json') -Raw|ConvertFrom-Json;if(-not $sent.AccountCorrect -or -not $sent.NetworkCorrect){throw 'Worker account/service/NIC mismatch.'}}
        elseif(Test-Path -LiteralPath (Join-Path $data 'submitted.json')){throw 'Rejected password was resubmitted.'}
        $case=$id+'-'+$mode;$cases.Add($case);Write-Output ('PASS Hunan worker: '+$case)
    }
}
@{Passed=$true;Cases=$cases.ToArray();RealNetworkModified=$false;RealCredentialsUsed=$false;ProviderReal=$true;PortalResponsesMocked=$true}|ConvertTo-Json -Depth 5|
    Set-Content -LiteralPath (Join-Path $root 'artifacts\hunan-worker-result.json') -Encoding UTF8
