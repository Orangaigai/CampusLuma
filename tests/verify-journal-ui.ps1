$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1 for .NET Framework desktop verification.'}
$projectPath=Split-Path $PSScriptRoot -Parent
$output=Join-Path $projectPath 'artifacts\research-20261023'
$state=Join-Path $output ('ui-state-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $state -Force
Add-Type -Path (Join-Path $projectPath 'CampusLuma.Core.dll')
$settings=[CampusLuma.SchoolRegistry]::Defaults()
$settings.Username='fixture-preview'
[CampusLuma.Store]::Atomic((Join-Path $state 'settings.json'),[CampusLuma.Store]::Json.Serialize($settings))
$records=@(
    @{Time=(Get-Date).AddDays(-2).ToString('o');Code='ALREADY_ONLINE';Success=$true;AuthenticationAttempted=$false;DurationMs=1900;RunId='28b616138eaa41939904b6a390255b00'},
    @{Time=(Get-Date).AddDays(-1).ToString('o');Code='BROWSER_START_FAILED';Success=$false;AuthenticationAttempted=$false;DurationMs=43400;ErrorCode='EDGE_PROCESS_CLOSED';ErrorStage='CREATE_CONTEXT';StartupAttempts=2;RunId='28b616138eaa41939904b6a390255b01'},
    @{Time=(Get-Date).ToString('o');Code='ONLINE_AFTER_AUTH';Success=$true;AuthenticationAttempted=$true;DurationMs=8930;RunId='28b616138eaa41939904b6a390255b02'})
foreach($record in $records){if(-not [CampusLuma.RunJournal]::Record($state,($record|ConvertTo-Json -Compress))){throw 'Preview history not saved.'}}
foreach($view in @('main','history')){
    $arguments=@('--ui-test','--data-directory',('"'+$state+'"'),'--output',('"'+(Join-Path $output ($view+'.png'))+'"'))
    if($view -eq 'history'){$arguments+='--history-preview'}
    $process=Start-Process -FilePath (Join-Path $projectPath 'CampusLuma.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if(-not $process.WaitForExit(15000) -or $process.ExitCode -ne 0){throw ('WPF verification failed: '+$view)}
    Write-Output ('PASS native WPF '+$view)
}
$report=[CampusLuma.RunJournal]::Feedback($state,$null,(Get-Date))
$json=[CampusLuma.Store]::Json.Serialize($report)
if($json.Contains('fixture-preview') -or $json.Contains($state)){throw 'Feedback contains private settings.'}
[CampusLuma.Store]::Atomic((Join-Path $output 'feedback-fixture.json'),$json)
$framework=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$testExe=Join-Path $projectPath 'JournalUiTests.exe'
$references=@(('/reference:'+(Join-Path $projectPath 'CampusLuma.exe')),('/reference:'+(Join-Path $projectPath 'CampusLuma.Core.dll')),'/reference:System.Web.Extensions.dll',('/reference:'+(Join-Path $framework 'WPF\PresentationFramework.dll')),('/reference:'+(Join-Path $framework 'WPF\PresentationCore.dll')),('/reference:'+(Join-Path $framework 'WPF\WindowsBase.dll')),'/reference:System.Xaml.dll')
& (Join-Path $framework 'csc.exe') /nologo /target:exe /codepage:65001 ('/out:'+$testExe) @references (Join-Path $PSScriptRoot 'JournalUiTests.cs')
if($LASTEXITCODE -ne 0){throw 'Native watcher test compilation failed.'}
& $testExe (Join-Path $state 'watcher')
if($LASTEXITCODE -ne 0){throw 'Atomic result watcher did not update WPF.'}
$result=@{Code='RUN_JOURNAL_UI_VERIFIED';Passed=$true;Views=@('main','history');FeedbackFileGenerated=$true;NativeWatcherCases=2;NativeOptionPersistenceCases=2}
$result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $output 'ui-verification.json') -Encoding UTF8
$result|ConvertTo-Json -Compress
