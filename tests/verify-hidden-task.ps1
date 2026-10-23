$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root 'artifacts\wrapper-fixture'
$data=Join-Path $fixture 'data'
if(-not (Test-Path -LiteralPath (Join-Path $fixture 'engine\campus-network-reconnect.ps1'))) { throw 'Run the isolated wrapper test first.' }
if(-not (Select-String -LiteralPath (Join-Path $fixture 'engine\campus-network-reconnect.ps1') -SimpleMatch 'Fixture forbids any native network mutation.')) { throw 'Refusing non-isolated engine.' }
Copy-Item -LiteralPath (Join-Path $root 'scripts\run-hidden.vbs') -Destination (Join-Path $fixture 'scripts') -Force
Set-Content -LiteralPath (Join-Path $data 'mode.txt') -Value 'auth' -Encoding ASCII
$lastRun=Join-Path $data 'last-run.json'
if(Test-Path -LiteralPath $lastRun) { Remove-Item -LiteralPath $lastRun }
$scheduler=New-Object -ComObject 'Schedule.Service'; $scheduler.Connect(); $folder=$scheduler.GetFolder('\')
$name='CampusLuma Test-'+[guid]::NewGuid().ToString('N')+' 01'
try {
    $definition=$scheduler.NewTask(0)
    $definition.Principal.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $definition.Principal.LogonType=3
    $definition.Settings.ExecutionTimeLimit='PT1M'
    $definition.Settings.DisallowStartIfOnBatteries=$false
    $definition.Settings.StopIfGoingOnBatteries=$false
    $action=$definition.Actions.Create(0)
    $action.Path=Join-Path $env:WINDIR 'System32\wscript.exe'
    $action.Arguments='//B //NoLogo "{0}" "{1}"' -f (Join-Path $fixture 'scripts\run-hidden.vbs'),$data
    $action.WorkingDirectory=$fixture
    $null=$folder.RegisterTaskDefinition($name,$definition,6,$null,$null,3)
    $null=$folder.GetTask($name).Run($null)
    $deadline=(Get-Date).AddSeconds(30)
    do { Start-Sleep -Milliseconds 250; $task=$folder.GetTask($name) } while((($task.State -eq 4) -or -not (Test-Path -LiteralPath $lastRun)) -and (Get-Date) -lt $deadline)
    if(-not (Test-Path -LiteralPath $lastRun)) { throw 'Hidden scheduled fixture did not finish.' }
    $result=Get-Content -LiteralPath $lastRun -Raw | ConvertFrom-Json
    if($result.Code -ne 'ONLINE_AFTER_AUTH' -or $task.LastTaskResult -ne 0) { throw 'Hidden scheduled wrapper fixture failed.' }
    @{Code='HIDDEN_INTERACTIVE_TASK_CHAIN_VERIFIED';TaskExitCode=$task.LastTaskResult;FixtureResult=$result.Code;RealNetworkModified=$false} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'artifacts\hidden-task-result.json') -Encoding UTF8
    Write-Output 'PASS real Windows task -> hidden VBS -> independent worker -> DPAPI -> simulated provider.'
} finally { try { $folder.GetTask($name).Stop(0) } catch {}; try { $folder.DeleteTask($name,0) } catch {} }
