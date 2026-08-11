# 微信收款监控（iOS 自签 App）

实时监听微信「收款到账语音播报」，识别金额后本地通知 + 上报 AI Hub 网站，并支持用付款单号自动核销充值单。

## 重要前提（iOS 系统限制，务必先看）

1. **iOS 不允许第三方 App 读取微信的通知/界面**，也没有「操作其他 App」的权限。本方案通过 **监听收款语音播报**（收款方手机扬声器外放）实现收款检测，这是个人收款监控唯一可行的 iOS 路线。
2. **后台无法做到系统级 100% 常驻**。本 App 采用「后台音频（无声保活）+ 麦克风采集」组合，锁屏/切后台可长时间运行，但 iOS 在极端情况（低电量、用户手动清除、系统压力）仍可能终止进程；启动监听后建议：
   - 连接电源（监听很耗电）
   - 设置 → 电池 → 低电量模式 关闭
   - 设置 → 通用 → 后台App刷新 保持开启
3. **自签证书**：免费 Apple ID（个人）签名有效期 **7 天**，到期需重装；开发者证书（¥688/年）签名有效期 1 年。
4. 播报识别成功率取决于：微信语音播报已开启、手机音量、环境噪音。收到钱后若 App 未弹通知，可看「运行日志」。

## 工作流程

```
付款方扫码 → 收款方微信语音播报「微信支付收款 12.00 元」
   → 本 App 后台麦克风采集 + 语音识别解析金额
   → 本地通知 + POST /api/recharge/detect 上报（需已绑定账号）
   → 付款方在网站充值弹窗提交付款单号（状态：待审核）
   → 收款方在本 App「检测记录 → 用付款单号核销」粘贴同一单号
   → 服务器校验：单号属于该账号 + 金额与 1 小时内语音检测一致
   → 自动到账（开发者开启自动核销时）或提示等待开发者确认
```

## 微信端设置（收款方手机）

微信 → 我 → 服务 → 收付款 → 二维码收款 → 右上角「...」/收款小账本 → 开启 **收款到账语音提醒**。
（或：微信 → 我 → 设置 → 通用 → 辅助功能 → 收款到账语音提醒）

## 构建与签名（需要 Mac + Xcode）

```bash
cd wechat-collect-ios
open WeChatMonitor.xcodeproj
```

1. Xcode 中选中 Target「收款监控」→ Signing & Capabilities
2. Team 选择你的 Apple ID（免费个人账号即可，首次需在 Xcode 添加账号）
3. 修改 `PRODUCT_BUNDLE_IDENTIFIER` 为你的唯一 ID（如 `com.yourname.wechatmonitor`），免费账号 Bundle ID 必须唯一
4. 连接 iPhone，选择真机运行（免费账号**不能**签名发布到 App Store，但可真机运行）
5. 若需要 IPA：Product → Archive（需要开发者证书）或用 `xcodebuild -project WeChatMonitor.xcodeproj -scheme WeChatMonitor -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build` 产出的 .app 用 `zip -r app.ipa Payload/收款监控.app` 打包，再用 AltStore / 爱思助手等自签安装

### 免费账号 7 天续签
安装后到期需重新签名安装，历史检测记录存在本机 UserDefaults 不会丢失。

## Windows 电脑构建（无需 Mac）

Xcode 只能在 macOS 运行，但可以完全用 GitHub 免费云服务编译：

1. 在 GitHub 新建一个**公开**仓库，把本目录（含 `.github/workflows/ios-build.yml`）推送上去（改代码请保持 `.swift`、`Info.plist`、`project.pbxproj` 同步修改）。
2. 仓库 → Actions 页 → 左边「iOS Build (IPA)」→ 右侧「Run workflow」→ 绿色按钮，等待约 5 分钟自动编译。
3. 编译完成后，Actions 运行页底部 **Artifacts** 区域下载 `WeChatMonitor-ipa.zip`，解压得到 `WeChatMonitor.ipa`。
4. Windows 安装 **Sideloadly**（https://sideloadly.io ，Windows 版），iPhone 连电脑（装好 iTunes）。
5. Sideloadly 中：IPA 选刚下载的 `WeChatMonitor.ipa`，Apple ID 填你的免费账号，点 Start。
6. iPhone 上 设置 → 通用 → VPN 与设备管理 → 信任开发者证书，即可打开 App。

> 注意：免费账号签名的 App **7 天过期**，到期在 Sideloadly 里重新拖一次同款 IPA 重签即可（无需重新编译）；期间请勿在 iPhone 上删除证书。每次改完代码 push 后重新 Run workflow 即可获得新 IPA。

## App 内使用

1. 打开 App → 设置区「绑定账号」→ 去网站「个人主页 → 收款监控 App 绑定」生成 6 位绑定码 → 输入绑定
2. 点击「开始监听」，授予麦克风 + 语音识别权限
3. 保持微信播报开启，正常收款即可
4. 收款后 App 弹通知；付款方提交单号后，在 App 检测记录里点「用付款单号核销」输入单号提交

## 服务器接口（已部署）

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/app/bind-code` | GET | 登录用户生成一次性绑定码（10 分钟） |
| `/api/app/bind` | POST | 绑定码换长期令牌（90 天） |
| `/api/recharge/detect` | POST | App 上报检测到的金额 |
| `/api/recharge/verify` | POST | 单号核销（金额匹配则到账/标记核验通过） |
| `/api/dev/recharge/autoverify` | GET/POST | 开发者开关自动核销 + 金额上限 |

安全模型：单号与账号绑定 + 金额必须与收款端语音检测一致 + 单号防重复 + 60 分钟窗口，无法凭空刷积分。

## 目录结构

```
WeChatMonitor.xcodeproj/   Xcode 工程
WeChatMonitor/
  AppMain.swift            入口 + 前后台生命周期
  BackgroundCoordinator.swift  后台刷新任务（被清理后尽量复活）
  MonitorEngine.swift      麦克风采集 + 静音保活 + 语音识别 + 去重 + 上报
  APIClient.swift          网站接口
  Views.swift              界面（状态/引导/绑定/检测记录/核销/日志）
  Info.plist               后台音频/麦克风/语音识别权限声明
  Assets.xcassets
```

> 免责声明：本工具用于个人收款核对，请勿用于违法违规用途。
