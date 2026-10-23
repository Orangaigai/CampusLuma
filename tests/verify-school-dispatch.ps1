$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root 'artifacts\school-dispatch-fixture'
$data=Join-Path $fixture 'data'
foreach($name in @('scripts','engine','engine\node_modules\playwright-core','adapters','data')) {
    $null=New-Item -ItemType Directory -Path (Join-Path $fixture $name) -Force
}
Copy-Item -LiteralPath (Join-Path $root 'CampusLuma.Core.dll') -Destination $fixture -Force
Copy-Item -LiteralPath (Join-Path $root 'scripts\run-once.ps1') -Destination (Join-Path $fixture 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $root 'scripts\schedule.ps1') -Destination (Join-Path $fixture 'scripts') -Force
'fixture only' | Set-Content -LiteralPath (Join-Path $fixture 'development.mode') -Encoding ASCII
@{OwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;DataDirectory=$data} | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $fixture 'data-location.json') -Encoding UTF8
foreach($name in @('campus-auth.ps1','campus-auth-provider.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root ('engine\'+$name)) -Destination (Join-Path $fixture 'engine') -Force
}
Copy-Item -LiteralPath (Join-Path $root 'adapters\xtu.json') -Destination (Join-Path $fixture 'adapters') -Force
$beta=Get-Content -LiteralPath (Join-Path $root 'adapters\xtu.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beta.id='fixture-b';$beta.name='模拟乙校';$beta.defaultSsid='Fixture-B'
$beta.fallbackPortal='https://portal.beta.invalid/login'
$beta.trustedOrigins=@('https://portal.beta.invalid')
$beta.browser.selfServiceUrl='https://portal.beta.invalid/self'
$beta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixture 'adapters\fixture-b.json') -Encoding UTF8
@{schemaVersion=1;id='pending';name='未验收学校';enabled=$false} | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $fixture 'adapters\pending.json') -Encoding UTF8
'{}' | Set-Content -LiteralPath (Join-Path $fixture 'engine\node_modules\playwright-core\package.json') -Encoding ASCII
$mock=@'
Set-Content -LiteralPath (Join-Path $DataDirectory 'engine-started.txt') -Value 'fixture only'
function global:netsh {
    if(($args -join ' ') -like 'wlan show interfaces*') { '    Name : WLAN';'    SSID : Fixture-B' }
    elseif(($args -join ' ') -like 'wlan show networks*') { 'SSID 1 : Fixture-B' }
    else { throw 'Fixture forbids native network mutation.' }
    $global:LASTEXITCODE=0
}
function global:curl.exe {
    if(Test-Path -LiteralPath (Join-Path $DataDirectory 'provider-started.json')) { $global:LASTEXITCODE=0;'Microsoft Connect Test' }
    else { $global:LASTEXITCODE=7 }
}
'@
$engine=Get-Content -LiteralPath (Join-Path $root 'engine\campus-network-reconnect.ps1') -Raw -Encoding UTF8
$engine=$engine.Replace('Local\XTUCampusNetworkReconnect',('Local\CampusLumaDispatch'+[guid]::NewGuid().ToString('N')))
$firstNewline=$engine.IndexOf("`n")
$engine=$engine.Substring(0,$firstNewline+1)+$mock+"`n"+$engine.Substring($firstNewline+1)
$engine | Set-Content -LiteralPath (Join-Path $fixture 'engine\campus-network-reconnect.ps1') -Encoding UTF8
@'
param([string]$InterfaceName)
return 0
'@ | Set-Content -LiteralPath (Join-Path $fixture 'engine\wifi-scan.ps1') -Encoding UTF8
@'
import fs from 'node:fs';
import path from 'node:path';
let input='';for await(const chunk of process.stdin) input+=chunk;
const p=JSON.parse(input.replace(/^\uFEFF/,''));
if(p.schoolId!=='fixture-b'||p.portalUrl!=='https://portal.beta.invalid/login'||p.username!=='fixture-student'||p.password!=='fixture-password-not-real') process.exit(2);
fs.writeFileSync(path.join(process.env.CAMPUSLUMA_STATE_DIR,'provider-started.json'),JSON.stringify({schoolId:p.schoolId,portal:p.portalUrl,mode:p.mode}));
console.log(JSON.stringify({Code:'ONLINE_AFTER_AUTH',Submitted:true,PortalSource:'FIXTURE'}));
'@ | Set-Content -LiteralPath (Join-Path $fixture 'engine\auth-provider.mjs') -Encoding UTF8
Add-Type -Path (Join-Path $fixture 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=$data
$settings=[CampusLuma.SchoolRegistry]::Defaults('fixture-b')
$settings.Username='fixture-student'
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cases=New-Object System.Collections.Generic.List[string]
function Run-Case([string]$name,[string]$expected,[bool]$engineExpected,[bool]$providerExpected) {
    foreach($file in @('provider-started.json','engine-started.txt')) {
        $path=Join-Path $data $file
        if(Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    $null=& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts\run-once.ps1') -DataDirectory $data
    $code=$LASTEXITCODE
    $result=Get-Content -LiteralPath (Join-Path $data 'last-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($result.Code -cne $expected) { throw ($name+': wrong result '+$result.Code) }
    if($result.Success -ne $providerExpected -or ($code -eq 0) -ne $providerExpected) { throw ($name+': wrong success/exit result') }
    if((Test-Path -LiteralPath (Join-Path $data 'engine-started.txt')) -ne $engineExpected) { throw ($name+': wrong engine dispatch') }
    if((Test-Path -LiteralPath (Join-Path $data 'provider-started.json')) -ne $providerExpected) { throw ($name+': wrong provider dispatch') }
    $cases.Add($name);Write-Output ('PASS school worker dispatch: '+$name)
}
[CampusLuma.Store]::Save($settings,'fixture-password-not-real')
$preview=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts\schedule.ps1') -Action Preview)
if($LASTEXITCODE -ne 0 -or (($preview -join "`n") | ConvertFrom-Json).Code -cne 'SCHEDULE_PREVIEW') { throw 'Default scheduler did not resolve isolated development data.' }
$cases.Add('default-scheduler-uses-development-data');Write-Output 'PASS school worker dispatch: default-scheduler-uses-development-data'
Run-Case 'second-school-to-Node-stdin' 'ONLINE_AFTER_AUTH' $true $true
$result=Get-Content -LiteralPath (Join-Path $data 'last-run.json') -Raw | ConvertFrom-Json
if($result.SchoolId -cne 'fixture-b' -or -not $result.AuthenticationAttempted) { throw 'Worker lost selected school or submitted result.' }
$credential=Get-Content -LiteralPath (Join-Path $data 'credential.json') -Raw | ConvertFrom-Json
$credential.SchoolId='xtu'
$credential | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $data 'credential.json') -Encoding UTF8
Run-Case 'foreign-school-credential-stops-before-provider' 'CREDENTIAL_SCHOOL_MISMATCH' $true $false
foreach($id in @('pending','missing','../xtu')) {
    $settings.Adapter=$id
    [CampusLuma.Store]::Json.Serialize($settings) | Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8
    Run-Case ('invalid-rule-'+$id) 'SETTINGS_OR_RUNTIME_ERROR' $false $false
}
@{Passed=$true;NetworkCommandsMocked=$true;RealCredentialSubmission=$false;Cases=$cases.ToArray()} | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $root 'artifacts\school-dispatch-result.json') -Encoding UTF8
