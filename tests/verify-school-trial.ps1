param([Parameter(Mandatory)][ValidateSet('hnust','hunnu')][string]$SchoolId)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pack=(Get-Content -LiteralPath (Join-Path $root ('artifacts\'+$SchoolId+'-trial-package.json')) -Raw|ConvertFrom-Json).Directory
$manifest=Get-Content -LiteralPath (Join-Path $pack 'build-manifest.json') -Raw|ConvertFrom-Json
foreach($file in $manifest.Files){if((Get-FileHash -LiteralPath (Join-Path $pack $file.File)).Hash -cne $file.Sha256){throw ('Hash mismatch: '+$file.File)}}
Add-Type -Path (Join-Path $pack 'CampusLuma.Core.dll')
if([CampusLuma.Store]::TaskPrefix -cne ('CampusLuma Trial-'+$SchoolId)){throw 'Trial task namespace mismatch.'}
$settings=Get-Content -LiteralPath (Join-Path $pack 'data\settings.json') -Raw|ConvertFrom-Json
if($settings.Username -or $null -ne $settings.Service -or (Test-Path -LiteralPath (Join-Path $pack 'data\credential.json'))){throw 'Trial has configured credentials.'}
Write-Output ('PASS '+$SchoolId+' manifest, no credentials and independent task namespace.')
$fixture=Join-Path $root ('artifacts\'+$SchoolId+'-trial-check-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $fixture -Force
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldPath=$env:PATH
try {
    $env:PATH=''
    $raw=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $pack 'scripts\run-once.ps1') -DataDirectory (Join-Path $pack 'data') -CheckOnly)
    $check=($raw -join "`n")|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or -not $check.Success -or $check.BrowserRequired){throw 'Bundled trial environment check failed.'}
    $url=([Uri](Join-Path $pack 'engine\auth-provider.mjs')).AbsoluteUri
    $ruleUrl=([Uri](Join-Path $pack 'engine\school-rules.mjs')).AbsoluteUri
    $service=if($SchoolId -eq 'hnust'){'telecom'}else{'0'}
    $code="const {authenticateSchool}=await import('$url');const {loadSchoolRule}=await import('$ruleUrl');const r=await authenticateSchool(await loadSchoolRule('$SchoolId'),{schoolId:'$SchoolId',username:'fixture',password:'fixture',service:'$service'},{probeInternet:async()=>true});if(r.Code!=='ONLINE'||r.Submitted)process.exit(2);"
    & (Join-Path $pack 'runtime\node.exe') --input-type=module -e $code
    if($LASTEXITCODE -ne 0){throw 'Actual bundled modules did not load.'}
    Write-Output ('PASS '+$SchoolId+' bundled runtime and real modules without PATH or browser.')
    $s=[CampusLuma.SchoolRegistry]::Defaults($SchoolId);$s.Username='fixture-student';$s.Service=if($SchoolId -eq 'hnust'){'telecom'}else{'2'}
    [CampusLuma.Store]::Json.Serialize($s)|Set-Content -LiteralPath (Join-Path $fixture 'settings.json') -Encoding UTF8
    $raw=@(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $pack 'scripts\schedule.ps1') -Action Preview -DataDirectory $fixture)
    if($LASTEXITCODE -ne 0 -or (($raw -join "`n")|ConvertFrom-Json).Code -ne 'SCHEDULE_PREVIEW'){throw 'Trial schedule preview failed.'}
    Write-Output ('PASS '+$SchoolId+' schedule preview without task registration.')
}finally{$env:PATH=$oldPath}
$preview=Start-Process -FilePath (Join-Path $pack 'CampusLuma.exe') -ArgumentList @('--render-preview','--data-directory',('"'+(Join-Path $pack 'data')+'"'),'--output',('"'+(Join-Path $root ('artifacts\'+$SchoolId+'-trial-window.png'))+'"')) -WindowStyle Hidden -PassThru
if(-not $preview.WaitForExit(15000) -or $preview.ExitCode -ne 0){throw 'Trial window render failed.'}
Write-Output ('PASS '+$SchoolId+' unconfigured minimal window rendering.')
@{Passed=$true;SchoolId=$SchoolId;Package=$pack;Cases=4;RealCampusVerified=$false;TaskRegistered=$false}|ConvertTo-Json|
    Set-Content -LiteralPath (Join-Path $root ('artifacts\'+$SchoolId+'-trial-check-result.json')) -Encoding UTF8
