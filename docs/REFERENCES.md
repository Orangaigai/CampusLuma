# 调研与设计取舍

整理日期：2026-10-23。以下链接为参考资料，不代表对方项目为本项目的学校适配或可靠性背书。未复制无许可证实现，也未把参考项目的测试结果视为自己的验收。

## 开源项目的组织

参考 [GitHub 仓库实践](https://docs.github.com/en/repositories/creating-and-managing-repositories/best-practices-for-repositories)、[贡献指南说明](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors) 组织 README、许可证、贡献、问题模板和安全报告入口；普通使用说明放前面，内部协议细节另列文档。

[LocalSend](https://github.com/localsend/localsend) 和 [PowerShell](https://github.com/PowerShell/PowerShell) 提供了下载、平台范围、贡献与版本说明分开的结构参考。CampusLuma 采用这一组织思路，保留小项目需要的文档，不引入大型项目的全部流程。

## 校园网项目及真实问题

| 项目 / 公开反馈 | 参考点 | 本项目的取舍 |
| --- | --- | --- |
| [BitSrunLoginGo](https://github.com/Mmx233/BitSrunLoginGo)、[接口地址变化问题 #61](https://github.com/Mmx233/BitSrunLoginGo/issues/61) | 缓存旧网卡地址会造成认证异常 | 明确目标接口，切网前后复核；不宣称已完成所有流量的接口绑定 |
| [bitsrun](https://github.com/BITNP/bitsrun)、[动态入口与外网问题 #48](https://github.com/BITNP/bitsrun/issues/48) | 门户登录状态不代表外网可达，入口参数可能变化 | 每轮发现入口，并独立验证外网 |
| [drcom-generic](https://github.com/drcoms/drcom-generic) | 同一厂商存在不同协议与学校变种 | 协议核心和每校规则分开，避免“填任意网址即可用” |
| [GDOU-net-login](https://github.com/QianyeSu/GDOU-net-login) | 原生窗口、隐私和排障说明 | 保持 Windows 小窗口，清楚说明本地凭据与路由限制 |
| [YSU 工具及状态显示反馈](https://github.com/wide-sky-with-me/ysu_net/issues/1) | 真实连通性与界面状态可能不同步 | 界面核对本次结果及系统任务，不拿旧成功代替今天的执行 |
| [XTUWebAuth](https://github.com/lunahaoyueli/XTUWebAuth)、[xtu-login](https://github.com/BlackJulySnow/xtu-login) | 湘大网页认证的公开流程线索 | 以当前门户和本机未认证实测为准，不能从旧项目存在推定现在可用 |

这些反馈来自特定版本和网络环境，不表示所有人都有同样问题。项目采用有限执行和故障分类，保留手动连接，暂不加入常驻轮询、自动关闭 VPN、账号踢线、跨平台前端或自动升级。

## 近期路线

1. 完善公开预览版的安装、升级和诊断文档，持续回归湘大核心路径。
2. 对登录后补连做真实重启后的校内验收，再考虑推广。
3. 等待陕西师大长安、湖南科大和湖南师大的本人校内反馈，逐项修复并记录范围。
4. 有明确需求、公开证据和验收条件后再开放其他学校。
