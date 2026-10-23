$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $project 'artifacts\service-selector-fixture'
$data=Join-Path $fixture ('data-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $data,(Join-Path $fixture 'ui'),(Join-Path $fixture 'scripts') -Force
foreach($name in @('CampusLuma.exe','CampusLuma.Core.dll','development.mode')){Copy-Item -LiteralPath (Join-Path $project $name) -Destination $fixture -Force}
Copy-Item -LiteralPath (Join-Path $project 'ui\MainWindow.xaml') -Destination (Join-Path $fixture 'ui') -Force
Copy-Item -LiteralPath (Join-Path $project 'adapters') -Destination $fixture -Recurse -Force
$beta=Get-Content -LiteralPath (Join-Path $fixture 'adapters\xtu.json') -Raw -Encoding UTF8|ConvertFrom-Json
$beta.id='fixture-b';$beta.name='模拟乙校';$beta.defaultSsid='Fixture-B';$beta.fallbackPortal='https://portal.beta.invalid/login';$beta.trustedOrigins=@('https://portal.beta.invalid');$beta.browser.selfServiceUrl='https://portal.beta.invalid/self'
$beta|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $fixture 'adapters\fixture-b.json') -Encoding UTF8
$snnu=Get-Content -LiteralPath (Join-Path $fixture 'adapters\snnu.json') -Raw -Encoding UTF8|ConvertFrom-Json
$snnu.enabled=$true
$snnu|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $fixture 'adapters\snnu.json') -Encoding UTF8
foreach($id in @('cuit','scit','ysu','uestc-telecom','qlu','dlut-panjin','mnnu-yuanshan')) {
    $file=Join-Path $fixture ('adapters\'+$id+'.json');$r=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
    $r.enabled=$true;$r|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $file -Encoding UTF8
}
$mock=@'
param([string]$DataDirectory,[string]$Action,[string]$TaskPrefix)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'CampusLuma.Core.dll')
[CampusLuma.Store]::Root=$DataDirectory
$marker=Join-Path $DataDirectory 'applied.json'
if($Action -eq 'Apply'){$s=[CampusLuma.Store]::Load();@{School=$s.Adapter;Service=$s.Service;Prefix=$TaskPrefix;Times=@([CampusLuma.Schedule]::Expand($s))}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding UTF8}
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
function Select-Option([string]$Id,[string]$Name){
    $box=Control $Id;$box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $item=$box.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$Name))
    if(-not $item){throw 'School option missing.'}
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
}
try {
    Open-Window
    $service=Control 'ServiceBox'
    Check ($null -eq $service -or $service.Current.IsOffscreen) 'XTU keeps the compact layout without a carrier field.'
    Select-Option 'SchoolBox' '陕西师范大学'
    Wait-Until {(Value 'SsidBox') -eq 'SNNU' -and -not (Control 'ServiceBox').Current.IsOffscreen} 'SNNU did not show its carrier selector.'
    $selection=(Control 'ServiceBox').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    Check ($selection.Length -eq 0) 'SNNU never guesses a default carrier.'
    Set-Value 'UsernameBox' 'fixture-student'
    (Control 'PasswordToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Wait-Until {-not (Control 'VisiblePasswordBox').Current.IsOffscreen} 'Password editor did not reveal.'
    Set-Value 'VisiblePasswordBox' 'fixture-password-not-real'
    (Control 'PasswordToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Click 'EnableButton'
    Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -like '*请选择本人已开通*'} 'Missing carrier was not explained.'
    $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
    Check ($saved.Adapter -eq 'xtu' -and -not (Test-Path -LiteralPath (Join-Path $data 'applied.json'))) 'An unselected service cannot overwrite settings or enable a task.'
    Select-Option 'ServiceBox' '联通';Click 'EnableButton'
    Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -eq '已保存并启用。'} 'Carrier save did not complete.'
    $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
    $applied=Get-Content -LiteralPath (Join-Path $data 'applied.json') -Raw|ConvertFrom-Json
    Check ($saved.Adapter -eq 'snnu' -and $saved.Service -eq 'unicom' -and $applied.Service -eq 'unicom' -and $applied.Prefix -eq 'CampusLuma Development') 'Carrier persists through the actual window and isolated scheduling bridge.'
    $credentialHash=(Get-FileHash -LiteralPath (Join-Path $data 'credential.json')).Hash
    Close-Window;Open-Window
    $selection=(Control 'ServiceBox').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    Check ($selection[0].Current.Name -eq '联通') 'Reopening retains the selected service.'
    Select-Option 'ServiceBox' '移动'
    Check ((Control 'ScheduleStatus').Current.Name -like '*未保存*') 'Changing the service does not pretend to activate the change.'
    Click 'EnableButton'
    Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -eq '已保存并启用。'} 'Carrier-only save failed.'
    $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
    Check ($saved.Service -eq 'mobile' -and (Get-FileHash -LiteralPath (Join-Path $data 'credential.json')).Hash -eq $credentialHash) 'Changing service reuses the encrypted password without rewriting it.'
    Select-Option 'SchoolBox' '湘潭大学'
    $service=Control 'ServiceBox'
    Check ($null -eq $service -or $service.Current.IsOffscreen) 'Switching to XTU hides the extra field.'
    Select-Option 'SchoolBox' '陕西师范大学'
    Set-Value 'UsernameBox' 'fixture-student';Select-Option 'ServiceBox' '校园网';Click 'EnableButton'
    Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -eq '已保存并启用。'} 'Empty campus service was rejected.'
    $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
    Check ($null -ne $saved.Service -and $saved.Service -ceq '') 'Campus service saves as an explicit empty string, not null.'
    Close-Window
    $preview=Start-Process -FilePath (Join-Path $fixture 'CampusLuma.exe') -ArgumentList @('--render-preview','--data-directory',('"'+$data+'"'),'--output',('"'+(Join-Path $project 'artifacts\snnu-service-window.png')+'"')) -WindowStyle Hidden -PassThru
    if(-not $preview.WaitForExit(15000) -or $preview.ExitCode -ne 0){throw 'Carrier window render failed.'}
    Open-Window
    foreach($id in @('cuit','scit','ysu','uestc-telecom','qlu','dlut-panjin','mnnu-yuanshan')) {
        $r=Get-Content -LiteralPath (Join-Path $fixture ('adapters\'+$id+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
        Select-Option 'SchoolBox' $r.name
        Check ((Value 'SsidBox') -ceq $r.defaultSsid) ($id+' uses its actual or deliberately blank Wi-Fi default.')
        $hasServices=$null -ne $r.browser.services
        if($hasServices){$selected=(Control 'ServiceBox').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection();Check ($selected.Length -eq 0) ($id+' does not reuse another school service.')}
        else{Check ((Control 'ServiceBox').Current.IsOffscreen) ($id+' has no invented operator field.')}
        Set-Value 'UsernameBox' 'fixture-student'
        (Control 'PasswordToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
        Set-Value 'VisiblePasswordBox' 'fixture-password-not-real'
        (Control 'PasswordToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
        if($hasServices){Select-Option 'ServiceBox' $(if($id -eq 'qlu'){'互联网'}else{'电信'})}
        if($r.requiresUserSsid){Set-Value 'SsidBox' 'Fixture-Campus'}
        Click 'EnableButton'
        Wait-Until {(Control 'EnableButton').Current.IsEnabled -and (Control 'Toast').Current.Name -eq '已保存并启用。'} ($id+' save did not complete.')
        $saved=Get-Content -LiteralPath (Join-Path $data 'settings.json') -Raw|ConvertFrom-Json
        $applied=Get-Content -LiteralPath (Join-Path $data 'applied.json') -Raw|ConvertFrom-Json
        $expectedService=if($id -eq 'qlu'){'internet'}elseif($hasServices){'telecom'}else{$null}
        Check ($saved.Adapter -ceq $id -and [object]::Equals($saved.Service,$expectedService) -and $applied.Prefix -ceq 'CampusLuma Development' -and $applied.School -ceq $id) ($id+' window saves its own service and passes it to scheduling.')
    }
    Close-Window
    $preview=Start-Process -FilePath (Join-Path $fixture 'CampusLuma.exe') -ArgumentList @('--render-preview','--data-directory',('"'+$data+'"'),'--output',('"'+(Join-Path $project 'artifacts\sam-service-window.png')+'"')) -WindowStyle Hidden -PassThru
    if(-not $preview.WaitForExit(15000) -or $preview.ExitCode -ne 0){throw 'SAM carrier window render failed.'}
    @{Passed=$true;Checks=$checks.ToArray();RealNetworkModified=$false;RealTaskRegistration=$false;RealCredentialsUsed=$false}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $project 'artifacts\service-selector-result.json') -Encoding UTF8
}finally{Close-Window}
