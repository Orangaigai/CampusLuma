param([Parameter(Mandatory)][ValidateSet('hnust','hunnu')][string]$SchoolId)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if(-not (Test-Path -LiteralPath (Join-Path $root 'development.mode'))){throw 'Build trials from the independent development copy only.'}
& (Join-Path $root 'build.ps1')
$rule=Get-Content -LiteralPath (Join-Path $root ('adapters\'+$SchoolId+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
$name='CampusLuma-'+$SchoolId.ToUpperInvariant()+'-Trial-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$stage=Join-Path $root ('artifacts\releases\'+$name)
foreach($directory in @('ui','engine','engine\node_modules','scripts','adapters','runtime','data')){$null=New-Item -ItemType Directory -Path (Join-Path $stage $directory) -Force}
foreach($file in @('CampusLuma.exe','CampusLuma.Core.dll','LICENSE','THIRD-PARTY.md')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage}
Copy-Item -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Destination (Join-Path $stage 'ui')
foreach($file in @('run-once.ps1','run-hidden.vbs','schedule.ps1')){Copy-Item -LiteralPath (Join-Path $root ('scripts\'+$file)) -Destination (Join-Path $stage 'scripts')}
foreach($file in @('campus-network-reconnect.ps1','campus-auth.ps1','campus-auth-provider.ps1','wifi-scan.ps1','auth-provider.mjs','school-rules.mjs','browser-profile.mjs','snnu-preflight.mjs','drcom-profile.mjs','drcom-auth.mjs','connectivity.mjs')){
    Copy-Item -LiteralPath (Join-Path $root ('engine\'+$file)) -Destination (Join-Path $stage 'engine')
}
foreach($dependency in @('iconv-lite','safer-buffer')){Copy-Item -LiteralPath (Join-Path $root ('engine\node_modules\'+$dependency)) -Destination (Join-Path $stage 'engine\node_modules') -Recurse}
$node=(Get-Command node.exe).Source;$version=(& $node --version).Trim()
if($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Invalid Node version.'}
Copy-Item -LiteralPath $node -Destination (Join-Path $stage 'runtime\node.exe')
& (Join-Path $root 'tools\copy-node-license.ps1') -NodeVersion $version -Destination (Join-Path $stage 'runtime\NODE-LICENSE.txt')
[IO.File]::WriteAllText((Join-Path $stage 'development.mode'),($SchoolId+'-trial'),(New-Object Text.UTF8Encoding($false)))
$rule.enabled=$true;$rule.verification='仅用于本人校内验收的试验包，尚未通过校内真实认证。'
$rule|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $stage ('adapters\'+$SchoolId+'.json')) -Encoding UTF8
@{Version=1;Adapter=$SchoolId;School=$rule.name;Ssid=$rule.defaultSsid;Interface='WLAN';Portal=$rule.fallbackPortal;Username='';Service=$null;Mode='custom';Start='07:01';End='23:00';IntervalMinutes=120;Times=@('07:01')}|
    ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $stage 'data\settings.json') -Encoding UTF8
@'
@echo off
start "" "%~dp0CampusLuma.exe" --data-directory "%~dp0data"
'@|Set-Content -LiteralPath (Join-Path $stage 'Start.cmd') -Encoding ASCII
$instructions=@'
# SCHOOL_NAME校园网自动连接 · 试验版

校内真实认证尚未验收。Windows 10/11 x64，自带运行环境；无须安装 Python 或 Node。首次打开不会启用计划。

1. 解压整个目录到可写位置，运行 Start.cmd。本人填写账号、密码、Wi-Fi 名称，选择实际已开通的运营商或校园网。
2. 先在校内点击“立即连接”，确认外网及远控实际可用，再“保存并启用”定时连接。07:01 只是示例，尚未确认本校允许认证的时间。
3. 需电脑开机、已登录且不睡眠。首次测试关闭 TUN；本版直连 HTTP 不使用系统代理，但尚未验收 TUN/全局及多网卡。
4. 到点只执行一次：附近有目标 Wi-Fi 就优先切换，已联网跳过认证；附近没有则保留现有网络并退出。
5. 每次读取当前入口和页面特征。页面版本未识别、服务器配置改变、验证码、运营商不匹配时停止。不会尝试旧接口、轮流猜服务或自动下线设备。
6. 湖科大宿舍需绑定运营商，校园网在部分区域可能仅内网可用。湖南师大须取得本次服务器配置；选择出口须符合本人业务，不根据账号后缀猜测。
7. data 保存设置、DPAPI 加密密码及脱敏结果。反馈错误码、阶段、时间即可；不要提供密码、Cookie、完整请求或加密 URL。分享原始 ZIP，不能转发使用后的 data。
8. 任务前缀为 CampusLuma Trial-SCHOOL_ID，与日用版隔离。停用点“暂停”；移动目录前先暂停，移动后重新保存。

学校门户使用 HTTP，本地 DPAPI 不会给学校 HTTP 链路加密。此工具仅自动完成正常认证，不办理运营商绑定业务。
'@
[IO.File]::WriteAllText((Join-Path $stage '使用说明.md'),$instructions.Replace('SCHOOL_NAME',$rule.name).Replace('SCHOOL_ID',$SchoolId),(New-Object Text.UTF8Encoding($true)))
$files=@(Get-ChildItem -LiteralPath $stage -File -Recurse|ForEach-Object{@{File=$_.FullName.Substring($stage.Length+1);Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$revision=(& git -C $root rev-parse HEAD).Trim()
@{BuildTime=(Get-Date).ToString('o');SourceCommit=$revision;Trial=$true;SchoolId=$SchoolId;RealCampusVerified=$false;NodeVersion=$version;Files=$files}|
    ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $stage 'build-manifest.json') -Encoding UTF8
$zip=$stage+'.zip';Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
@{SchoolId=$SchoolId;Directory=$stage;Archive=$zip;Sha256=(Get-FileHash -LiteralPath $zip).Hash;RealCampusVerified=$false;NodeVersion=$version}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root ('artifacts\'+$SchoolId+'-trial-package.json')) -Encoding UTF8
Write-Output ('Trial archive: '+$zip)
