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
    /// v2.11：当前正在抓取的页码（跨注入保留；翻页由 Swift 驱动整页导航，页码不再由 JS 硬编码）
    private var pendingPage = 1
    /// v2.11：防重入——本页 hasNext 已处理过就不再重复翻页（避免 didFinish 重复注入导致翻过头）
    private var hasHandledNext = false
    /// 跨 page 消息累积（每次抓取前清空；@MainActor 单例，无并发问题）
    private var pendingHouses: [AjkHouse] = []
    private var pendingOverview: AjkOverview = .empty
    /// v1.91：两步抓取——先工作台首页（神奇分/房产币）再房源列表页
    private var phase = 0                 // 0=工作台概览 1=房源列表
    private var pendingOverviewText: String? = nil
    private static let overviewURL = "https://vip.anjuke.com/user/brokerhomeV2"
    // v2.10：逐步进度回调（每次抓取前设置，完成/失败时清空）
    private var onProgress: ((String) -> Void)?
    // v2.10：活动看门狗——30s 无任何进展才判超时；原来固定 75s 且缺 didFail 回调，网络失败只能干等
    private var watchdog: DispatchWorkItem?

    // MARK: - 公开入口：抓取全部房源（当前登录态）

    func fetchAll(maxPages: Int, onProgress: ((String) -> Void)? = nil) async throws -> FetchResult {
        pendingMaxPages = maxPages
        pendingHouses = []
        pendingOverview = .empty
        pendingOverviewText = nil
        phase = 0
        pendingPage = 1
        hasHandledNext = false
        self.onProgress = onProgress
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
            // v1.91：先加载工作台首页抓神奇分/房产币，再进房源列表抓卡片
            let url = URL(string: Self.overviewURL)!
            wv.load(URLRequest(url: url))
            self.progress("正在打开安居客后台…")
            // v2.10：活动看门狗——30s 无任何进展（未加载完成/未回传数据）才判超时，
            // 网络失败/页面卡死不再干等固定 75s；每有进展重新计时
            self.armWatchdog(seconds: 30)
        }
    }

    // MARK: - 进度与看门狗（v2.10）

    private func progress(_ text: String) {
        onProgress?(text)
    }

    /// 取消旧看门狗并重新计时（每次有进展都调用）
    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.finish(error: "页面加载超时，请检查网络后重试")
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - 导航回调

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoadCount += 1
        // v2.10：页面已加载完成，但脚本等待/回传可能较久，看门狗放宽到 45s
        armWatchdog(seconds: 45)
        // SPA 异步渲染 + 登录判定后注入抓取脚本；phase 0=工作台概览，1=房源列表
        // v2.11：列表页每次整页导航完成后按当前 pendingPage 注入「只收集本页」的脚本，
        // 翻页由 Swift 用 hasNext 返回的 href 驱动 load，不再由 JS click（click 会销毁脚本上下文导致中断/超时）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.phase == 0 {
                self.progress("正在读取工作台概览（神奇分/房产币）…")
                self.runOverviewScrape(on: webView)
            } else {
                self.progress("正在解析第 \(self.pendingPage) 页…")
                self.runScrape(on: webView, page: self.pendingPage)
            }
        }
    }

    // MARK: - 导航失败立即报错（v2.10：原来缺这两个回调，页面加载失败时 didFinish 永不触发，只能干等超时）

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard continuation != nil else { return }
        finish(error: "页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard continuation != nil else { return }
        finish(error: "页面加载失败（网络异常或平台拦截）：\(error.localizedDescription)")
    }

    // MARK: - 注入 JS：收集工作台概览文本（神奇分/房产币）

    private func runOverviewScrape(on webView: WKWebView) {
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // v2.10：登录页快速识别——URL 进 passport/登录，或标题含「登录」且正文含登录引导词；
          // 命中立即回传 needLogin，不再走完整两步流程后才提示（原来要干等很久）
          var hrefNow = location.href || '';
          var titleNow = norm(document.title || '');
          var bodyNow = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          if (hrefNow.indexOf('passport') >= 0 || hrefNow.indexOf('/login') >= 0 ||
              (titleNow.indexOf('登录') >= 0 && (bodyNow.indexOf('请登录') >= 0 || bodyNow.indexOf('扫码登录') >= 0 || bodyNow.indexOf('账号密码登录') >= 0))) {
            window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'needLogin'}));
            return;
          }
          // 等待 SPA 渲染出神奇分/房产币（最多 12 秒）
          var waited = 0;
          while (waited < 12000) {
            var bt = (document.body && (document.body.innerText || document.body.textContent)) || '';
            if (bt.indexOf('神奇分') >= 0 && (bt.indexOf('总分') >= 0 || bt.indexOf('房产币') >= 0)) break;
            await sleep(500); waited += 500;
          }
          var bodyText = norm(document.body.innerText || document.body.textContent);
          window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'overview', text: bodyText}));
        })();
        void 0;
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                Task { @MainActor in
                    self.finish(error: "脚本执行失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 注入 JS：收集原始文本（解析放 Swift）
    // v2.11：脚本只「收集当前页 + 探测下一页 href」，翻页由 Swift 整页导航（load href）驱动。
    // 原实现是 JS 内循环 next.click()——安居客「下一页」是整页跳转链接，点击后脚本上下文被导航销毁，
    // 循环中断、done 永不发出，只能靠看门狗 30s 误报「网络超时」；且每次 didFinish 重新注入又从第 1 页重来。

    private func runScrape(on webView: WKWebView, page: Int) {
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // 登录页快速识别（翻页后可能被登出/跳登录）
          var hrefNow = location.href || '';
          var titleNow = norm(document.title || '');
          var bodyNow = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          if (hrefNow.indexOf('passport') >= 0 || hrefNow.indexOf('/login') >= 0 ||
              (titleNow.indexOf('登录') >= 0 && (bodyNow.indexOf('请登录') >= 0 || bodyNow.indexOf('扫码登录') >= 0 || bodyNow.indexOf('账号密码登录') >= 0))) {
            window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'needLogin'}));
            return;
          }
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
          // v2.11：JS 内 seen 只防「本页内」文本节点重复；跨页重复由 Swift 按编号去重
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
          window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'page', overview: bodyText, cards: cards, page: \(page)}));
          // 探测「下一页」链接（不点击）：取第一个文本为「下一页」的 <a href>；disabled/无有效 href = 没有下一页
          var nextHref = '';
          var links = document.querySelectorAll('a, span, div, button');
          for (var i = 0; i < links.length; i++) {
            var tx = norm(links[i].textContent);
            if (tx !== '下一页') continue;
            var cls = links[i].getAttribute('class') || '';
            if (cls.indexOf('disabled') >= 0 || links[i].getAttribute('aria-disabled') === 'true') break;
            var h = links[i].getAttribute('href') || '';
            if (h && h !== '#' && h.indexOf('javascript') < 0) {
              nextHref = new URL(h, location.href).href;
            }
            break;
          }
          window.webkit.messageHandlers.ajkScrape.postMessage(JSON.stringify({type:'hasNext', href: nextHref}));
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
        cancelWatchdog()
        webView?.stopLoading()
        webView = nil
        onProgress = nil
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

        // v2.10：逐步进度——每收到一条消息都视为有进展，看门狗重新计时
        armWatchdog(seconds: 30)

        if type == "progress" {
            if let text = dict["text"] as? String { progress(text) }
            return
        }

        if type == "needLogin" {
            // v2.10：打开页面即被跳转/显示登录页 → 立即提示先登录，不再走完整两步流程后才报
            guard let c = continuation else { return }
            continuation = nil
            cancelWatchdog()
            userContentController.removeScriptMessageHandler(forName: "ajkScrape")
            webView?.stopLoading()
            webView = nil
            onProgress = nil
            var result = FetchResult()
            result.needLogin = true
            c.resume(returning: result)
            return
        }

        if type == "overview" {
            // 工作台首页文本（神奇分/房产币）已拿到 → 切到房源列表页继续
            pendingOverviewText = (dict["text"] as? String) ?? ""
            phase = 1
            let url = URL(string: AjkStore.shared.settings.baseURL) ?? URL(string: "https://vip.anjuke.com/zufang/main/zufang/subpages/allHouse")!
            progress("正在打开房源列表页…")
            webView?.load(URLRequest(url: url))
            return
        }

        if type == "page" {
            let overview = (dict["overview"] as? String) ?? ""
            let page = (dict["page"] as? Int) ?? 1
            progress("正在解析第 \(page) 页…")
            // v2.11：本页已收集完成，允许新一轮翻页（防 didFinish 重复注入导致翻过头）
            hasHandledNext = false
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
            // v1.91：概览 = 工作台文本（神奇分/房产币）+ 列表页文本（今日点击/推广/端口/套餐），合并后解析
            let combinedOverview = [pendingOverviewText, overview].compactMap { $0 }.joined(separator: " ")
            let parsed = AjkParser.parse(overview: combinedOverview, cards: cardTexts, covers: covers, page: page)
            if !parsed.houses.isEmpty {
                // v2.9（新增2）：只保留利保米兰公馆房源（community/title 含「米兰」）；
                // 若一条都没匹配（用户在设置里改了 URL 抓其他小区）则原样保留，避免整页误删
                let milan = parsed.houses.filter { $0.community.contains("米兰") || $0.title.contains("米兰") }
                pendingHouses += (milan.isEmpty ? parsed.houses : milan)
                pendingOverview = parsed.overview
            }
            return
        }

        // v2.11：翻页探测结果——有下一页 href 且未达上限 → Swift 整页导航翻页；否则正常结束
        if type == "hasNext" {
            let href = (dict["href"] as? String) ?? ""
            if hasHandledNext { return }
            hasHandledNext = true
            if !href.isEmpty, pendingPage < pendingMaxPages {
                pendingPage += 1
                progress("正在打开第 \(pendingPage) 页…")
                if let url = URL(string: href) {
                    webView?.load(URLRequest(url: url))
                    return
                }
            }
            finishSuccess()
            return
        }

        if type == "done" {
            finishSuccess()
            return
        }
    }

    // MARK: - 正常收尾（v2.11：done 与 hasNext 无下一页共用）

    private func finishSuccess() {
        guard let c = continuation else { return }
        continuation = nil
        cancelWatchdog()
        userContentController.removeScriptMessageHandler(forName: "ajkScrape")
        webView?.stopLoading()
        webView = nil
        onProgress = nil
        var result = FetchResult()
        // v2.9（新增2）：跨页全局去重——同一套房源编号只保留首个，消除「同套重复」展示
        var seen = Set<String>()
        var deduped: [AjkHouse] = []
        for h in pendingHouses where seen.insert(h.number).inserted {
            deduped.append(h)
        }
        result.houses = deduped
        result.overview = pendingOverview
        // 登录态判定：一张卡片都没抓到且概览不含房源特征 → 可能未登录
        if result.houses.isEmpty && result.overview == .empty {
            result.needLogin = true
        }
        c.resume(returning: result)
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
