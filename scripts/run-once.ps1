param([string]$DataDirectory = '', [switch]$CheckOnly, [switch]$CatchUp,
    [ValidateSet('Manual','Scheduled','LogonCatchUp')][string]$Origin='Manual')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$clock = [Diagnostics.Stopwatch]::StartNew()
if($CatchUp){$Origin='LogonCatchUp'}
$result = @{ Time = (Get-Date).ToString('o'); RunId = [guid]::NewGuid().ToString('N'); Origin=$Origin; Code = 'NOT_STARTED'; Success = $false }
$exitCode = 1
$executionMutex=$null
$ownsExecution=$false
$publishResult=$true
try {
    Add-Type -Path (Join-Path $projectRoot 'CampusLuma.Core.dll')
    if(-not $DataDirectory) { $DataDirectory=[CampusLuma.Store]::UserRoot() }
    if ($CheckOnly) {
        $bundledNode=Join-Path $projectRoot 'runtime\node.exe'
        $node=if(Test-Path -LiteralPath $bundledNode){$bundledNode}else{Get-Command node.exe -ErrorAction SilentlyContinue}
        $edge = @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')) |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        $result.NodeReady = [bool]$node
        $result.EdgeReady = [bool]$edge
        $checkSchool='xtu'
        $checkSettings=Join-Path $DataDirectory 'settings.json'
        if(Test-Path -LiteralPath $checkSettings){$checkSchool=(Get-Content -LiteralPath $checkSettings -Raw -Encoding UTF8|ConvertFrom-Json).Adapter}
        $checkRule=[CampusLuma.SchoolRegistry]::Load($checkSchool)
        $result.BrowserRequired=$checkRule.kind -eq 'browser'
        $dependency=if($result.BrowserRequired){'playwright-core'}else{'iconv-lite'}
        $result.DependenciesReady = Test-Path -LiteralPath (Join-Path $projectRoot ('engine\node_modules\'+$dependency+'\package.json'))
        $result.Code = 'ENVIRONMENT_CHECKED'
        $result.Success = $result.NodeReady -and (-not $result.BrowserRequired -or $result.EdgeReady) -and $result.DependenciesReady
        if ($result.Success) { $exitCode = 0 }
    } else {
        $settings = [CampusLuma.Store]::Json.Deserialize((Get-Content -LiteralPath (Join-Path $DataDirectory 'settings.json') -Raw -Encoding UTF8),[CampusLuma.Settings])
        $adapter = [CampusLuma.SchoolRegistry]::Load($settings.Adapter)
        $result.SchoolId=$adapter.id
        $result.RuleVersion=$adapter.schemaVersion
        [CampusLuma.Schedule]::Validate($settings)
        # Saved task actions and Store.UserRoot already provide the pinned data
        # directory. Avoid requiring another native file-handle query here.
        $DataDirectory=[IO.Path]::GetFullPath($DataDirectory)
        $executionMutex=New-Object Threading.Mutex($false,([CampusLuma.ScheduleRecovery]::LockName($DataDirectory)))
        try {$ownsExecution=$executionMutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$ownsExecution=$true}
        if(-not $ownsExecution){$result.Code='RUN_SKIPPED';$exitCode=0;$publishResult=$false;exit 0}
        if($CatchUp){
            $decision=[CampusLuma.ScheduleRecovery]::ReadDecision($DataDirectory,$settings,(Get-Date))
            if(-not $decision.Allowed){
                $result.Code=$decision.Code
                if($decision.Code -eq 'CATCHUP_STATE_UNAVAILABLE'){$exitCode=1}else{$exitCode=0;$publishResult=$false}
                exit $exitCode
            }
            $result.ScheduledSlot=$decision.Slot
        }
        try {
            [CampusLuma.ScheduleRecovery]::MarkAttempt($DataDirectory,$settings,(Get-Date))
        } catch {
            if($CatchUp){$result.Code='CATCHUP_STATE_UNAVAILABLE';$exitCode=1;exit 1}
            # Normal scheduled/manual connections do not depend on this optional feature.
        }
        @{ schoolId = $adapter.id; targetSsid = [string]$settings.Ssid; interfaceName = [string]$settings.Interface; portal = [string]$settings.Portal } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DataDirectory 'campus-settings.json') -Encoding UTF8
        $env:CAMPUSLUMA_STATE_DIR = $DataDirectory
        $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $output = @(& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $projectRoot $adapter.entry) -DataDirectory $DataDirectory -StructuredResult)
        $exitCode = $LASTEXITCODE
        $reply = ($output -join "`n") | ConvertFrom-Json
        if ($null -eq $reply -or $reply.Code -notmatch '^[A-Z_]+$' -or $reply.Success -isnot [bool]) {
            throw 'INVALID_ENGINE_RESULT'
        }
        $result.Code = [string]$reply.Code
        $result.Success = ($exitCode -eq 0 -and $reply.Success -and $reply.Code -in @('ALREADY_ONLINE','ONLINE_AFTER_AUTH'))
        $result.AuthenticationAttempted = [bool]$reply.AuthenticationAttempted
        $result.AuthenticationCode = [string]$reply.AuthenticationCode
        foreach($field in @('ErrorType','ErrorStage','ErrorCode','StartupAttempts','WifiErrorCode')) {
            if($null -ne $reply.$field) { $result[$field]=$reply.$field }
        }
    }
} catch {
    $exitCode = 1
    $result.Code = if ($_.Exception.Message -match '^(UNSUPPORTED_ADAPTER|INVALID_PORTAL|INVALID_WIFI_SETTINGS)$') { $_.Exception.Message } else { 'SETTINGS_OR_RUNTIME_ERROR' }
    $result.ErrorType = $_.Exception.GetType().Name
} finally {
    if (-not $CheckOnly) {
        $null = New-Item -ItemType Directory -Path $DataDirectory -Force
        $result.ExitCode = $exitCode
        $result.CompletedAt = (Get-Date).ToString('o')
        $result.DurationMs = $clock.ElapsedMilliseconds
        try {
            $result.HistorySaved = [CampusLuma.RunJournal]::Record($DataDirectory,($result | ConvertTo-Json -Depth 4 -Compress),$publishResult)
        } catch {
            # History must never turn a completed authentication into a retry.
            $result.HistorySaved = $false
            if($publishResult){try { [CampusLuma.Store]::Atomic((Join-Path $DataDirectory 'last-run.json'),($result | ConvertTo-Json -Depth 4 -Compress)) } catch {}}
        }
    }
    if($ownsExecution){$executionMutex.ReleaseMutex()}
    if($null -ne $executionMutex){$executionMutex.Dispose()}
    $result | ConvertTo-Json -Depth 4 -Compress | Write-Output
}
exit $exitCode
