$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$schedulerFixture=Join-Path $root 'artifacts\scheduler-fixture'
$data=Join-Path $schedulerFixture 'data'
$null=New-Item -ItemType Directory -Path (Join-Path $schedulerFixture 'scripts') -Force
$null=New-Item -ItemType Directory -Path $data -Force
$settings=@{Adapter='xtu';School='湘潭大学';Ssid='XTU-FREE-2';Interface='WLAN';Portal='https://zz.xtu.edu.cn/pc/center';Username='fixture-student';Mode='custom';Times=@('07:01');Start='07:01';End='23:00';IntervalMinutes=120}
$settings.Mode='custom';$settings.Times=@(0..59 | ForEach-Object {'23:{0:00}' -f $_})
$settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $root 'CampusLuma.Core.dll') -Destination $schedulerFixture -Force
Copy-Item -LiteralPath (Join-Path $root 'adapters') -Destination $schedulerFixture -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'scripts\schedule.ps1') -Destination (Join-Path $schedulerFixture 'scripts') -Force
# Even if a minute boundary occurs during this test, its task can only exit.
# It never points at the real network worker or sends fixture credentials.
Set-Content -LiteralPath (Join-Path $schedulerFixture 'scripts\run-hidden.vbs') -Value 'WScript.Quit 0' -Encoding ASCII
$scheduleScript=Join-Path $schedulerFixture 'scripts\schedule.ps1'
$prefix='CampusLuma Test-'+[guid]::NewGuid().ToString('N')
$scheduler=New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$folder=$scheduler.GetFolder('\')
$oldTaskXml=$null
try { $oldTaskXml=$folder.GetTask('CampusLuma Reconnect 01').Xml } catch {}
try {
    & $scheduleScript -Action Apply -DataDirectory $data -TaskPrefix $prefix
    if($LASTEXITCODE -ne 0) { throw 'Schedule registration failed.' }
    $tasks=@($folder.GetTasks(0) | Where-Object Name -Like ($prefix+' *'))
    if($tasks.Count -ne 2) { throw '60 times must produce two task batches.' }
    $triggerCount=0
    foreach($task in $tasks) {
        if(-not $task.Enabled -or $task.Definition.Principal.LogonType -ne 3) { throw 'Task identity or enable state invalid.' }
        if($task.Definition.Settings.StartWhenAvailable -or $task.Definition.Settings.RestartCount -ne 0) { throw 'Unexpected catch-up/restart.' }
        $triggerCount+=$task.Definition.Triggers.Count
        if($task.Definition.Triggers.Count -gt 48) { throw 'Too many triggers per task.' }
        foreach($trigger in $task.Definition.Triggers) { if($trigger.Type -ne 2 -or $trigger.Repetition.Interval) { throw 'Unexpected recurring trigger.' } }
    }
    if($triggerCount -ne 60) { throw 'Incorrect total trigger count.' }
    & $scheduleScript -Action Inspect -DataDirectory $data -TaskPrefix $prefix
    & $scheduleScript -Action Disable -DataDirectory $data -TaskPrefix $prefix
    if(@($folder.GetTasks(0) | Where-Object { $_.Name -like ($prefix+' *') -and $_.Enabled }).Count -ne 0) { throw 'Pause did not disable every batch.' }
    # Re-applying fewer times must replace old batches, not accumulate tasks.
    $settings=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $settings.Times=@('23:59')
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8
    & $scheduleScript -Action Apply -DataDirectory $data -TaskPrefix $prefix
    if(@($folder.GetTasks(0) | Where-Object Name -Like ($prefix+' *')).Count -ne 1) { throw 'Obsolete task batch not removed.' }
    $settings|Add-Member -NotePropertyName CatchUpOnLogon -NotePropertyValue $true -Force
    $settings|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8
    & $scheduleScript -Action Apply -DataDirectory $data -TaskPrefix $prefix
    if($LASTEXITCODE -ne 0){throw 'Logon recovery registration failed.'}
    $catchUp=$folder.GetTask($prefix+' CatchUp')
    $trigger=$catchUp.Definition.Triggers.Item(1)
    $triggerSid=if($trigger.UserId -match '^S-1-'){$trigger.UserId}else{(New-Object Security.Principal.NTAccount($trigger.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value}
    if(-not $catchUp.Enabled -or $trigger.Type -ne 9 -or $trigger.Delay -ne 'PT30S' -or
        $triggerSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
        $catchUp.Definition.Actions.Item(1).Arguments -notlike '* catch-up'){throw 'Logon task is not bound to the current user and guarded worker.'}
    $inspected=(& $scheduleScript -Action Inspect -DataDirectory $data -TaskPrefix $prefix)|ConvertFrom-Json
    if(-not $inspected.CatchUpEnabled -or ($inspected.Times -join ',') -ne '23:59'){throw 'Logon trigger leaked into daily time list.'}
    $dailyBefore=$folder.GetTask($prefix+' 01')
    $dailyLastRun=$dailyBefore.LastRunTime
    $dailyExit=$dailyBefore.LastTaskResult
    $null=$catchUp.Run($null)
    $deadline=(Get-Date).AddSeconds(5)
    do{Start-Sleep -Milliseconds 100;$catchUp=$folder.GetTask($prefix+' CatchUp')}while(($catchUp.State -eq 4 -or $catchUp.LastRunTime.Year -lt 2010) -and (Get-Date) -lt $deadline)
    if($catchUp.State -eq 4 -or $catchUp.LastRunTime.Year -lt 2010){throw 'Isolated logon action did not finish.'}
    $inspected=(& $scheduleScript -Action Inspect -DataDirectory $data -TaskPrefix $prefix)|ConvertFrom-Json
    if([datetime]$inspected.LastRun -ne $dailyLastRun -or $inspected.LastExitCode -ne $dailyExit){throw 'No-op recovery concealed the daily task result.'}
    & $scheduleScript -Action Disable -DataDirectory $data -TaskPrefix $prefix
    if($folder.GetTask($prefix+' CatchUp').Enabled -or $folder.GetTask($prefix+' 01').Enabled){throw 'Pause did not disable both daily and logon tasks.'}
    $settings.CatchUpOnLogon=$false
    $settings|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $data 'settings.json') -Encoding UTF8
    & $scheduleScript -Action Apply -DataDirectory $data -TaskPrefix $prefix
    if($LASTEXITCODE -ne 0 -or @($folder.GetTasks(0)|Where-Object Name -Like ($prefix+' *')).Count -ne 1){throw 'Turning recovery off left a logon task.'}
    if($oldTaskXml -and $folder.GetTask('CampusLuma Reconnect 01').Xml -ne $oldTaskXml) { throw 'Original task changed.' }
    @{Code='SCHEDULER_REGISTER_PAUSE_REPLACE_VERIFIED';TotalTriggersVerified=60;TaskBatchesVerified=2;LogonCatchUpRegistrationVerified=$true;DailyTaskResultPreserved=$true;OriginalTaskUnchanged=$true} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'artifacts\scheduler-result.json') -Encoding UTF8
    Write-Output 'PASS Windows registration, 60 triggers, optional logon recovery, pause, replacement and production task isolation.'
} finally {
    foreach($task in @($folder.GetTasks(0) | Where-Object Name -Like ($prefix+' *'))) { $folder.DeleteTask($task.Name,0) }
}
