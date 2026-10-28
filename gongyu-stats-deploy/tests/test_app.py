# -*- coding: utf-8 -*-
"""
gongyu-stats 云函数核心逻辑自动化测试（v1.83 起）
运行：cd gongyu-stats-deploy && python3 -m pytest tests/test_app.py -v
覆盖：口令哈希 / 北京时间 / 域名清洗 / 埋点去重与输入截断 / 删除路径校验 / COS 请求签名与超时参数。
不依赖网络：所有 cos_request 调用点均被 monkeypatch。
"""
import sys
import os
import time
import hashlib
import importlib.util

import pytest

# 用绝对路径加载 pkg/app.py（避免与环境中同名「app」包冲突）
_PKG_APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pkg", "app.py")
_spec = importlib.util.spec_from_file_location("gongyu_app", _PKG_APP)
app = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app)


# ---------- 1. 口令哈希 ----------

class TestSha256:
    def test_known_vector(self):
        assert app._sha256_hex("88888888") == hashlib.sha256(b"88888888").hexdigest()

    def test_utf8_input(self):
        # 中文口令应 UTF-8 编码后哈希（与 App 端一致）
        assert app._sha256_hex("口令中文") == hashlib.sha256("口令中文".encode("utf-8")).hexdigest()


# ---------- 2. 北京时间 ----------

class TestNow:
    def test_is_plus8(self):
        now = app._now()
        utc = now - __import__("datetime").timedelta(hours=8)
        # _now 应等于当前 UTC + 8h（误差 5 秒内）
        assert abs((utc - __import__("datetime").datetime.utcnow()).total_seconds()) < 5


# ---------- 3. 自定义域名清洗 ----------

class TestCleanCd:
    def test_strip_protocol(self):
        assert app._clean_cd("https://share.fangyuan88.site/") == "share.fangyuan88.site"
        assert app._clean_cd("http://abc.com") == "abc.com"

    def test_strip_trailing_slash(self):
        assert app._clean_cd("share.fangyuan88.site///") == "share.fangyuan88.site"

    def test_length_cap(self):
        assert len(app._clean_cd("a" * 200)) == 90


# ---------- 4. 埋点去重 + 输入截断（monkeypatch COS 读写） ----------

class TestTrack:
    @pytest.fixture(autouse=True)
    def patch_cos(self, monkeypatch):
        app._TRACK_DEDUP.clear()
        calls = {"get": [], "put": []}

        def fake_cos(method, path, body=None, content_type=None, url_query=None, timeout=15):
            calls[method.lower()].append((path, timeout))
            if method == "GET":
                return 404, b""
            return 200, b""

        monkeypatch.setattr(app, "cos_request", fake_cos)
        return calls

    def test_first_track_writes(self, patch_cos):
        app.do_track({"room": "1-2334上", "mode": "masked", "ref": "", "uname": "涛"})
        assert patch_cos["put"], "首次埋点应写入统计文件"
        assert patch_cos["get"], "写入前应尝试读取现有统计文件"

    def test_dedup_within_30s(self, patch_cos):
        app.do_track({"room": "1-2334上", "mode": "masked", "ref": "", "uname": "涛"})
        n = len(patch_cos["put"])
        app.do_track({"room": "1-2334上", "mode": "masked", "ref": "", "uname": "涛"})
        assert len(patch_cos["put"]) == n, "30 秒窗口内相同埋点应被去重"

    def test_different_room_not_dedup(self, patch_cos):
        app.do_track({"room": "1-2334上", "mode": "masked", "ref": "", "uname": "涛"})
        app.do_track({"room": "1-2059", "mode": "masked", "ref": "", "uname": "涛"})
        assert len(patch_cos["put"]) == 2

    def test_input_truncation(self, patch_cos):
        app.do_track({"room": "x" * 100, "mode": "y" * 100, "ref": "z" * 500, "uname": "u" * 100})
        # 截断后 room<=40 / mode<=20 / ref<=200 / uname<=40（中文占 1 字符计）
        assert len(patch_cos["put"]) == 1  # 正常写入不抛错

    def test_empty_room_no_write(self, patch_cos):
        app.do_track({"room": "", "mode": "", "ref": "", "uname": "涛"})
        assert not patch_cos["put"], "空房号不应产生写入"


# ---------- 5. 删除路径校验（防路径穿越） ----------

class TestDelPath:
    def test_reject_empty(self):
        assert app.do_admin_del({"key": ""})["ok"] is False

    def test_reject_root(self):
        assert app.do_admin_del({"key": "/"})["ok"] is False

    def test_reject_parent_dotdot(self):
        assert app.do_admin_del({"key": "h/../../etc/passwd"})["ok"] is False

    def test_accept_normal_key(self, monkeypatch):
        monkeypatch.setattr(app, "cos_request", lambda *a, **k: (200, b""))
        r = app.do_admin_del({"key": "h/1-2334上/info.json"})
        assert r["ok"] is True


# ---------- 6. COS 签名与超时参数（monkeypatch urlopen） ----------

class TestCosRequest:
    @pytest.fixture(autouse=True)
    def patch_urlopen(self, monkeypatch):
        captured = {}

        class FakeResp:
            status = 200

            def read(self):
                return b"ok"

        def fake_urlopen(req, timeout=15):
            captured["timeout"] = timeout
            captured["auth"] = req.get_header("Authorization") or ""
            captured["method"] = req.get_method()
            return FakeResp()

        monkeypatch.setattr(app.urllib.request, "urlopen", fake_urlopen)
        return captured

    def test_default_timeout_15(self, patch_urlopen):
        app.cos_request("GET", "/h/x.json")
        assert patch_urlopen["timeout"] == 15

    def test_explicit_timeout_30(self, patch_urlopen):
        app.cos_request("GET", "/", url_query={"prefix": "h/"}, timeout=30)
        assert patch_urlopen["timeout"] == 30

    def test_auth_header_present(self, patch_urlopen):
        app.cos_request("GET", "/h/x.json")
        assert patch_urlopen["auth"].startswith("q-sign-algorithm=sha1")
        assert "q-signature=" in patch_urlopen["auth"]

    def test_chinese_path_signed_raw(self, patch_urlopen):
        # 中文路径应签名原始 path（URL 编码用于发送），至少不抛异常且带签名
        app.cos_request("GET", "/h/1-2334上/info.json")
        assert patch_urlopen["auth"].startswith("q-sign-algorithm=sha1")
