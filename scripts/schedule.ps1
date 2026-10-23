param([ValidateSet('Apply','Disable','Inspect','Preview')][string]$Action = 'Inspect',
    [string]$DataDirectory = '', [string]$TaskPrefix = '')
$ErrorActionPreference = 'Stop'
try {
    $projectRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -Path (Join-Path $projectRoot 'CampusLuma.Core.dll')
    if(-not $DataDirectory){$DataDirectory=[CampusLuma.Store]::UserRoot()}
    if(-not $TaskPrefix){$TaskPrefix=[CampusLuma.Store]::TaskPrefix}
    if($TaskPrefix -notmatch '^CampusLuma (Reconnect|Development|Trial-(snnu|hnust|hunnu|sam)|Test-[a-zA-Z0-9]+)$') { throw 'Invalid task namespace.' }
    $DataDirectory=[CampusLuma.Store]::CanonicalRoot($DataDirectory)
    if($Action -in @('Apply','Preview')) {
        $settings = [CampusLuma.Store]::Json.Deserialize((Get-Content -LiteralPath (Join-Path $DataDirectory 'settings.json') -Raw -Encoding UTF8), [CampusLuma.Settings])
        [CampusLuma.Schedule]::Validate($settings)
        $times = @([CampusLuma.Schedule]::Expand($settings))
        if($Action -eq 'Preview') { @{Code='SCHEDULE_PREVIEW';Times=$times;CatchUpEnabled=$settings.CatchUpOnLogon;TaskCount=([int][Math]::Ceiling($times.Count/48.0)+[int]$settings.CatchUpOnLogon)} | ConvertTo-Json -Compress; exit 0 }
    }
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    $tasks = @($folder.GetTasks(0) | Where-Object { $_.Name -match ('^'+[regex]::Escape($TaskPrefix)+' (\d+|CatchUp)$') })
    if($Action -eq 'Disable') {
        foreach($task in $tasks) { $task.Enabled = $false }
        @{Code='SCHEDULE_DISABLED';Enabled=$false;TaskCount=$tasks.Count} | ConvertTo-Json -Compress; exit 0
    }
    if($Action -eq 'Inspect') {
        $enabledTasks = @($tasks | Where-Object Enabled)
        $nextRun = @($enabledTasks | ForEach-Object NextRunTime | Where-Object { $_ -gt (Get-Date) } | Sort-Object)[0]
        $actualTimes=@($enabledTasks | ForEach-Object { $_.Definition.Triggers } | Where-Object {$_.Type -eq 2} | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') } | Sort-Object -Unique)
        # A harmless logon skip must not conceal an earlier daily task failure.
        $latest=$tasks | Where-Object {$_.Name -ne ($TaskPrefix+' CatchUp')} | Sort-Object LastRunTime -Descending | Select-Object -First 1
        $running=@($enabledTasks|Where-Object {$_.State -eq 4}).Count -gt 0
        @{Code='SCHEDULE_STATUS';Enabled=($enabledTasks.Count -gt 0);CatchUpEnabled=(@($enabledTasks|Where-Object {$_.Name -eq ($TaskPrefix+' CatchUp')}).Count -gt 0);TaskCount=$tasks.Count;Times=$actualTimes;NextRun=if($nextRun){$nextRun.ToString('s')}else{$null};LastRun=if($latest){$latest.LastRunTime.ToString('s')}else{$null};LastExitCode=if($latest){$latest.LastTaskResult}else{0};State=if($running){4}elseif($latest){$latest.State}else{0}} | ConvertTo-Json -Compress; exit 0
    }
    # Register the new definitions disabled first. On any registration failure,
    # leave their predecessors intact; do not touch another app's task names.
    $definitions = @()
    $definitionNames = @()
    function New-Definition {
        $definition=$scheduler.NewTask(0)
        $definition.Principal.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $definition.Principal.LogonType=3
        $definition.Settings.Enabled=$false
        $definition.Settings.StartWhenAvailable=$false
        $definition.Settings.WakeToRun=$true
        $definition.Settings.DisallowStartIfOnBatteries=$false
        $definition.Settings.StopIfGoingOnBatteries=$false
        $definition.Settings.MultipleInstances=2
        $definition.Settings.ExecutionTimeLimit='PT3M'
        $definition.RegistrationInfo.Description='CampusLuma daily connectivity checks. Signed-in user required. No continuous polling.'
        return $definition
    }
    for($offset=0;$offset -lt $times.Count;$offset+=48) {
        $definition = New-Definition
        foreach($time in $times[$offset..([Math]::Min($offset+47,$times.Count-1))]) {
            $trigger = $definition.Triggers.Create(2)
            $boundary = (Get-Date).Date.AddMinutes([CampusLuma.Schedule]::Minute($time))
            if($boundary -le (Get-Date)) { $boundary = $boundary.AddDays(1) }
            $trigger.StartBoundary = $boundary.ToString('yyyy-MM-ddTHH:mm:ss')
            $trigger.DaysInterval = 1
        }
        $exec = $definition.Actions.Create(0)
        $exec.Path = Join-Path $env:WINDIR 'System32\wscript.exe'
        $exec.Arguments = '//B //NoLogo "{0}" "{1}"' -f (Join-Path $PSScriptRoot 'run-hidden.vbs'),$DataDirectory
        $exec.WorkingDirectory = $projectRoot
        $definitions += $definition
        $definitionNames += ('{0} {1:00}' -f $TaskPrefix,$definitions.Count)
    }
    if($settings.CatchUpOnLogon){
        $definition=New-Definition
        $trigger=$definition.Triggers.Create(9)
        $trigger.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $trigger.Delay='PT30S'
        $exec=$definition.Actions.Create(0)
        $exec.Path=Join-Path $env:WINDIR 'System32\wscript.exe'
        $exec.Arguments='//B //NoLogo "{0}" "{1}" catch-up' -f (Join-Path $PSScriptRoot 'run-hidden.vbs'),$DataDirectory
        $exec.WorkingDirectory=$projectRoot
        $definitions+=$definition
        $definitionNames+=($TaskPrefix+' CatchUp')
    }
    # Preserve existing definitions and enabled state for rollback.
    $backups = @($tasks | ForEach-Object { @{Name=$_.Name;Xml=$_.Xml;Enabled=$_.Enabled} })
    $registered = @()
    try {
        for($index=0;$index -lt $definitions.Count;$index++) {
            $name = $definitionNames[$index]
            $null = $folder.RegisterTaskDefinition($name,$definitions[$index],6,$null,$null,3)
            $registered += $name
        }
        foreach($name in $registered) { $folder.GetTask($name).Enabled = $true }
        foreach($task in $tasks) { if($task.Name -notin $registered) { $folder.DeleteTask($task.Name,0) } }
    } catch {
        foreach($name in $registered) { try { $folder.DeleteTask($name,0) } catch {} }
        foreach($backup in $backups) { $null=$folder.RegisterTask($backup.Name,$backup.Xml,6,$null,$null,3); $folder.GetTask($backup.Name).Enabled=$backup.Enabled }
        throw
    }
    @{Code='SCHEDULE_APPLIED';Enabled=$true;CatchUpEnabled=$settings.CatchUpOnLogon;Times=$times;TaskCount=$definitions.Count} | ConvertTo-Json -Compress
    exit 0
} catch { @{Code='SCHEDULE_ERROR';ErrorType=$_.Exception.GetType().Name} | ConvertTo-Json -Compress; exit 1 }
