param([Parameter(Mandatory)][string]$InterfaceName)
$ErrorActionPreference = 'Stop'
$adapter = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.Name -ceq $InterfaceName } | Select-Object -First 1
if (-not $adapter) { throw 'Configured Wi-Fi interface is not present.' }
if (-not ('XtuCampusNativeWifiScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class XtuCampusNativeWifiScan {
    [DllImport("wlanapi.dll")]
    static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")]
    static extern uint WlanScan(IntPtr handle, ref Guid guid, IntPtr ssid, IntPtr ie, IntPtr reserved);
    [DllImport("wlanapi.dll")]
    static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
    public static uint Refresh(Guid guid) {
        uint negotiated;
        IntPtr handle;
        uint code = WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle);
        if (code != 0) return code;
        try {
            code = WlanScan(handle, ref guid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            // WlanScan is asynchronous. Wait once for the documented 4-second
            // scan completion window before reading available networks.
            if (code == 0) Thread.Sleep(4000);
            return code;
        } finally { WlanCloseHandle(handle, IntPtr.Zero); }
    }
}
'@
}
[XtuCampusNativeWifiScan]::Refresh([guid]$adapter.Id)
