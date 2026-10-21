# 公寓管家

「公寓管家」= 租房管家（经营工具）+ 房源管家（获客分享）合体版。

一个 App 搞定中介/二房东的全部日常：

| 板块 | 功能 |
| --- | --- |
| 工作台 | 待办、未收租提醒、租期到期提醒、快捷操作 |
| 成交 | 成交记录、杂项收入 / 杂项支出、退租 |
| 收租 | 收租计划、水电结算、账单模板（微信分享图 / Excel 导出） |
| 包租 | 包租房、付款计划、水电及付款提醒 |
| 汇总 | 收入 / 支出 / 净收入统计 |
| 房源 | 房源库、实拍图视频、微信卡片分享、H5 脱敏页、腾讯云 COS 远程配置 |
| 设置 | 备份恢复、数据同步迁移、自动备份、水电单价、自定义铃声 |

## 基本信息

- 应用 ID：`com.gj.tg`（全新独立 ID，可与旧 App 并行安装）
- 应用名称：公寓管家
- 版本：v1.1（build 2）
- 图标：沿用房源管家 App 图标
- 系统要求：iOS 17.0+
- 无第三方依赖：COS 上传为手写签名实现（CryptoKit），全系统框架
- 应用组：`group.com.gj.tg.shared`（v1.1 起与旧应用彻底隔离，桌面小组件同步数据互不相通）

## 数据与还原

- **租房管家经营数据**：默认 SwiftData 存储；通过「设置 → 备份数据 / 恢复数据」导出导入 JSON 备份。
- **房源管家数据**：独立存放在 `Documents/备份/` 文件夹（housekeeper.store + Media/ 图片视频 + 名片二维码 + 分享缓存）；在 iOS「文件」App 里复制整个「备份」文件夹即可备份，放回即可还原。
- 两个数据体系完全隔离，互不影响。

## 构建

GitHub Actions 自动构建（`.github/workflows/build.yml`）：

- 推送 `main` 分支（触发路径 `AgentTool/**` 等）自动执行 xcodebuild Release 构建
- ad-hoc 签名（巨魔 TrollStore / 证书均可安装）
- 产物：`公寓管家<版本>.ipa`，随 GitHub Release 发布（`GongYuGuanJia-v<版本>.ipa`）
- Release Tag：`v<版本>`，例如 `v1.0`

## 本地构建

```bash
xcodebuild -project AgentTool.xcodeproj -scheme AgentTool -configuration Release \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build
```

## 版本迭代

见 [`版本更新记录.md`](版本更新记录.md)。
