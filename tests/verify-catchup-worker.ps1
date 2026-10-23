$ErrorActionPreference='Stop'
$projectPath=Split-Path $PSScriptRoot -Parent
$template=Join-Path $projectPath 'artifacts\wrapper-fixture'
if(-not (Test-Path -LiteralPath (Join-Path $template 'engine\campus-network-reconnect.ps1'))){throw 'Run verify-wrapper.ps1 first.'}
$fixture=Join-Path $projectPath ('artifacts\catchup-worker-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $fixture 'data'
foreach($directory in @('scripts','engine','adapters','data')){$null=New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force}
Copy-Item -LiteralPath (Join-Path $projectPath 'CampusLuma.Core.dll') -Destination $fixture
foreach($file in @('run-once.ps1','run-hidden.vbs')){Copy-Item -LiteralPath (Join-Path $projectPath ('scripts\'+$file)) -Destination (Join-Path $fixture 'scripts')}
Copy-Item -LiteralPath (Join-Path $projectPath 'adapters\xtu.json') -Destination (Join-Path $fixture 'adapters')
foreach($file in @('campus-auth.ps1','campus-auth-provider.ps1','wifi-scan.ps1','campus-network-reconnect.ps1')){Copy-Item -LiteralPath (Join-Path $template ('engine\'+$file)) -Destination (Join-Path $fixture 'engine')}
foreach($file in @('settings.json','credential.json')){Copy-Item -LiteralPath (Join-Path $template ('data\'+$file)) -Destination $data}
$enginePath=Join-Path $fixture 'engine\campus-network-reconnect.ps1'
$engine=[IO.File]::ReadAllText($enginePath)
if(-not $engine.Contains('Fixture forbids any native network mutation.')){throw 'Fixture has no network mutation barrier.'}
$engine=[regex]::Replace($engine,'Local\\CampusLumaWrapper[0-9a-f]+',('Local\CampusLumaCatchUp'+[guid]::NewGuid().ToString('N')))
$line=$engine.IndexOf("`n")
$spy=@'
Add-Content -LiteralPath (Join-Path $DataDirectory 'engine-entry.txt') -Value 'mock-engine-entered'
'@
[IO.File]::WriteAllText($enginePath,$engine.Substring(0,$line+1)+$spy+"`n"+$engine.Substring($line+1),(New-Object Text.UTF8Encoding($true)))
Add-Type -Path (Join-Path $fixture 'CampusLuma.Core.dll')
$settings=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw -Encoding UTF8|ConvertFrom-Json
$settings.Times=@((Get-Date).AddMinutes(-15).ToString('HH:mm'))
$settings|Add-Member -NotePropertyName CatchUpOnLogon -NotePropertyValue $true -Force
$receipt=Join-Path $data 'schedule-receipt.json'
$cases=@()
function Save-Settings {$settings|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8}
function Calls {if(Test-Path -LiteralPath (Join-Path $data 'engine-entry.txt')){return @(Get-Content -LiteralPath (Join-Path $data 'engine-entry.txt')).Count};return 0}
function Clear-Receipt {if(Test-Path -LiteralPath $receipt){Remove-Item -LiteralPath $receipt -Force}}
function Invoke-Case([string]$Name,[string]$Expected,[bool]$CatchUp=$true,[string]$Origin='Manual'){
    $parameters=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture 'scripts\run-once.ps1'),'-DataDirectory',$data,'-Origin',$Origin)
    if($CatchUp){$parameters+='-CatchUp'}
    $reply=(& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" @parameters)|ConvertFrom-Json
    $actualExit=$LASTEXITCODE
    $expectedExit=if($Expected -in @('CATCHUP_STATE_UNAVAILABLE','AUTH_TIME_RESTRICTED')){1}else{0}
    if($reply.Code -ne $Expected -or $actualExit -ne $expectedExit){throw ('Wrong catch-up outcome: '+$Name+' '+$reply.Code+' exit '+$actualExit)}
    if($CatchUp -and $reply.Origin -ne 'LogonCatchUp'){throw 'Origin not recorded.'}
    $script:cases+=@{Case=$Name;Code=$reply.Code;EngineCalls=(Calls)}
    Write-Output ('PASS guarded worker: '+$Name)
}
Save-Settings
Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Value 'auth' -Encoding ASCII
$settings.CatchUpOnLogon=$false;Save-Settings
Invoke-Case 'disabled feature does not inspect network' 'CATCHUP_DISABLED'
if((Calls) -ne 0){throw 'Disabled recovery entered engine.'}
$settings.CatchUpOnLogon=$true;Save-Settings
Invoke-Case 'late login performs one mock authentication' 'ONLINE_AFTER_AUTH'
if((Calls) -ne 1){throw 'Expected exactly one engine invocation.'}
$last=Get-Content -LiteralPath (Join-Path $data 'last-run.json') -Raw -Encoding UTF8
Invoke-Case 'next login does not repeat the same slot' 'CATCHUP_ALREADY_HANDLED'
if((Calls) -ne 1 -or (Get-Content -LiteralPath (Join-Path $data 'last-run.json') -Raw -Encoding UTF8) -ne $last){throw 'Skipped recovery changed active result or entered engine.'}

# Verify the real hidden VBS argument path, without logging out Windows.
$historyCount=(Get-Content -LiteralPath (Join-Path $data 'run-history.json') -Raw -Encoding UTF8|ConvertFrom-Json).Count
$process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList @('//B','//NoLogo',('"'+(Join-Path $fixture 'scripts\run-hidden.vbs')+'"'),('"'+$data+'"'),'catch-up') -WindowStyle Hidden -PassThru
if(-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0){throw 'Hidden catch-up worker did not exit.'}
$history=Get-Content -LiteralPath (Join-Path $data 'run-history.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($history.Count -ne $historyCount+1 -or $history[-1].Code -ne 'CATCHUP_ALREADY_HANDLED' -or (Calls) -ne 1){throw 'VBS did not invoke the guarded catch-up path.'}
$cases+=@{Case='hidden VBS forwards catch-up argument';Code='CATCHUP_ALREADY_HANDLED';EngineCalls=(Calls)}
Write-Output 'PASS hidden VBS catch-up argument and invocation history'

Clear-Receipt
Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Value 'failure' -Encoding ASCII
Invoke-Case 'school rejection is recorded as an attempt' 'AUTH_TIME_RESTRICTED'
$callsAfterFailure=Calls
Invoke-Case 'reboot does not repeat rejected login' 'CATCHUP_ALREADY_HANDLED'
if((Calls) -ne $callsAfterFailure){throw 'School rejection was retried.'}

Clear-Receipt
Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Value 'home' -Encoding ASCII
Invoke-Case 'at home exits without authentication' 'CAMPUS_NOT_VISIBLE'
$homeCalls=Calls
Invoke-Case 'another login at home remains quiet' 'CATCHUP_ALREADY_HANDLED'
if((Calls) -ne $homeCalls){throw 'Repeated network scan at home.'}

$settings.Times=@((Get-Date).AddMinutes(5).ToString('HH:mm'));Save-Settings
Invoke-Case 'outside the catch-up window does nothing' 'CATCHUP_OUTSIDE_WINDOW'
if((Calls) -ne $homeCalls){throw 'Out-of-window recovery entered engine.'}
$settings.Times=@((Get-Date).AddMinutes(-15).ToString('HH:mm'));Save-Settings
Set-Content -LiteralPath $receipt -Value '{broken' -Encoding ASCII
Invoke-Case 'corrupt receipt stops before network access' 'CATCHUP_STATE_UNAVAILABLE'
if((Calls) -ne $homeCalls){throw 'Corrupt receipt entered engine.'}

Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Value 'online' -Encoding ASCII
Invoke-Case 'ordinary scheduled run works with corrupt receipt' 'ALREADY_ONLINE' $false 'Scheduled'
$scheduledCalls=Calls
Invoke-Case 'scheduled execution prevents duplicate logon recovery' 'CATCHUP_ALREADY_HANDLED'
if((Calls) -ne $scheduledCalls){throw 'Scheduled run followed by extra catch-up.'}

$mutex=New-Object Threading.Mutex($false,([CampusLuma.ScheduleRecovery]::LockName($data)))
$owned=$mutex.WaitOne(0)
try{if(-not $owned){throw 'Test execution lock unavailable.'};Invoke-Case 'overlap cannot enter network engine' 'RUN_SKIPPED'}finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
if((Calls) -ne $scheduledCalls){throw 'Concurrent execution entered engine.'}
$report=[CampusLuma.RunJournal]::Feedback($data,$null,(Get-Date))
$feedback=[CampusLuma.Store]::Json.Serialize($report)
if($feedback -match 'fixture-student|fixture-password-not-real|PlanToken'){throw 'Private execution receipt leaked into feedback.'}
@{Code='CATCHUP_WORKER_VERIFIED';Passed=$true;RealNetworkModified=$false;RealCredentialsUsed=$false;LogonSessionRestarted=$false;Cases=$cases}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $projectPath 'artifacts\catchup-worker-result.json') -Encoding UTF8
Write-Output ('PASS all guarded worker cases: '+$cases.Count)
