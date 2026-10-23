$ErrorActionPreference='Stop'
$projectPath=Split-Path $PSScriptRoot -Parent
$template=Join-Path $projectPath 'artifacts\wrapper-fixture'
$mockEngine=Join-Path $template 'engine\campus-network-reconnect.ps1'
if(-not (Test-Path -LiteralPath $mockEngine) -or -not (Select-String -LiteralPath $mockEngine -SimpleMatch 'Fixture forbids any native network mutation.')) {
    throw 'Run verify-wrapper.ps1 first; clock test requires an isolated engine.'
}
$runId=[guid]::NewGuid().ToString('N')
$fixtureRoot=Join-Path $projectPath ('artifacts\clock-trigger-fixture\'+$runId)
$null=New-Item -ItemType Directory -Path $fixtureRoot -Force
Copy-Item -LiteralPath (Join-Path $projectPath 'CampusLuma.Core.dll') -Destination $fixtureRoot -Force
Copy-Item -LiteralPath (Join-Path $projectPath 'adapters') -Destination $fixtureRoot -Recurse -Force
Add-Type -Path (Join-Path $fixtureRoot 'CampusLuma.Core.dll')
$service=New-Object -ComObject 'Schedule.Service'
$service.Connect()
$folder=$service.GetFolder('\')
$production=@{}
foreach($task in @($folder.GetTasks(0) | Where-Object { $_.Name -like 'CampusLuma Reconnect *' })) { $production[$task.Name]=$task.Xml }
$now=Get-Date
$triggerAt=$now.Date.AddHours($now.Hour).AddMinutes($now.Minute+2)
$cases=@()
try {
    foreach($mode in @('custom','interval')) {
        $fixturePath=Join-Path $fixtureRoot $mode
        foreach($directory in @('scripts','engine','adapters','data')) { $null=New-Item -ItemType Directory -Path (Join-Path $fixturePath $directory) -Force }
        Copy-Item -LiteralPath (Join-Path $projectPath 'CampusLuma.Core.dll') -Destination $fixturePath -Force
        foreach($script in @('schedule.ps1','run-once.ps1','run-hidden.vbs')) { Copy-Item -LiteralPath (Join-Path $projectPath ('scripts\'+$script)) -Destination (Join-Path $fixturePath 'scripts') -Force }
        Copy-Item -LiteralPath (Join-Path $projectPath 'adapters\xtu.json') -Destination (Join-Path $fixturePath 'adapters') -Force
        foreach($script in @('campus-network-reconnect.ps1','campus-auth.ps1','campus-auth-provider.ps1','wifi-scan.ps1')) { Copy-Item -LiteralPath (Join-Path $template ('engine\'+$script)) -Destination (Join-Path $fixturePath 'engine') -Force }
        # Isolate the mocked worker from both the production mutex and the
        # other clock test. All network commands remain mocked and mutations throw.
        $enginePath=Join-Path $fixturePath 'engine\campus-network-reconnect.ps1'
        $engine=[regex]::Replace([IO.File]::ReadAllText($enginePath),'Local\\(?:XTUCampusNetworkReconnect|CampusLumaWrapper[0-9a-f]+)',('Local\CampusLumaClock'+$runId+$mode))
        [IO.File]::WriteAllText($enginePath,$engine,(New-Object Text.UTF8Encoding($true)))
        $dataPath=Join-Path $fixturePath 'data'
        [CampusLuma.Store]::Root=$dataPath
        $settings=[CampusLuma.SchoolRegistry]::Defaults()
        $settings.Username='fixture-student'
        $settings.Mode=$mode
        $settings.Times.Clear()
        $settings.Times.Add($triggerAt.ToString('HH:mm'))
        $settings.Start=$triggerAt.ToString('HH:mm')
        $settings.End=$triggerAt.AddMinutes(5).ToString('HH:mm')
        $settings.IntervalMinutes=5
        [CampusLuma.Store]::Save($settings,'fixture-password-not-real')
        Set-Content -LiteralPath (Join-Path $dataPath 'mode.txt') -Value 'auth' -Encoding ASCII
        $prefix='CampusLuma Test-'+$runId+$mode
        $case=[pscustomobject]@{Mode=$mode;Prefix=$prefix;Data=$dataPath;ExpectedTimes=@([CampusLuma.Schedule]::Expand($settings))}
        $cases+=$case
        & (Join-Path $fixturePath 'scripts\schedule.ps1') -Action Apply -DataDirectory $dataPath -TaskPrefix $prefix
        if($LASTEXITCODE -ne 0) { throw ('Clock fixture registration failed: '+$mode) }
        $task=$folder.GetTask($prefix+' 01')
        $actualTimes=@($task.Definition.Triggers | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') } | Sort-Object)
        if(($actualTimes -join ',') -ne ($case.ExpectedTimes -join ',') -or $task.NextRunTime -ne $triggerAt) { throw 'Stored Windows trigger does not match the chosen time.' }
    }
    Write-Output ('WAIT system clock, no manual Run: '+$triggerAt.ToString('yyyy-MM-dd HH:mm:ss'))
    $deadline=$triggerAt.AddSeconds(45)
    do {
        $complete=$true
        foreach($case in $cases) {
            if(-not (Test-Path -LiteralPath (Join-Path $case.Data 'last-run.json')) -or $folder.GetTask($case.Prefix+' 01').State -eq 4) { $complete=$false }
        }
        if($complete) { break }
        Start-Sleep -Milliseconds 500
    } while((Get-Date) -lt $deadline)
    if(-not $complete) { throw 'A clock-triggered task did not finish within 45 seconds of its trigger.' }
    $results=@()
    foreach($case in $cases) {
        $task=$folder.GetTask($case.Prefix+' 01')
        $result=Get-Content -LiteralPath (Join-Path $case.Data 'last-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if(-not $result.Success -or $result.Code -ne 'ONLINE_AFTER_AUTH' -or $task.LastTaskResult -ne 0 -or
            $task.LastRunTime -lt $triggerAt -or $task.LastRunTime -gt $triggerAt.AddSeconds(30)) { throw ('Clock execution failed: '+$case.Mode) }
        $history=Get-Content -LiteralPath (Join-Path $case.Data 'run-history.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($history.Count -ne 1 -or $history[0].RunId -ne $result.RunId -or -not $result.CompletedAt -or -not $result.AuthenticationAttempted){throw ('Clock run missing its invocation history: '+$case.Mode)}
        $results+=[ordered]@{Mode=$case.Mode;RegisteredTimes=$case.ExpectedTimes;ExpectedAt=$triggerAt.ToString('s');WindowsLastRun=$task.LastRunTime.ToString('s');StartedAt=$result.Time;CompletedAt=$result.CompletedAt;ExitCode=$task.LastTaskResult;Result=$result.Code;HistoryCount=$history.Count}
        Write-Output ('PASS clock -> Windows task -> hidden VBS -> worker -> DPAPI -> mock authentication: '+$case.Mode)
    }
    foreach($name in $production.Keys) { if($folder.GetTask($name).Xml -ne $production[$name]) { throw 'Production task changed during clock verification.' } }
    @{Code='AUTOMATIC_CLOCK_TRIGGER_VERIFIED';Passed=$true;ManuallyStarted=$false;GuiRequired=$false;RealNetworkModified=$false;RealCredentialsUsed=$false;ProductionTasksUnchanged=$true;Cases=$results} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $projectPath 'artifacts\clock-trigger-result.json') -Encoding UTF8
} finally {
    foreach($case in $cases) {
        foreach($task in @($folder.GetTasks(0) | Where-Object Name -Like ($case.Prefix+' *'))) {
            try { $task.Stop(0) } catch {}
            $folder.DeleteTask($task.Name,0)
        }
    }
}
