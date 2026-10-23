# 参与贡献

欢迎反馈问题、完善说明、增加隔离测试、帮助校内验收和提交学校规则。日常开发以本仓库 `main` 为基础，请先查看 [学校状态](docs/SCHOOLS.md) 和已有 Issues。

## 本地开发

1. 安装 Windows 10/11 x64、.NET Framework 4.8、Windows PowerShell 5.1、Node.js 24 和 Edge。
2. Fork / clone 后执行 `npm.cmd --prefix engine ci`，再执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1`。
3. 保留根目录 `development.mode`。它使开发程序使用 `CampusLuma-Dev` 数据和 `CampusLuma Development` 任务，不覆盖已安装正式版。
4. 运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-offline.ps1`。涉及窗口、任务调度时，在桌面会话中运行 `tests/run-tests.ps1`。

编译生成的 exe / dll、`artifacts`、本地数据和依赖目录均已忽略。中文 PowerShell 脚本需使用 UTF-8 BOM，让系统 PowerShell 5.1 正确读取；构建会规范这些脚本编码。

## 提交修改

- 一次 PR 解决一个清楚的问题，说明改动理由、验证方式和限制。
- 修复调度、密码保存、入口信任或失败分类时，增加能复现原问题的测试。
- 不为视觉微调增加大量重复测试；界面保持简洁，正常状态灰黑色，错误红色。
- 不在应用内直接写入个人 SSID、账号、路径、MAC 或会话地址；测试使用虚构数据。
- 不读取浏览器保存的密码或历史，不记录密码及完整网络报文。
- 不引入持续扫描、自动下线其他设备、自动控制 VPN 等与当前边界不同的行为，除非先在 Issue 中讨论清楚。

所有提交者都应理解并验证自己提交的代码，包括借助 AI 编写的代码。请标明尚未实际测试的部分，不将模拟结果写成校内验收通过。

## 构建发布包

在干净、已提交的源码目录中，先完成依赖安装和测试，再执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1`。脚本读取 `VERSION`，只复制程序、公开规则和依赖，保留第三方许可证，生成文件清单和 ZIP 的 SHA-256；输出在 `artifacts/releases`。它不会创建联网任务或把本地配置带入包中。

对外发布前，执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-release.ps1 -Archive <ZIP路径>`，从全新解压目录检查清单、依赖、后台 Edge、本地 OCR 和空账号窗口，不进行真实认证；发布标签指向清单的 `SourceCommit`，预览包保留 `development.mode`。不要手动将已经使用过的安装目录压缩上传。

## 添加学校

先按 [适配指南](docs/ADAPTERS.md) 收集可公开的官方来源。协议核心与学校规则分开；新规则默认禁用，逐校、逐校区验收后再讨论开放。不要向不拥有的账号尝试密码，不扫描学校地址段，不绕过学校业务和认证限制。

## 问题与安全报告

普通故障、功能建议和学校适配使用 [Issue 表单](https://github.com/Orangaigai/CampusLuma/issues/new/choose)。先导出脱敏反馈，不附个人配置或 HAR。涉及凭据泄露、可信来源绕过等安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

提交贡献表示你有权提供这些内容，并同意按本项目 MIT 许可证发布；第三方代码应保留必要声明，不复制没有明确授权的实现。
