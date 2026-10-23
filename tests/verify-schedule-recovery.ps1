$ErrorActionPreference='Stop'
$projectPath=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output=Join-Path $projectPath ('artifacts\schedule-recovery-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $output -Force
Copy-Item -LiteralPath (Join-Path $projectPath 'CampusLuma.Core.dll') -Destination $output
$exe=Join-Path $output 'ScheduleRecoveryTests.exe'
& $compiler /nologo /target:exe /codepage:65001 ('/out:'+$exe) ('/reference:'+(Join-Path $projectPath 'CampusLuma.Core.dll')) /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'ScheduleRecoveryTests.cs')
if($LASTEXITCODE -ne 0){throw 'Recovery test build failed.'}
& $exe (Join-Path $output 'state')
if($LASTEXITCODE -ne 0){throw 'Recovery boundary scenarios failed.'}
