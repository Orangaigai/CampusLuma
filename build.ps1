$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if(-not (Test-Path -LiteralPath $compiler)) { $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'; $compiler = Join-Path $framework 'csc.exe' }
$core = Join-Path $PSScriptRoot 'CampusLuma.Core.dll'
& $compiler /nologo /target:library /optimize+ /codepage:65001 "/out:$core" /reference:System.Web.Extensions.dll /reference:System.Security.dll (Join-Path $PSScriptRoot 'src\Schedule.cs') (Join-Path $PSScriptRoot 'src\Store.cs') (Join-Path $PSScriptRoot 'src\SchoolRegistry.cs') (Join-Path $PSScriptRoot 'src\ResultText.cs') (Join-Path $PSScriptRoot 'src\RunJournal.cs') (Join-Path $PSScriptRoot 'src\ScheduleRecovery.cs')
if($LASTEXITCODE -ne 0) { throw 'Core build failed.' }
$references=@("/reference:$core",'/reference:System.Web.Extensions.dll',('/reference:'+(Join-Path $framework 'WPF\PresentationFramework.dll')),('/reference:'+(Join-Path $framework 'WPF\PresentationCore.dll')),('/reference:'+(Join-Path $framework 'WPF\WindowsBase.dll')),'/reference:System.Xaml.dll')
& $compiler /nologo /target:winexe /optimize+ /codepage:65001 ('/out:'+(Join-Path $PSScriptRoot 'CampusLuma.exe')) @references (Join-Path $PSScriptRoot 'src\App.cs')
if($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
# Windows PowerShell 5.1 needs a BOM to read UTF-8 source containing Chinese.
foreach($script in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -Recurse | Where-Object { $_.FullName -notlike '*\node_modules\*' })) {
    $text=[IO.File]::ReadAllText($script.FullName,[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($script.FullName,$text,(New-Object Text.UTF8Encoding($true)))
}
Write-Output 'Built CampusLuma.exe and CampusLuma.Core.dll.'
