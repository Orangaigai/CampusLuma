param([switch]$Once, [string]$TargetSsid, [string]$DataDirectory = $PSScriptRoot, [switch]$StructuredResult)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $DataDirectory 'campus-network-reconnect.log'
$mutex = New-Object System.Threading.Mutex($false, 'Local\XTUCampusNetworkReconnect')
$ownsMutex = $false
$outcome = @{ Code = 'RECOVERY_FAILED'; Success = $false; AuthenticationAttempted = $false; AuthenticationCode = $null }

function Write-Status([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    if ($Once -and -not $StructuredResult) { Write-Output $line }
}

function Test-Internet {
    $text = & curl.exe -4 --noproxy '*' --connect-timeout 3 --max-time 5 -s 'http://www.msftconnecttest.com/connecttest.txt' 2>$null
    if ($LASTEXITCODE -eq 0 -and ($text -join '').Trim() -eq 'Microsoft Connect Test') { return $true }
    $status = & curl.exe -4 --noproxy '*' --connect-timeout 3 --max-time 5 -s -o NUL -w '%{http_code}' 'https://connectivitycheck.platform.hicloud.com/generate_204' 2>$null
    return ($LASTEXITCODE -eq 0 -and ($status -join '').Trim() -eq '204')
}

function Get-CurrentSsid {
    $lines=@(netsh wlan show interfaces 2>$null)
    if($LASTEXITCODE -ne 0){
        $outcome.Code='WIFI_STATUS_UNAVAILABLE';$outcome.WifiErrorCode=$LASTEXITCODE
        throw 'Unable to read Wi-Fi status.'
    }
    $selected=$false;$found=0;$headers=0;$current=$null
    foreach ($line in $lines) {
        if($line -match '^\s*(?:Name|名称)\s*[:：]\s*(.*?)\s*$'){
            $headers++;$selected=$Matches[1] -ceq $settings.interfaceName
            if($selected){$found++}
        }elseif($selected -and $line -match '^\s*SSID\s*[:：]\s*(.+?)\s*$'){$current=$Matches[1]}
    }
    if($headers -eq 0){$outcome.Code='WIFI_STATUS_UNRECOGNIZED';throw 'Unrecognized Wi-Fi status layout.'}
    if($found -ne 1){$outcome.Code='CAMPUS_INTERFACE_REQUIRED';throw 'Configured Wi-Fi interface could not be identified uniquely.'}
    return $current
}

function Test-CampusVisible([string]$ssid, [string]$interfaceName) {
    $scanCode = & (Join-Path $PSScriptRoot 'wifi-scan.ps1') -InterfaceName $interfaceName
    if ($scanCode -ne 0) {
        $outcome.Code='WIFI_SCAN_FAILED';$outcome.WifiErrorCode=$scanCode
        Write-Status ('Wi-Fi scan failed with Windows error code: ' + $scanCode)
        throw 'Unable to refresh the Wi-Fi network list.'
    }
    $networks=@(netsh wlan show networks interface="$interfaceName" mode=ssid 2>$null)
    if($LASTEXITCODE -ne 0){$outcome.Code='WIFI_SCAN_FAILED';$outcome.WifiErrorCode=$LASTEXITCODE;throw 'Unable to read available Wi-Fi networks.'}
    foreach ($line in $networks) {
        if ($line -match '^\s*SSID\s+\d+\s*[:：]\s*(.*?)\s*$' -and $Matches[1] -ceq $ssid) {
            return $true
        }
    }
    return $false
}

try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        $outcome.Code = 'RUN_SKIPPED'
        if ($Once -and -not $StructuredResult) { Write-Output 'A recovery run is already active.' }
        exit 0
    }

    $settings = @{}
    foreach ($file in @('campus-settings.json', 'local-settings.json')) {
        $path = Join-Path $DataDirectory $file
        if (Test-Path -LiteralPath $path) {
            $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($property in $data.PSObject.Properties) { $settings[$property.Name] = $property.Value }
        }
    }
    if ($TargetSsid) { $settings.targetSsid = $TargetSsid }
    if (-not $settings.targetSsid -or -not $settings.interfaceName) {
        throw 'Invalid campus recovery settings.'
    }

    $ssid = Get-CurrentSsid
    if ($ssid -cne $settings.targetSsid) {
        # At the daily run, prefer campus even if another Wi-Fi is online.
        # Read the available networks once; no background polling at home.
        if (-not (Test-CampusVisible $settings.targetSsid $settings.interfaceName)) {
            Write-Status 'Target campus Wi-Fi not visible; keeping current connection.'
            $outcome.Code = 'CAMPUS_NOT_VISIBLE'
            exit 0
        }
        Write-Status 'Target campus Wi-Fi visible; connecting to saved campus profile.'
        Start-Sleep -Seconds 2
        $null = netsh wlan connect name="$($settings.targetSsid)" interface="$($settings.interfaceName)" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $outcome.Code='WIFI_CONNECT_FAILED';$outcome.WifiErrorCode=$LASTEXITCODE
            Write-Status 'Campus Wi-Fi connection request failed; no authentication attempted.'
            exit 1
        }
        for ($check = 0; $check -lt 10; $check++) {
            Start-Sleep -Seconds 2
            $ssid = Get-CurrentSsid
            # Windows can still report the previous SSID during the switch.
            if ($ssid -ceq $settings.targetSsid) { break }
        }
    }
    if ($ssid -cne $settings.targetSsid) {
        $outcome.Code='WIFI_CONNECT_TIMEOUT'
        Write-Status 'Campus Wi-Fi did not connect within the wait limit; no authentication attempted.'
        exit 1
    }
    # Existing sessions and successful no-sense authentication need no login.
    $online = Test-Internet
    if ((Get-CurrentSsid) -cne $settings.targetSsid) {
        $outcome.Code='WIFI_CHANGED_BEFORE_AUTH'
        Write-Status 'Wi-Fi changed before authentication; no authentication attempted.'
        exit 1
    }
    if ($online) {
        Write-Status 'Campus Wi-Fi online; no authentication needed.'
        $outcome.Code = 'ALREADY_ONLINE'; $outcome.Success = $true
        exit 0
    }

    # One recovery attempt per invocation; the daily schedule is set by install-task.ps1.
    Write-Status 'Offline; starting school account authentication.'
    $portalUri = if ($settings.portal) { [Uri]$settings.portal } else { $null }
    $auth = & (Join-Path $PSScriptRoot 'campus-auth.ps1') -DataDirectory $DataDirectory -PortalUri $portalUri
    $outcome.AuthenticationAttempted = [bool]$auth.Attempted
    $outcome.AuthenticationCode = [string]$auth.Code
    foreach($field in @('ErrorType','ErrorStage','ErrorCode','StartupAttempts')) {
        if($null -ne $auth.$field) { $outcome[$field]=$auth.$field }
    }
    if($auth.ErrorStage) { Write-Status ('Authentication runtime error: '+$auth.ErrorStage+'; '+$auth.ErrorCode) }
    $online = Test-Internet
    if ((Get-CurrentSsid) -cne $settings.targetSsid) {
        $outcome.Code='WIFI_CHANGED_DURING_AUTH'
        Write-Status ('Campus Wi-Fi changed during recovery; authentication status: ' + $auth.Code)
        exit 1
    }
    if ($online) {
        Write-Status ('Online after recovery; authentication status: ' + $auth.Code)
        $outcome.Code = 'ONLINE_AFTER_AUTH'; $outcome.Success = $true
        exit 0
    }
    Write-Status ('Still offline; authentication status: ' + $auth.Code)
    if ($auth.Code -match '^[A-Z_]+$') { $outcome.Code = [string]$auth.Code }
    exit 1
} catch {
    Write-Status ('Recovery error: ' + $_.Exception.GetType().Name)
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    # Report this invocation, including a mutex skip, rather than an older log.
    if ($StructuredResult) { $outcome | ConvertTo-Json -Compress | Write-Output }
}
