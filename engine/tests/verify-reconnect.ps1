$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('xtu-reconnect-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture

# Execute the real entry script with simulated OS commands and provider.
# Each scenario runs in a separate process and cannot change real Wi-Fi.
$harness = @'
param([string]$CasePath)
$ErrorActionPreference = 'Stop'
$global:testCase = Get-Content -LiteralPath $CasePath -Raw | ConvertFrom-Json
$global:testSsid = $global:testCase.ssid
$global:testOnline = [bool]$global:testCase.online
$global:testConnectionPending = $false
$global:testConnectPolls = 0
$global:testProbeCount = 0
$global:testTrace = Join-Path $PSScriptRoot 'trace.txt'
function global:netsh {
    $operation = $args -join ' '
    Add-Content -LiteralPath $global:testTrace -Value ('netsh ' + $operation)
    if ($operation -like 'wlan show interfaces*') {
        if($global:testCase.statusReadError){$global:LASTEXITCODE=5;return}
        if ($global:testConnectionPending) {
            $global:testConnectPolls++
            if ($global:testConnectPolls -ge [int]$global:testCase.connectDelayPolls) {
                $global:testSsid = $global:testCase.afterConnectSsid
                $global:testOnline = [bool]$global:testCase.afterConnectOnline
                $global:testConnectionPending = $false
            }
        }
        if($global:testCase.extraSsid){'    Name : Other-WiFi';'    SSID : '+$global:testCase.extraSsid}
        if(-not $global:testCase.omitTarget){
            if(-not $global:testCase.omitHeaders){if($global:testCase.chineseHeader){'    名称 ： WLAN'}else{'    Name : WLAN'}}
            if ($global:testSsid) { '    SSID : ' + $global:testSsid }
        }
    } elseif ($operation -like 'wlan show networks*') {
        if($global:testCase.networkListError){$global:LASTEXITCODE=5;return}
        $index = 0
        foreach ($ssid in @($global:testCase.visibleSsids)) {
            $index++
            'SSID ' + $index + ' : ' + $ssid
        }
    } elseif ($operation -like 'wlan connect*') {
        if ($global:testCase.connectError) {
            $global:LASTEXITCODE = 1
            return
        }
        $global:testConnectionPending = $true
    } else { throw 'Unexpected netsh operation.' }
    $global:LASTEXITCODE = 0
}
function global:curl.exe {
    Add-Content -LiteralPath $global:testTrace -Value 'internet-probe'
    $global:testProbeCount++
    $changeAfter = 2
    if ($global:testCase.changeSsidAfterProbeCount) { $changeAfter = [int]$global:testCase.changeSsidAfterProbeCount }
    if ($global:testCase.changeSsidAfterProbe -and $global:testProbeCount -ge $changeAfter) {
        $global:testSsid = $global:testCase.changeSsidAfterProbe
    }
    if ($global:testOnline) {
        $global:LASTEXITCODE = 0
        'Microsoft Connect Test'
    } else {
        $global:LASTEXITCODE = 7
    }
}
function global:Start-Sleep { param([int]$Seconds) }
& (Join-Path $PSScriptRoot 'campus-network-reconnect.ps1') -Once -StructuredResult
exit $LASTEXITCODE
'@
$provider = @'
Add-Content -LiteralPath $global:testTrace -Value 'authenticate'
$global:testOnline = [bool]$global:testCase.afterAuthOnline
if ($global:testCase.afterAuthSsid) { $global:testSsid = $global:testCase.afterAuthSsid }
[pscustomobject]@{ Attempted = $true; Code = 'FIXTURE_AUTH_RESULT' }
'@
$scan = @'
param([string]$InterfaceName)
Add-Content -LiteralPath $global:testTrace -Value 'active-scan'
if ($global:testCase.scanError) { return 5 }
if ($global:testCase.afterScanSsids) { $global:testCase.visibleSsids = $global:testCase.afterScanSsids }
return 0
'@
$cases = @(
    @{ name = 'home-online-no-campus'; ssid = 'HomeWiFi'; online = $true; visibleSsids = @('HomeWiFi'); expectedExit = 0; probes = 0; scans = 1; connects = 0; auth = 0 },
    @{ name = 'home-offline-no-campus'; ssid = 'HomeWiFi'; online = $false; visibleSsids = @('HomeWiFi'); expectedExit = 0; probes = 0; scans = 1; connects = 0; auth = 0 },
    @{ name = 'lookalike-campus-is-not-target'; ssid = 'HomeWiFi'; visibleSsids = @('XTU-FREE-20', 'xtu-free-2'); expectedExit = 0; probes = 0; scans = 1; connects = 0; auth = 0 },
    @{ name = 'campus-online'; ssid = 'XTU-FREE-2'; online = $true; expectedExit = 0; probes = 1; scans = 0; connects = 0; auth = 0 },
    @{ name = 'disconnected-no-campus'; ssid = ''; online = $false; visibleSsids = @('HomeWiFi'); expectedExit = 0; probes = 0; scans = 1; connects = 0; auth = 0 },
    @{ name = 'wired-online-no-campus'; ssid = ''; online = $true; visibleSsids = @(); expectedExit = 0; probes = 0; scans = 1; connects = 0; auth = 0 },
    @{ name = 'campus-auth-recovers'; ssid = 'XTU-FREE-2'; online = $false; afterAuthOnline = $true; expectedExit = 0; probes = 3; scans = 0; connects = 0; auth = 1 },
    @{ name = 'campus-auth-fails-once'; ssid = 'XTU-FREE-2'; online = $false; afterAuthOnline = $false; expectedExit = 1; probes = 4; scans = 0; connects = 0; auth = 1 },
    @{ name = 'hotspot-online-switches-campus-no-login-needed'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('PhoneHotspot', 'XTU-FREE-2'); afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $true; expectedExit = 0; probes = 1; scans = 1; connects = 1; auth = 0 },
    @{ name = 'hotspot-online-switches-campus-then-auth'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('PhoneHotspot', 'XTU-FREE-2'); afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $false; afterAuthOnline = $true; expectedExit = 0; probes = 3; scans = 1; connects = 1; auth = 1 },
    @{ name = 'other-offline-switches-campus-then-auth'; ssid = 'OtherWiFi'; online = $false; visibleSsids = @('XTU-FREE-2'); afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $false; afterAuthOnline = $true; expectedExit = 0; probes = 3; scans = 1; connects = 1; auth = 1 },
    @{ name = 'waits-through-previous-ssid-during-switch'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('XTU-FREE-2'); connectDelayPolls = 3; afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $true; expectedExit = 0; probes = 1; scans = 1; connects = 1; auth = 0 },
    @{ name = 'disconnected-campus-connects'; ssid = ''; online = $false; visibleSsids = @('XTU-FREE-2'); afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $true; expectedExit = 0; probes = 1; scans = 1; connects = 1; auth = 0 },
    @{ name = 'visible-campus-connect-request-fails'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('XTU-FREE-2'); connectError = $true; expectedExit = 1; expectedCode='WIFI_CONNECT_FAILED';probes = 0; scans = 1; connects = 1; auth = 0 },
    @{ name = 'visible-campus-switch-times-out'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('XTU-FREE-2'); connectDelayPolls = 100; afterConnectSsid = 'XTU-FREE-2'; expectedExit = 1; expectedCode='WIFI_CONNECT_TIMEOUT';probes = 0; scans = 1; connects = 1; auth = 0 },
    @{ name = 'switch-to-campus-auth-fails-once'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('XTU-FREE-2'); afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $false; afterAuthOnline = $false; expectedExit = 1; probes = 4; scans = 1; connects = 1; auth = 1 },
    @{ name = 'wifi-changes-before-authentication'; ssid = 'XTU-FREE-2'; online = $false; changeSsidAfterProbe = 'PhoneHotspot'; expectedExit = 1; expectedCode='WIFI_CHANGED_BEFORE_AUTH';probes = 2; scans = 0; connects = 0; auth = 0 },
    @{ name = 'hotspot-online-during-probe-is-not-campus-success'; ssid = 'XTU-FREE-2'; online = $true; changeSsidAfterProbe = 'PhoneHotspot'; changeSsidAfterProbeCount = 1; expectedExit = 1; probes = 1; scans = 0; connects = 0; auth = 0 },
    @{ name = 'hotspot-online-after-auth-is-not-campus-success'; ssid = 'XTU-FREE-2'; online = $false; afterAuthOnline = $true; afterAuthSsid = 'PhoneHotspot'; expectedExit = 1; expectedCode='WIFI_CHANGED_DURING_AUTH';probes = 3; scans = 0; connects = 0; auth = 1 },
    @{ name = 'active-scan-refreshes-stale-network-list'; ssid = 'PhoneHotspot'; online = $true; visibleSsids = @('PhoneHotspot'); afterScanSsids = @('XTU-FREE-2'); afterConnectSsid = 'XTU-FREE-2'; afterConnectOnline = $true; expectedExit = 0; probes = 1; scans = 1; connects = 1; auth = 0 },
    @{ name = 'active-scan-denied-does-not-switch'; ssid = 'PhoneHotspot'; online = $true; scanError = $true; expectedExit = 1; expectedCode='WIFI_SCAN_FAILED';probes = 0; scans = 0; connects = 0; auth = 0 },
    @{ name = 'ignores-other-adapter-before-campus';ssid='XTU-FREE-2';extraSsid='OtherNetwork';online=$true;expectedExit=0;expectedCode='ALREADY_ONLINE';probes=1;scans=0;connects=0;auth=0 },
    @{ name = 'campus-on-other-adapter-does-not-count';ssid='HomeWiFi';extraSsid='XTU-FREE-2';online=$true;visibleSsids=@('HomeWiFi');expectedExit=0;expectedCode='CAMPUS_NOT_VISIBLE';probes=0;scans=1;connects=0;auth=0 },
    @{ name = 'missing-selected-adapter-stops-before-scan';ssid='HomeWiFi';extraSsid='XTU-FREE-2';omitTarget=$true;expectedExit=1;expectedCode='CAMPUS_INTERFACE_REQUIRED';probes=0;scans=0;activeScans=0;connects=0;auth=0 },
    @{ name = 'unknown-layout-stops-before-credentials';ssid='XTU-FREE-2';omitHeaders=$true;expectedExit=1;expectedCode='WIFI_STATUS_UNRECOGNIZED';probes=0;scans=0;activeScans=0;connects=0;auth=0 },
    @{ name = 'native-status-error-stops-before-credentials';ssid='XTU-FREE-2';statusReadError=$true;expectedExit=1;expectedCode='WIFI_STATUS_UNAVAILABLE';probes=0;scans=0;activeScans=0;connects=0;auth=0 },
    @{ name = 'chinese-interface-header-and-colon';ssid='XTU-FREE-2';chineseHeader=$true;online=$true;expectedExit=0;expectedCode='ALREADY_ONLINE';probes=1;scans=0;connects=0;auth=0 },
    @{ name = 'network-list-read-denied-is-not-campus-absent';ssid='PhoneHotspot';networkListError=$true;expectedExit=1;expectedCode='WIFI_SCAN_FAILED';probes=0;scans=1;connects=0;auth=0 }
)

try {
    $entry=[IO.File]::ReadAllText((Join-Path $root 'campus-network-reconnect.ps1')).Replace('Local\XTUCampusNetworkReconnect',('Local\CampusLumaReconnectTest'+[guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText((Join-Path $fixture 'campus-network-reconnect.ps1'),$entry,(New-Object Text.UTF8Encoding($true)))
    '{"targetSsid":"XTU-FREE-2","interfaceName":"WLAN","startHour":7,"startMinute":1}' |
        Set-Content -LiteralPath (Join-Path $fixture 'campus-settings.json') -Encoding UTF8
    $harness | Set-Content -LiteralPath (Join-Path $fixture 'harness.ps1') -Encoding UTF8
    $provider | Set-Content -LiteralPath (Join-Path $fixture 'campus-auth.ps1') -Encoding UTF8
    $scan | Set-Content -LiteralPath (Join-Path $fixture 'wifi-scan.ps1') -Encoding UTF8
    foreach ($case in $cases) {
        $tracePath = Join-Path $fixture 'trace.txt'
        if (Test-Path -LiteralPath $tracePath) { Remove-Item -LiteralPath $tracePath }
        $casePath = Join-Path $fixture 'case.json'
        $case | ConvertTo-Json | Set-Content -LiteralPath $casePath -Encoding UTF8
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -CasePath "{1}"' -f (Join-Path $fixture 'harness.ps1'), $casePath
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        try {
            $process.StartInfo = $start
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(15000)) { $process.Kill(); throw ('Timed out: ' + $case.name) }
            $trace = @(Get-Content -LiteralPath $tracePath)
            $probes = @($trace | Where-Object { $_ -eq 'internet-probe' }).Count
            $connects = @($trace | Where-Object { $_ -like 'netsh wlan connect*' }).Count
            $scans = @($trace | Where-Object { $_ -like 'netsh wlan show networks*' }).Count
            $activeScans = @($trace | Where-Object { $_ -eq 'active-scan' }).Count
            $expectedActiveScans = 0
            if ($case.ssid -cne 'XTU-FREE-2') { $expectedActiveScans = 1 }
            if($case.ContainsKey('activeScans')){$expectedActiveScans=$case.activeScans}
            $auth = @($trace | Where-Object { $_ -eq 'authenticate' }).Count
            if ($process.ExitCode -ne $case.expectedExit -or $probes -ne $case.probes -or
                $scans -ne $case.scans -or $activeScans -ne $expectedActiveScans -or
                $connects -ne $case.connects -or $auth -ne $case.auth) {
                throw ('FAILED {0}: exit={1}; probes={2}; connects={3}; auth={4}; scans={5}; stdout={6}; stderr={7}' -f
                    $case.name, $process.ExitCode, $probes, $connects, $auth, $scans, $stdout.Result, $stderr.Result)
            }
            $reply=$stdout.Result|ConvertFrom-Json
            if($case.expectedCode -and $reply.Code -ne $case.expectedCode){throw ('Incorrect diagnostic outcome: '+$case.name+' '+$reply.Code)}
            if($case.expectedExit -ne 0 -and $reply.Success){throw ('Failure incorrectly reported as online: '+$case.name)}
            Write-Output ('PASS ' + $case.name)
        } finally { $process.Dispose() }
    }
    Write-Output ('Reconnect workflow: ' + $cases.Count + ' scenarios passed.')
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^xtu-reconnect-[0-9a-f]{32}$') {
        throw 'Refusing to clean up an unexpected test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
