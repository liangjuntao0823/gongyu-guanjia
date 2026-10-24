#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gongyu-stats 云函数一键部署脚本（云电脑 / 任意 Linux/macOS 可用）

用途：公寓管家「云端后台」的腾讯云 SCF 云函数（gongyu-stats）更新部署。
当 AgentTool/云端部署包.zip 里的 app.py / admin.html 有改动时，跑本脚本即可把
新代码 + 环境变量推送到线上函数，无需登录网页控制台。

用法：
    python3 deploy.py

读取环境变量（也可直接改下面 DEFAULTS）：
    TENCENT_SECRET_ID   腾讯云 API 密钥 ID
    TENCENT_SECRET_KEY  腾讯云 API 密钥 Key
    SCF_REGION          函数地域（默认 ap-hongkong）
    FUNCTION_NAME       函数名（默认 gongyu-stats）
    BUCKET              桶名（默认 fangyuan88-1511251056）
    COS_REGION          桶地域（默认 ap-hongkong）
    PASSWORD            后台口令（默认 12345678；注意若桶内 h/_admin_pwd.json 已存在，线上以桶内为准）

依赖：pip install tencentcloud-sdk-python-scf（自动尝试安装）
"""
import base64
import io
import os
import sys
import zipfile

DEFAULTS = {
    "BUCKET": "fangyuan88-1511251056",
    "COS_REGION": "ap-hongkong",
    "SCF_REGION": "ap-hongkong",
    "FUNCTION_NAME": "gongyu-stats",
    "PASSWORD": "12345678",
}

HERE = os.path.dirname(os.path.abspath(__file__))
PKG_SRC = os.path.join(os.path.dirname(HERE), "AgentTool", "云端部署包.zip")
PKG_DIR = os.path.join(HERE, "pkg")


def ensure_sdk():
    try:
        import tencentcloud  # noqa
    except ImportError:
        print("[deploy] 正在安装 tencentcloud-sdk-python-scf …")
        os.system(f"{sys.executable} -m pip install -q tencentcloud-sdk-python-scf")


def prepare_pkg():
    """解包 AgentTool/云端部署包.zip 到 pkg/（SCF 要求 zip 根 = 函数代码根：app.py/admin.html/scf_bootstrap/依赖目录）"""
    if not os.path.isfile(PKG_SRC):
        sys.exit(f"[deploy] 找不到部署包：{PKG_SRC}")
    if os.path.isdir(PKG_DIR):
        import shutil
        shutil.rmtree(PKG_DIR)
    with zipfile.ZipFile(PKG_SRC) as z:
        z.extractall(PKG_DIR)
    print(f"[deploy] 部署包已解包：{PKG_DIR}")


def build_zip(src_dir):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(src_dir):
            for f in files:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, src_dir)
                z.write(full, rel)
    return buf.getvalue()


def main():
    ensure_sdk()
    sid = os.environ.get("TENCENT_SECRET_ID", "")
    skey = os.environ.get("TENCENT_SECRET_KEY", "")
    if not sid or not skey:
        sys.exit("[deploy] 缺少密钥：设置环境变量 TENCENT_SECRET_ID / TENCENT_SECRET_KEY（或用 --set-key 写入 .env 见 README）")
    prepare_pkg()
    zip_bytes = build_zip(PKG_DIR)
    print(f"[deploy] 打包完成：{len(zip_bytes)} 字节")

    from tencentcloud.common import credential
    from tencentcloud.common.profile.client_profile import ClientProfile
    from tencentcloud.common.profile.http_profile import HttpProfile
    from tencentcloud.scf.v20180416 import scf_client, models

    region = os.environ.get("SCF_REGION", DEFAULTS["SCF_REGION"])
    fn = os.environ.get("FUNCTION_NAME", DEFAULTS["FUNCTION_NAME"])
    cred = credential.Credential(sid, skey)
    cp = ClientProfile(httpProfile=HttpProfile(endpoint="scf.tencentcloudapi.com", reqTimeout=30))
    client = scf_client.ScfClient(cred, region, cp)

    # 1) 更新函数代码（zip 整体上传）
    code = models.UpdateFunctionCodeRequest()
    code.FunctionName = fn
    code.ZipFile = base64.b64encode(zip_bytes).decode()
    client.UpdateFunctionCode(code)
    print(f"[deploy] 代码已更新：{fn}")

    # 2) 更新环境变量（桶/地域/密钥/口令）
    def kv(k, v):
        item = models.Variable()
        item.Key = k
        item.Value = v
        return item

    cfg = models.UpdateFunctionConfigurationRequest()
    cfg.FunctionName = fn
    env = models.Environment()
    env.Variables = [
        kv("BUCKET", os.environ.get("BUCKET", DEFAULTS["BUCKET"])),
        kv("REGION", os.environ.get("COS_REGION", DEFAULTS["COS_REGION"])),
        kv("SECRET_ID", sid),
        kv("SECRET_KEY", skey),
        kv("PASSWORD", os.environ.get("PASSWORD", DEFAULTS["PASSWORD"])),
    ]
    cfg.Environment = env
    client.UpdateFunctionConfiguration(cfg)
    print("[deploy] 环境变量已更新（SECRET_ID 已注入）")

    print(f"[deploy] 部署完成 ✅ 后台地址：https://{fn}.{region}.tencentscf.com")
    print("[deploy] 提示：部署后请在 App 设置 → 云端配置 → 云函数后台 → 点「刷新网页后台缓存」")


if __name__ == "__main__":
    main()
