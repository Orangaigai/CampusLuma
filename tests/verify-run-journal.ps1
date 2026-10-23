$ErrorActionPreference='Stop'
$projectPath=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output=Join-Path $projectPath ('artifacts\journal-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$null=New-Item -ItemType Directory -Path $output -Force
$exe=Join-Path $output 'RunJournalTests.exe'
Copy-Item -LiteralPath (Join-Path $projectPath 'CampusLuma.Core.dll') -Destination $output
& $compiler /nologo /target:exe /codepage:65001 ('/out:'+$exe) ('/reference:'+(Join-Path $projectPath 'CampusLuma.Core.dll')) /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'RunJournalTests.cs')
if($LASTEXITCODE -ne 0){throw 'Journal test compilation failed.'}
& $exe (Join-Path $output 'state')
if($LASTEXITCODE -ne 0){throw 'Journal test scenarios failed.'}
$result=@{Code='RUN_JOURNAL_VERIFIED';Passed=$true;Scenarios=25;Directory=$output}
$result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
$result|ConvertTo-Json -Compress
