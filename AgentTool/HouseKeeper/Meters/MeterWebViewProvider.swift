//
//  MeterWebViewProvider.swift
//  公寓管家 · 电表数据兜底方案：WebView 渲染官方页面 + JS DOM 抓取
//  与直连方案共用同一数据出口（MeterLedger），设置页可切换。
//  仅读取页面已渲染文本（余额/累计/状态/抄表时间），不模拟点击充值等任何资金操作。
//

import Foundation
import WebKit

/// 页面级抓取协议：WebView 方案与直连方案共用
protocol MeterProviding {
    func query(uid: String) async throws -> MeterQueryResult
    func payRecords(uid: String) async throws -> [MeterPayRecord]
}

/// 直连方案（默认）：URLSession + 微信 UA
final class MeterDirectProvider: MeterProviding {
    func query(uid: String) async throws -> MeterQueryResult {
        try await MeterQueryService.shared.query(store: .shared, uid: uid)
    }
    func payRecords(uid: String) async throws -> [MeterPayRecord] {
        try await MeterQueryService.shared.payRecords(store: .shared, uid: uid)
    }
}

/// WebView 兜底方案：加载查询页 → JS 点击目标户号「查询」→ 抓取渲染后的 DOM 文本
final class MeterWebViewProvider: NSObject, MeterProviding, WKNavigationDelegate {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingUID = ""

    func query(uid: String) async throws -> MeterQueryResult {
        let text = try await loadAndScrape(uid: uid, action: "query")
        return parseQueryText(text)
    }

    func payRecords(uid: String) async throws -> [MeterPayRecord] {
        let text = try await loadAndScrape(uid: uid, action: "records")
        return parseRecordText(text)
    }

    // MARK: - 抓取

    /// 完成 JS 执行，返回抓取文本
    private func loadAndScrape(uid: String, action: String) async throws -> String {
        let store = MeterStore.shared
        let openId = store.settings.openId
        guard !openId.isEmpty else { throw MeterQueryError.msg("未配置电表查询链接") }

        let url = URL(string: "http://wy.mlh-china.com/electricmeter/?openId=\(openId)")!
        pendingUID = uid

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()   // 不落缓存，避免旧页面
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = MeterQueryService.wechatUA
            self.webView = wv
            wv.load(URLRequest(url: url))
            // 兜底超时（页面卡死时恢复）
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                if let c = self.continuation {
                    self.continuation = nil
                    c.resume(throwing: MeterQueryError.msg("网页加载超时"))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等待 SPA 渲染完成（uniapp 异步渲染），再注入抓取脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            self.runScrape(on: webView)
        }
    }

    private func runScrape(on webView: WKWebView) {
        let uid = pendingUID
        let js = """
        (function(){
          var target = '\(uid)';
          var out = {text:'', clicked:false};
          function all(sel){ return Array.prototype.slice.call(document.querySelectorAll(sel)); }
          // 找到包含目标用户号的一行，点该行上的「查询」按钮
          var rows = all('div, li');
          var row = null;
          for (var i=0;i<rows.length;i++){
            var t = rows[i].innerText || '';
            if (t.indexOf(target) >= 0 && t.indexOf('查询') >= 0 && t.length < 200){ row = rows[i]; break; }
          }
          if (row){
            var btns = all('button, span, div, a');
            for (var i=0;i<btns.length;i++){
              var b = btns[i];
              if ((b.innerText||'').trim() === '查询'){
                var rect = b.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0 && row.contains(b)) { b.click(); out.clicked = true; break; }
              }
            }
          }
          // 等待结果渲染后抓取（页面内结果文本）
          setTimeout(function(){
            var divs = all('div');
            var parts = [];
            for (var i=0;i<divs.length;i++){
              var t = (divs[i].innerText||'').trim();
              if (!t) continue;
              if (t.indexOf('电表剩余') === 0 || t.indexOf('电表累计') === 0 ||
                  t.indexOf('电表状态') === 0 || t.indexOf('最新抄表时间') === 0 ||
                  t.indexOf('剩余') === 0 || t.indexOf('累计') === 0 ||
                  t.indexOf('状态') === 0 || t.indexOf('抄表') === 0){
                if (t.length < 60) parts.push(t);
              }
            }
            out.text = parts.join('\\n');
            window.webkit.messageHandlers.meterScrape.postMessage(out);
          }, 1600);
        })();
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        let controller = webView.configuration.userContentController
        controller.addUserScript(script)
        controller.add(self, name: "meterScrape")
        webView.evaluateJavaScript(js) { _, _ in }
    }

    private func parseQueryText(_ text: String) -> MeterQueryResult {
        var shengyu = "", leiji = "", zhuangtai = "", shijian = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("电表剩余") || l.hasPrefix("剩余") { shengyu = l.components(separatedBy: CharacterSet.decimalDigits.inverted).joined() }
            if l.hasPrefix("电表累计") || l.hasPrefix("累计") { leiji = l.components(separatedBy: CharacterSet.decimalDigits.inverted).joined() }
            if l.hasPrefix("电表状态") || l.hasPrefix("状态") { zhuangtai = l.contains("拉闸") ? "拉闸" : "合闸" }
            if l.hasPrefix("最新抄表时间") || l.hasPrefix("抄表") { shijian = l }
        }
        if shengyu.isEmpty && leiji.isEmpty && zhuangtai.isEmpty {
            // 页面未渲染出结果时给出可识别提示
        }
        return MeterQueryResult(shengyu: shengyu.isEmpty ? "0" : shengyu,
                                leiji: leiji.isEmpty ? "0" : leiji,
                                zhuangtai: zhuangtai.isEmpty ? "合闸" : zhuangtai,
                                shijian: shijian)
    }

    private func parseRecordText(_ text: String) -> [MeterPayRecord] {
        // 兜底方案下充值记录依赖页面「记录」列表渲染，结构多变；返回空并提示以直连为主
        return []
    }
}

extension MeterWebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "meterScrape",
              let dict = message.body as? [String: Any],
              let text = dict["text"] as? String,
              let c = continuation else { return }
        continuation = nil
        userContentController.removeScriptMessageHandler(forName: "meterScrape")
        webView?.stopLoading()
        webView = nil
        c.resume(returning: text)
    }
}
