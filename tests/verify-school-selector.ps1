$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $project 'artifacts\school-selector-fixture'
$data=Join-Path $fixture ('data-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $data,(Join-Path $fixture 'ui'),(Join-Path $fixture 'scripts') -Force
foreach($name in @('CampusLuma.exe','CampusLuma.Core.dll','development.mode')){Copy-Item -LiteralPath (Join-Path $project $name) -Destination $fixture -Force}
Copy-Item -LiteralPath (Join-Path $project 'ui\MainWindow.xaml') -Destination (Join-Path $fixture 'ui') -Force
Copy-Item -LiteralPath (Join-Path $project 'adapters') -Destination $fixture -Recurse -Force
$beta=Get-Content -LiteralPath (Join-Path $fixture 'adapters\xtu.json') -Raw -Encoding UTF8|ConvertFrom-Json
$beta.id='fixture-b';$beta.name='模拟乙校';$beta.defaultSsid='Fixture-B';$beta.fallbackPortal='https://portal.beta.invalid/login';$beta.trustedOrigins=@('https://portal.beta.invalid');$beta.browser.selfServiceUrl='https://portal.beta.invalid/self'
$beta|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $fixture 'adapters\fixture-b.json') -Encoding UTF8
$mock=@'
param([string]$DataDirectory,[string]$Action,[string]$TaskPrefix)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=$DataDirectory
$marker=Join-Path $DataDirectory 'applied.json'
if($Action -eq 'Apply'){$s=[CampusLuma.Store]::Load();@{School=$s.Adapter;Prefix=$TaskPrefix;Times=@([CampusLuma.Schedule]::Expand($s))}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding UTF8}
$enabled=Test-Path -LiteralPath $marker
@{Code='SCHEDULE_OK';Enabled=$enabled;Times=@('07:01');NextRun=(Get-Date).AddDays(1).ToString('s')}|ConvertTo-Json -Compress
'@
[IO.File]::WriteAllText((Join-Path $fixture 'scripts\schedule.ps1'),$mock,(New-Object Text.UTF8Encoding($true)))
Add-Type -Path (Join-Path $project 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=$data
$initial=[CampusLuma.SchoolRegistry]::Defaults();$initial.Username='fixture-student';[CampusLuma.Store]::Save($initial,'fixture-password-not-real')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$gui=$null;$checks=New-Object 'Collections.Generic.List[string]'
function Wait-Until([scriptblock]$Test,[string]$ErrorText){$until=(Get-Date).AddSeconds(12);do{if(& $Test){return};Start-Sleep -Milliseconds 100}while((Get-Date) -lt $until);throw $ErrorText}
function Control([string]$Name){$script:ui.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,$Name))}
function Value([string]$Name){(Control $Name).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value}
function Set-Value([string]$Name,[string]$Value){(Control $Name).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Value)}
function Click([string]$Name){(Control $Name).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw $Name};$checks.Add($Name);Write-Output ('PASS '+$Name)}
function Open-Window{
    $script:gui=Start-Process -FilePath (Join-Path $fixture 'CampusLuma.exe') -ArgumentList @('--data-directory',('"'+$data+'"')) -WindowStyle Hidden -PassThru
    Wait-Until {$script:gui.Refresh();$script:gui.MainWindowHandle -ne [IntPtr]::Zero} 'Fixture window did not open.'
    $script:ui=[Windows.Automation.AutomationElement]::FromHandle($script:gui.MainWindowHandle)
    Wait-Until {(Control 'EnableButton').Current.IsEnabled} 'Fixture window was not ready.'
}
function Close-Window{if($script:gui -and -not $script:gui.HasExited){$null=$script:gui.CloseMainWindow();$null=$script:gui.WaitForExit(5000)}}
function Select-School([string]$Name){
    $box=Control 'SchoolBox';$box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $item=$box.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$Name))
    if(-not $item){throw 'School option missing.'}
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
}
try {
    Open-Window
    Select-School '模拟乙校'
    Wait-Until {(Value 'SsidBox') -eq 'Fixture-B'} 'School selection did not apply its Wi-Fi rule.'
    Check ((Value 'UsernameBox') -eq '' -and (Control 'PasswordHint').Current.Name -like '*学校已更改*') 'Switching school clears account input and requires a matching password.'
    Set-Value 'UsernameBox' 'fixture-student';Click 'EnableButton'
    Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -like '*保存失败*'} 'A different school silently reused the old credential.'
    $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
    Check ($saved.Adapter -eq 'xtu') 'Rejected cross-school password reuse leaves saved school unchanged.'
    (Control 'PasswordToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Wait-Until {-not (Control 'VisiblePasswordBox').Current.IsOffscreen} 'Password editor did not reveal.'
    Set-Value 'VisiblePasswordBox' 'second-fixture-password-not-real'
    (Control 'PasswordToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Click 'EnableButton'
    Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -eq '已保存并启用。'} 'Second-school save did not complete.'
    $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
    $cred=Get-Content -LiteralPath (Join-Path $data 'credential.json') -Raw|ConvertFrom-Json
    $applied=Get-Content -LiteralPath (Join-Path $data 'applied.json') -Raw|ConvertFrom-Json
    Check ($saved.Adapter -eq 'fixture-b' -and $saved.Portal -eq 'https://portal.beta.invalid/login' -and $saved.Ssid -eq 'Fixture-B') 'Actual window saves selected school, URL and Wi-Fi from its rule.'
    Check ($cred.SchoolId -eq 'fixture-b' -and $applied.School -eq 'fixture-b') 'Window save binds credentials and scheduled settings to the selected school.'
    Check ($applied.Prefix -eq 'CampusLuma Development') 'Development window uses its independent task namespace.'
    Close-Window;Open-Window
    $selected=(Control 'SchoolBox').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name
    Check ($selected -eq '模拟乙校' -and (Value 'SsidBox') -eq 'Fixture-B' -and (Control 'PasswordHint').Current.Name -like '*无需重填*') 'Reopening retains selected school and matching credential.'
    Select-School '湘潭大学'
    Wait-Until {(Value 'SsidBox') -eq 'XTU-FREE-2'} 'Switching back did not restore XTU rule.'
    Check ((Value 'UsernameBox') -eq '' -and (Control 'PasswordHint').Current.Name -like '*学校已更改*') 'Switching back never sends the other school credential.'
    @{Passed=$true;Checks=$checks.ToArray();RealNetworkModified=$false;RealTaskRegistration=$false;RealCredentialsUsed=$false}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $project 'artifacts\school-selector-result.json') -Encoding UTF8
}finally{Close-Window}
