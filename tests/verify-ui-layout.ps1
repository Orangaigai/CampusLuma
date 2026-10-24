$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$framework=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpf=Join-Path $framework 'WPF'
$exe=Join-Path $project 'UiLayoutTests.exe'
$references=@(('/reference:'+(Join-Path $project 'CampusLuma.exe')),('/reference:'+(Join-Path $project 'CampusLuma.Core.dll')),'/reference:System.Web.Extensions.dll')
foreach($assembly in @('PresentationFramework.dll','PresentationCore.dll','WindowsBase.dll','UIAutomationProvider.dll','UIAutomationTypes.dll')){$references+=('/reference:'+(Join-Path $wpf $assembly))}
$references+='/reference:System.Xaml.dll'
& (Join-Path $framework 'csc.exe') /nologo /target:exe /codepage:65001 ('/out:'+$exe) @references (Join-Path $PSScriptRoot 'UiLayoutTests.cs')
if($LASTEXITCODE -ne 0){throw 'UI layout checks did not compile.'}
$output=Join-Path $project ('artifacts\ui-polish\verified-'+[guid]::NewGuid().ToString('N'))
& $exe $output
if($LASTEXITCODE -ne 0){throw 'UI layout checks failed.'}
Write-Output ('UI evidence: '+$output)
