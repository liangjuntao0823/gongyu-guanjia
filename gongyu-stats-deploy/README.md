# gongyu-stats 云函数部署环境（云电脑）

公寓管家「云端后台」的腾讯云 SCF 云函数 **gongyu-stats** 的一键部署工具。

## 现状（2026-10-25 已配置完成）

- **云函数**：`gongyu-stats`（ap-hongkong，Python3.9，Active）
- **后台地址**：https://1511251056-csopw5c0jd.ap-hongkong.tencentscf.com
- **桶**：`fangyuan88-1511251056`（ap-hongkong）
- **密钥**：已把云函数环境变量的 SECRET_ID / SECRET_KEY 更新为用户提供的最新密钥（2026-10-25），桶读写验证通过；**密钥不写入本仓库**，部署时经环境变量注入
- **后台口令**：桶内 `h/_admin_pwd.json` = `88888888`（App 设置页改过后以桶内为准，云函数优先读桶）

## 桶内目录结构（备份存放位置，用户备份从这里读写）

```
h/                      房源共享区：h/<房号>/ 媒体、h/_houses.json 账本、h/_ops.json 操作日志
statistics/             访问统计
users/<用户名>/         用户私有区
    backups/            云端备份（快速备份 zip / 全量备份 zip）
    shares/             分享 H5 页面、视频首帧图、封面
    qrcode.jpg          名片二维码
    share_records.json  分享记录
    media/              全量备份的媒体镜像（按 sha1 去重）
```

> 备份路径 = `users/<用户名>/backups/`（如 `users/涛/backups/`）。旧路径 `backups/<用户名>/` 仅兼容读取。

## 部署脚本用法

```bash
cd gongyu-stats-deploy
export TENCENT_SECRET_ID="AKIDxxxxxxxxxxxxxxxxxx"
export TENCENT_SECRET_KEY="xxxxxxxxxxxxxxxxxxxxxxxx"
python3 deploy.py
```

脚本自动：解包 `AgentTool/云端部署包.zip` → 打包 zip → 更新函数代码 → 更新环境变量（桶/地域/密钥/口令）。

**密钥安全**：密钥不要写进代码文件；用环境变量传入，或写入本目录 `.env`（已被 .gitignore 排除，见下）。

## 常用操作

| 操作 | 方法 |
| --- | --- |
| 后台打不开/连不上 | 先 `curl "https://1511251056-csopw5c0jd.ap-hongkong.tencentscf.com/?act=admin"` 看是否返回页面；不行就重跑 deploy.py |
| 改了 app.py/admin.html 重新部署 | 打包进 `AgentTool/云端部署包.zip` 后跑 `python3 deploy.py` |
| 部署后 App 端 | 设置 → 云函数后台 → 「刷新网页后台缓存」 |
| 换桶/换密钥 | 改环境变量 BUCKET / TENCENT_SECRET_ID / TENCENT_SECRET_KEY 后重跑 |

## 依赖

- Python 3.10+
- `pip install tencentcloud-sdk-python-scf cos-python-sdk-v5`（deploy.py 会自动装 scf SDK）
