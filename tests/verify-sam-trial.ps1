$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pack=(Get-Content -LiteralPath (Join-Path $root 'artifacts\sam-trial-package.json') -Raw|ConvertFrom-Json).Directory
$manifest=Get-Content -LiteralPath (Join-Path $pack 'build-manifest.json') -Raw|ConvertFrom-Json
# Dependency bytes are checked once, directly from the final ZIP by
# verify-release-archives.ps1. Check this launch directory's app/runtime too.
foreach($file in ($manifest.Files|Where-Object {-not $_.File.StartsWith('engine\node_modules\')})){if((Get-FileHash -LiteralPath (Join-Path $pack $file.File)).Hash -cne $file.Sha256){throw ('Hash mismatch: '+$file.File)}}
Add-Type -Path (Join-Path $pack 'CampusLuma.Core.dll')
if([CampusLuma.Store]::TaskPrefix -cne 'CampusLuma Trial-sam'){throw 'SAM trial task namespace mismatch.'}
$settings=Get-Content -LiteralPath (Join-Path $pack 'data\settings.json') -Raw|ConvertFrom-Json
if($settings.Username -or $null -ne $settings.Service -or (Test-Path -LiteralPath (Join-Path $pack 'data\credential.json'))){throw 'Trial has configured credentials.'}
$ids=@('cuit','scit','ysu','uestc-telecom','qlu','dlut-panjin','mnnu-yuanshan')
if([CampusLuma.SchoolRegistry]::Available().Count -ne 7){throw 'SAM trial school count mismatch.'}
Write-Output 'PASS SAM seven-school manifest, empty credentials and isolated namespace.'
$fixture=Join-Path $root ('artifacts\sam-trial-check-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $fixture -Force
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$oldPath=$env:PATH
try {
    $env:PATH=''
    $raw=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $pack 'scripts\run-once.ps1') -DataDirectory (Join-Path $pack 'data') -CheckOnly)
    $check=($raw -join "`n")|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or -not $check.Success -or -not $check.BrowserRequired){throw 'SAM bundled environment check failed.'}
    $url=([Uri](Join-Path $pack 'engine\auth-provider.mjs')).AbsoluteUri
    $ruleUrl=([Uri](Join-Path $pack 'engine\school-rules.mjs')).AbsoluteUri
    $browserUrl=([Uri](Join-Path $pack 'engine\browser-auth.mjs')).AbsoluteUri
    $code=@'
import assert from 'node:assert/strict';
const {authenticateSchool}=await import('__AUTH__');
const {loadSchoolRule}=await import('__RULES__');
const {createBrowserAdapter}=await import('__BROWSER__');
for(const id of ['cuit','scit','ysu','uestc-telecom','qlu','dlut-panjin','mnnu-yuanshan']){
  const rule=await loadSchoolRule(id);
  const r=await authenticateSchool(rule,{schoolId:id,username:'fixture',password:'fixture',service:rule.browser.services?.[0].value??null},{probeInternet:async()=>true});
  assert.equal(r.Code,'ONLINE');assert.equal(r.Submitted,false);
  const adapter=createBrowserAdapter(rule),browser=await adapter.launchBrowser();
  try {
    if(id==='cuit'){
      const page=await browser.newPage();
      await page.setContent('<div id="sample" style="width:120px;height:40px;background:white;color:black;font:28px Arial;letter-spacing:3px;line-height:40px">1234</div>');
      assert.equal(await adapter.solveCaptcha(await page.locator('#sample').screenshot()),'1234');
    }
  }finally{await browser.close();}
}
'@
    $code=$code.Replace('__AUTH__',$url).Replace('__RULES__',$ruleUrl).Replace('__BROWSER__',$browserUrl)
    $moduleCheck=Join-Path $fixture 'bundled-modules.mjs'
    [IO.File]::WriteAllText($moduleCheck,$code,(New-Object Text.UTF8Encoding($false)))
    & (Join-Path $pack 'runtime\node.exe') $moduleCheck
    if($LASTEXITCODE -ne 0){throw 'SAM actual modules or bundled browser dependencies did not load.'}
    Write-Output 'PASS bundled Node, seven providers, actual Edge and OCR inference with an empty PATH.'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $pack 'scripts\collect-campus.ps1') -SchoolId qlu
    if($LASTEXITCODE -ne 0){throw 'Portable collection wrapper failed.'}
    $report=Get-Content -LiteralPath (Join-Path $pack 'reports\入口-qlu.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($report.Code -cne 'NOT_TARGET_WIFI' -or $report.CredentialSubmission -or $report.Requests){throw 'Collection did not exit on a different Wi-Fi.'}
    Write-Output 'PASS real portable PowerShell -> bundled Node collection exits on another Wi-Fi without requests.'
    foreach($id in $ids){
        $s=[CampusLuma.SchoolRegistry]::Defaults($id);$s.Username='fixture-student';$services=[CampusLuma.SchoolRegistry]::Services([CampusLuma.SchoolRegistry]::Load($id));$s.Service=if($services.Length){$services[0].value}else{$null};if(-not $s.Ssid){$s.Ssid='Fixture-Campus'}
        [CampusLuma.Store]::Json.Serialize($s)|Set-Content -LiteralPath (Join-Path $fixture 'settings.json') -Encoding UTF8
        $raw=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $pack 'scripts\schedule.ps1') -Action Preview -DataDirectory $fixture)
        if($LASTEXITCODE -ne 0 -or (($raw -join "`n")|ConvertFrom-Json).Code -ne 'SCHEDULE_PREVIEW'){throw ($id+' schedule preview failed.')}
        Write-Output ('PASS '+$id+' real trial schedule preview without task registration.')
    }
}finally{$env:PATH=$oldPath}
$preview=Start-Process -FilePath (Join-Path $pack 'CampusLuma.exe') -ArgumentList @('--render-preview','--data-directory',('"'+(Join-Path $pack 'data')+'"'),'--output',('"'+(Join-Path $root 'artifacts\sam-trial-window.png')+'"')) -WindowStyle Hidden -PassThru
if(-not $preview.WaitForExit(15000) -or $preview.ExitCode -ne 0){throw 'SAM trial window render failed.'}
Write-Output 'PASS unconfigured SAM trial minimal window rendering.'
@{Passed=$true;SchoolIds=$ids;Package=$pack;RealCampusVerified=$false;TaskRegistered=$false}|ConvertTo-Json -Depth 5|
    Set-Content -LiteralPath (Join-Path $root 'artifacts\sam-trial-check-result.json') -Encoding UTF8
