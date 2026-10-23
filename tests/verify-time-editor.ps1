param([string]$TestDataParent='')
$ErrorActionPreference='Stop'
$projectPath=Split-Path $PSScriptRoot -Parent
$fixturePath=Join-Path $projectPath 'artifacts\time-editor-fixture'
$dataPath=Join-Path $(if($TestDataParent){$TestDataParent}else{$fixturePath}) ('data-'+[guid]::NewGuid().ToString('N'))
$encoding=New-Object Text.UTF8Encoding($true)
$null=New-Item -ItemType Directory -Path (Join-Path $fixturePath 'ui'),(Join-Path $fixturePath 'scripts'),$dataPath -Force
foreach($file in @('CampusLuma.exe','CampusLuma.Core.dll')) { Copy-Item -LiteralPath (Join-Path $projectPath $file) -Destination $fixturePath -Force }
Copy-Item -LiteralPath (Join-Path $projectPath 'ui\MainWindow.xaml') -Destination (Join-Path $fixturePath 'ui') -Force
Copy-Item -LiteralPath (Join-Path $projectPath 'adapters') -Destination $fixturePath -Recurse -Force
# Exercise the actual GUI save handler and DPAPI store, while replacing only
# task registration. This fixture has no network worker or authentication engine.
$scheduler=@'
param([string]$DataDirectory,[string]$Action,[string]$TaskPrefix)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=$DataDirectory
$marker=Join-Path $DataDirectory 'applied-times.json'
if($Action -eq 'Apply') {
    $settings=[CampusLuma.Store]::Load()
    [CampusLuma.Schedule]::Expand($settings) | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
}
if($Action -eq 'Disable' -and (Test-Path -LiteralPath $marker)) { Remove-Item -LiteralPath $marker }
$enabled=Test-Path -LiteralPath $marker
$next=if($enabled){[CampusLuma.Schedule]::Next([CampusLuma.Store]::Load(),[datetime]::Now).ToString('s')}else{''}
$times=if($enabled){@(Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json)}else{@()}
@{Code='SCHEDULE_OK';Enabled=$enabled;Times=@($times);NextRun=$next} | ConvertTo-Json -Compress
'@
[IO.File]::WriteAllText((Join-Path $fixturePath 'scripts\schedule.ps1'),$scheduler,$encoding)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TimeEditorNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
}
'@
$script:fixtureProcess=$null
$script:uiRoot=$null
$checks=New-Object 'System.Collections.Generic.List[string]'
function Wait-Until([scriptblock]$Condition,[string]$Message) {
    $deadline=[datetime]::Now.AddSeconds(10)
    do { if(& $Condition){return}; Start-Sleep -Milliseconds 100 } while([datetime]::Now -lt $deadline)
    throw $Message
}
function Control([string]$Id) {
    $script:uiRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$Id))
}
function Value([string]$Id) { (Control $Id).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Set-Value([string]$Id,[string]$Text) { (Control $Id).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Text) }
function Click([string]$Id) { (Control $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Toggle-Password { (Control 'PasswordToggle').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() }
function Plaintext-Hidden {
    $clear=Control 'VisiblePasswordBox'
    return (-not $clear -or ($clear.Current.IsOffscreen -and (Value 'VisiblePasswordBox') -eq ''))
}
function Save-Fixture {
    $configPath=Join-Path $dataPath 'settings.json'
    $before=if(Test-Path -LiteralPath $configPath){(Get-Item -LiteralPath $configPath).LastWriteTimeUtc.Ticks}else{0}
    Click 'EnableButton'
    Wait-Until { (Test-Path -LiteralPath $configPath) -and (Get-Item -LiteralPath $configPath).LastWriteTimeUtc.Ticks -gt $before -and (Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -eq '已保存并启用。' } 'Save-and-enable UI did not complete.'
}
function Check([bool]$Passed,[string]$Message) { if(-not $Passed){throw $Message}; $checks.Add($Message); Write-Output ('PASS '+$Message) }
function Open-Fixture {
    $script:fixtureProcess=Start-Process -FilePath (Join-Path $fixturePath 'CampusLuma.exe') -ArgumentList @('--data-directory',('"'+$dataPath+'"')) -WindowStyle Hidden -PassThru
    Wait-Until { $script:fixtureProcess.Refresh(); $script:fixtureProcess.MainWindowHandle -ne [IntPtr]::Zero } 'Fixture window did not open.'
    $script:uiRoot=[System.Windows.Automation.AutomationElement]::FromHandle($script:fixtureProcess.MainWindowHandle)
    Wait-Until { (Control 'AddTimeButton').Current.IsEnabled } 'Fixture window did not finish loading.'
}
function Close-Fixture {
    if($script:fixtureProcess -and -not $script:fixtureProcess.HasExited) {
        $null=$script:fixtureProcess.CloseMainWindow()
        if(-not $script:fixtureProcess.WaitForExit(5000)){throw 'Fixture window did not close.'}
    }
}
try {
    Open-Fixture
    Set-Value 'UsernameBox' 'fixture-student'
    Toggle-Password
    Wait-Until { $null -ne (Control 'VisiblePasswordBox') -and -not (Control 'VisiblePasswordBox').Current.IsOffscreen } 'Eye toggle did not reveal the input.'
    Set-Value 'VisiblePasswordBox' 'fixture-password-not-real'
    Check ((Value 'VisiblePasswordBox') -eq 'fixture-password-not-real') 'Eye reveals the typed password and permits editing.'
    Toggle-Password
    Wait-Until { -not (Control 'PasswordBox').Current.IsOffscreen -and (Plaintext-Hidden) } 'Eye toggle did not mask the input.'
    Check ((Control 'PasswordBox').Current.IsPassword -and (Plaintext-Hidden)) 'Second eye click masks the password and removes clear text from the UI.'
    Toggle-Password
    Wait-Until { $null -ne (Control 'VisiblePasswordBox') -and -not (Control 'VisiblePasswordBox').Current.IsOffscreen } 'Eye toggle did not reveal again.'
    Check ((Value 'VisiblePasswordBox') -eq 'fixture-password-not-real') 'Repeated eye toggles preserve the entered password.'
    Save-Fixture
    $credentialHash=(Get-FileHash -LiteralPath (Join-Path $dataPath 'credential.json')).Hash
    $firstApplied=Get-Content -LiteralPath (Join-Path $dataPath 'applied-times.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check (($firstApplied -join ',') -eq '07:01' -and (Plaintext-Hidden) -and (Control 'PasswordHint').Current.Name -like '*无需重填*') 'First save enables 07:01, clears the input, and explains password reuse.'
    Click 'AddTimeButton'; Click 'AddTimeButton'; Click 'AddTimeButton'
    Wait-Until { $null -ne (Control 'TimeBox3') } 'Plus clicks did not create four time editors.'
    Check ((Value 'TimeBox0') -eq '07:01' -and (Value 'TimeBox1') -eq '08:01' -and (Value 'TimeBox2') -eq '09:01' -and (Value 'TimeBox3') -eq '10:01') 'Repeated plus clicks add separate editable times.'
    Check ((Control 'ScheduleStatus').Current.Name -like '*修改尚未保存*') 'Unsaved edits do not masquerade as the active schedule.'
    Click 'RemoveTime3'; Click 'RemoveTime2'
    Wait-Until { $null -eq (Control 'TimeBox2') } 'Extra editors were not removed.'
    Save-Fixture
    # Windows PowerShell 5.1 emits JSON arrays as one pipeline object. An @()
    # wrapper nests that array; assignment retains the actual time strings.
    $secondApplied=Get-Content -LiteralPath (Join-Path $dataPath 'applied-times.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check (($secondApplied -join ',') -eq '07:01,08:01' -and (Get-FileHash -LiteralPath (Join-Path $dataPath 'credential.json')).Hash -eq $credentialHash) 'Adding 08:01 and saving again reuses the encrypted password.'
    Click 'AddTimeButton'; Click 'AddTimeButton'
    Wait-Until { $null -ne (Control 'TimeBox3') } 'Editors did not return.'
    Set-Value 'TimeBox1' '7：30'
    Set-Value 'TimeBox2' '18:00'
    $null=[TimeEditorNative]::SetForegroundWindow($script:fixtureProcess.MainWindowHandle)
    (Control 'TimeBox1').SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Wait-Until { (Value 'TimeBox1') -eq '07:30' } 'Enter did not normalize the edited time.'
    Check ((Control 'ScheduleStatus').Current.Name -like '*修改尚未保存*' -and ((Get-Content -LiteralPath (Join-Path $dataPath 'applied-times.json') -Raw -Encoding UTF8 | ConvertFrom-Json) -join ',') -eq '07:01,08:01') 'Enter edits a time without updating the active schedule.'
    Set-Value 'TimeBox1' '07:01'
    Check ((Control 'PreviewText').Current.Name -like '*重复*') 'Duplicate time has visible feedback.'
    Set-Value 'TimeBox1' '24:00'
    Check ((Control 'PreviewText').Current.Name -like '*时间请用*') 'Invalid time has visible feedback.'
    Set-Value 'TimeBox1' '12:30'
    Click 'RemoveTime3'
    Wait-Until { $null -eq (Control 'TimeBox3') } 'Delete did not remove the last editor.'
    Check ($null -eq (Control 'TimeBox3') -and (Control 'PreviewText').Current.Name -like '*共 3 次') 'Delete removes only the selected time.'
    Save-Fixture
    $saved=Get-Content -LiteralPath (Join-Path $dataPath 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $applied=Get-Content -LiteralPath (Join-Path $dataPath 'applied-times.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check (($saved.Times -join ',') -eq '07:01,12:30,18:00' -and ($applied -join ',') -eq '07:01,12:30,18:00') 'Save passes all edited times to storage and the isolated scheduler.'
    $configPath=Join-Path $dataPath 'settings.json'
    $attributes=[IO.File]::GetAttributes($configPath)
    try {
        [IO.File]::SetAttributes($configPath,($attributes -bor [IO.FileAttributes]::ReadOnly))
        Click 'AddTimeButton'
        Wait-Until { $null -ne (Control 'TimeBox3') } 'Fourth time was not added.'
        Toggle-Password
        Wait-Until { -not (Control 'VisiblePasswordBox').Current.IsOffscreen } 'Password input did not reveal for rollback test.'
        Set-Value 'VisiblePasswordBox' 'replacement-fixture-password-not-real'
        Toggle-Password
        Wait-Until { Plaintext-Hidden } 'Password input did not hide before rollback test.'
        Click 'EnableButton'
        Wait-Until { (Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -like '*修改尚未生效*' } 'Failed write was not reported clearly.'
        $afterFailure=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $afterApplied=Get-Content -LiteralPath (Join-Path $dataPath 'applied-times.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Check (($afterFailure.Times -join ',') -eq '07:01,12:30,18:00' -and ($afterApplied -join ',') -eq '07:01,12:30,18:00' -and (Control 'ScheduleStatus').Current.Name -like '*修改尚未保存*' -and (Get-FileHash -LiteralPath (Join-Path $dataPath 'credential.json')).Hash -eq $credentialHash) 'Denied writes restore the prior password and settings, keep the old schedule, and show failure.'
    } finally { [IO.File]::SetAttributes($configPath,$attributes) }
    Toggle-Password
    Wait-Until { -not (Control 'VisiblePasswordBox').Current.IsOffscreen } 'Password input did not reveal for clearing.'
    Set-Value 'VisiblePasswordBox' ''
    Toggle-Password
    Wait-Until { Plaintext-Hidden } 'Cleared password input did not hide.'
    Click 'RemoveTime3'; Save-Fixture
    Close-Fixture; Open-Fixture
    Check ((Value 'TimeBox0') -eq '07:01' -and (Value 'TimeBox1') -eq '12:30' -and (Value 'TimeBox2') -eq '18:00') 'Closing and reopening preserves all custom times.'
    @{Code='CUSTOM_TIME_EDITOR_AND_PASSWORD_VERIFIED';Passed=$true;Checks=$checks.ToArray();NetworkChanged=$false;RealTaskRegistration=$false;SavedTimes=$saved.Times;DataDirectoryAttributes=[IO.File]::GetAttributes($dataPath).ToString()} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $projectPath 'artifacts\time-editor-result.json') -Encoding UTF8
} finally { Close-Fixture }
