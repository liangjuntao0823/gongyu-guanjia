//
//  AjkWebViewProvider.swift
//  公寓管家 · 安居客经纪人后台数据抓取（v1.85）
//  方案：WKWebView 持久登录态（cookie 保存，登录一次免登）→ 注入 JS 收集页面房源卡片文本与概览 → Swift 解析入库
//  安全边界：仅用户主动触发抓取；只读取用户自己账号页面；绝不做任何写操作（发布/编辑/推广）
//

import Foundation
import WebKit

@MainActor
final class AjkWebViewProvider: NSObject, WKNavigationDelegate {

    static let shared = AjkWebViewProvider()

    /// 抓取结果（Swift 侧解析）
    struct FetchResult {
        var houses: [AjkHouse] = []
        var overview: AjkOverview = .empty
        var needLogin: Bool = false
        var error: String = ""
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var pendingMaxPages = 5
    private var pageLoadCount = 0
    /// 跨 page 消息累积（每次抓取前清空；@MainActor 单例，无并发问题）
    private var pendingHouses: [AjkHouse] = []
    private var pendingOverview: AjkOverview = .empty

    // MARK: - 公开入口：抓取全部房源（当前登录态）

    func fetchAll(maxPages: Int) async throws -> FetchResult {
        pendingMaxPages = maxPages
        pendingHouses = []
        pendingOverview = .empty
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FetchResult, Error>) in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            // 持久数据存储：保存登录 cookie（与电表方案的临时会话相反，这里必须记住登录态）
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            let controller = wv.configuration.userContentController
            controller.add(self, name: "ajkScrape")
            self.webView = wv
            let url = URL(string: AjkStore.shared.settings.baseURL) ?? URL(string: "https://vip.anjuke.com/zufang/main/zufang/subpages/allHouse")!
            wv.load(URLRequest(url: url))
            // 兜底超时（页面卡死/网络异常时恢复，避免无限等待）
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                if let c = self.continuation {
                    self.continuation = nil
                    c.resume(throwing: AjkError.msg("页面加载超时，请检查网络后重试"))
                }
            }
        }
    }

    // MARK: - 导航回调

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoadCount += 1
        // SPA 异步渲染 + 登录判定后注入抓取脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.runScrape(on: webView)
        }
    }

    // MARK: - 注入 JS：收集原始文本（解析放 Swift）

    private func runScrape(on webView: WKWebView) {
        let maxPages = pendingMaxPages
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // 等待 SPA 渲染出房源卡片（最多 15 秒，防抓空）
          var waited = 0;
          while (waited < 15000) {
            if (document.body && document.body.innerText && document.body.innerText.indexOf('编号:') >= 0) break;
            await sleep(500); waited += 500;
          }
          // 收集概览文本
          var bodyText = norm(document.body.innerText || document.body.textContent);
          // 收集房源卡片：找到含"编号:"的文本节点，向上定位到含"预约管理"的容器；
          // v1.90：同时抓取卡片内第一张封面图 URL（缩略图，作为房源封面）
          function collectCards(seenSet) {
            var out = [];
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              var n = walker.currentNode;
              if (n.nodeValue && n.nodeValue.indexOf('编号:') >= 0) {
                var el = n.parentElement;
                var guard = 0;
                var t = '';
                while (el && guard < 8) {
                  t = el.innerText || '';
                  if (t.indexOf('预约管理') >= 0 && t.indexOf('编号:') >= 0) { break; }
                  el = el.parentElement; guard++;
                }
                if (!el) continue;
                var m = t.match(/编号:(\\d+)/);
                if (m && !seenSet.has(m[1])) {
                  seenSet.add(m[1]);
                  var cover = '';
                  var img = el.querySelector('img');
                  if (img) { cover = img.getAttribute('src') || img.getAttribute('data-src') || ''; }
                  out.push({t: norm(t), cover: cover});
                }
              }
            }
            return out;
          }
          var seen = new Set();
          var cards = collectCards(seen);
          var out = {type:'page', overview: bodyText, cards: cards, page: 1};
          window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify(out));
          // 自动翻页：点"下一页"直到没有或达到上限
          var page = 1;
          var maxP = \(maxPages);
          for (var p = 1; p < maxP; p++) {
            var next = null;
            var links = document.querySelectorAll('a, span, div, button');
            for (var i = 0; i < links.length; i++) {
              var tx = norm(links[i].textContent);
              if (tx === '下一页') { next = links[i]; break; }
            }
            if (!next) break;
            var disabled = next.getAttribute('class') || '';
            if (disabled.indexOf('disabled') >= 0 || next.getAttribute('aria-disabled') === 'true') break;
            next.click();
            await sleep(2500);
            // 收集新一页
            var cards2 = collectCards(seen);
            page = p + 1;
            window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'page', overview: bodyText, cards: cards2, page: page}));
            if (cards2.length === 0) break;
          }
          window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'done', total: seen.size, error:''}));
        })();
        void 0;
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                // evaluateJavaScript 回调为非隔离上下文，需切回主 actor 再调用 @MainActor 方法
                Task { @MainActor in
                    self.finish(error: "脚本执行失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(error: String) {
        guard let c = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView = nil
        var result = FetchResult()
        result.error = error
        c.resume(returning: result)
    }
}

extension AjkWebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ajkScrape",
              let body = message.body as? String,
              let dict = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "page" {
            let overview = (dict["overview"] as? String) ?? ""
            let page = (dict["page"] as? Int) ?? 1
            // v1.90：卡片元素为 {t, cover} 对象；兼容旧版纯文本数组
            var cardTexts: [String] = []
            var covers: [String: String] = [:]   // number -> coverURL
            if let objs = dict["cards"] as? [[String: Any]] {
                for obj in objs {
                    let t = (obj["t"] as? String) ?? ""
                    let cover = (obj["cover"] as? String) ?? ""
                    if t.isEmpty { continue }
                    if let m = t.range(of: #"编号:(\d+)"#, options: .regularExpression) {
                        let num = String(t[m]).replacingOccurrences(of: "编号:", with: "")
                        if !cover.isEmpty { covers[num] = cover }
                    }
                    cardTexts.append(t)
                }
            } else if let strs = dict["cards"] as? [String] {
                cardTexts = strs
            }
            let parsed = AjkParser.parse(overview: overview, cards: cardTexts, covers: covers, page: page)
            if !parsed.houses.isEmpty {
                pendingHouses += parsed.houses
                pendingOverview = parsed.overview
            }
            return
        }

        if type == "done" {
            guard let c = continuation else { return }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "ajkScrape")
            webView?.stopLoading()
            webView = nil
            var result = FetchResult()
            result.houses = pendingHouses
            result.overview = pendingOverview
            // 登录态判定：一张卡片都没抓到且概览不含房源特征 → 可能未登录
            if result.houses.isEmpty && result.overview == .empty {
                result.needLogin = true
            }
            c.resume(returning: result)
        }
    }
}

/// 抓取错误
enum AjkError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        }
    }
}
