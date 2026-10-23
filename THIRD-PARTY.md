# 第三方组件与参考

CampusLuma 自身源码使用 MIT 许可证，根目录和 `engine/LICENSE` 保留原版权声明。第三方软件不因随包分发而变为本项目许可证。

| 组件 | 版本 / 许可证 | 用途 |
| --- | --- | --- |
| Playwright Core | 1.64.0 / Apache-2.0 | 使用本机 Edge 操作门户 |
| ddddocr-node | 2.3.0 / MIT | 本地图片验证码识别 |
| onnxruntime-node | 1.15.1 / MIT | OCR 推理的传递依赖 |
| iconv-lite | 0.7.3 / MIT | 陕师大 GB2312 表单编码 |
| safer-buffer | 2.1.2 / MIT | 编码组件的传递依赖 |
| Node.js | 见包内版本清单 / MIT 及其第三方声明 | Windows 包内的独立运行时 |
| Microsoft Edge、.NET Framework、Windows PowerShell | 各自厂商条款 | 使用系统已安装组件，不随包分发 |

直接依赖和全部传递依赖以 [engine/package-lock.json](engine/package-lock.json) 为准。依赖自身的 `LICENSE`、`NOTICE`、`ThirdPartyNotices` 等文件保留在 Windows 包的 `engine/node_modules` 中；Node 的完整声明在 `runtime/NODE-LICENSE.txt`。源码仓库不提交 `node_modules` 或 Node 二进制。

官方上游：[Playwright](https://github.com/microsoft/playwright)、[ddddocr-node](https://github.com/renhaoyeh/ddddocr-node)、[ONNX Runtime](https://github.com/microsoft/onnxruntime)、[iconv-lite](https://github.com/pillarjs/iconv-lite)、[Node.js](https://github.com/nodejs/node)。

学校认证页面、学校名称及厂商名称属于各自权利人；仓库不分发学校原始页面、Logo、个人抓包或账户资料。其他校园网项目只作为公开行为与设计参考，见 [来源与取舍](docs/REFERENCES.md)。
