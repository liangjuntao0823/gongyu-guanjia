//
//  F58WebViewProvider.swift
//  公寓管家 · 58同城找房列表抓取（v2.2 b109）
//  方案：WKWebView 手机 UA 加载 m 站手机版列表（iPhone UA + m 站 URL，58 对手机浏览器风控宽松，
//       实测不弹验证码、key 关键词生效；自动剥离 reform=pcfront——它会转 PC 站并丢弃 key 参数）
//       → 注入 JS 收集第一页房源卡片（标题/缩略图/价格/位置/详情链接）
//       → 再用 iPhone UA 逐个抓详情页补经纪人姓名/公司（m 站详情页实测放行、无验证码；
//         串行 + 小并发 + 超时降级：失败则该条 agent 为空，不阻塞列表）
//  安全边界：仅用户主动触发抓取；只读 58 公开租房列表页与详情页；绝不做任何写操作；只抓第一页约 40 条
//

import Foundation
import WebKit

@MainActor
final class F58WebViewProvider: NSObject, WKNavigationDelegate {

    static let shared = F58WebViewProvider()

    /// 抓取结果
    struct FetchResult {
        var houses: [F58House] = []
        var needCaptcha: Bool = false
        var error: String = ""
        /// 详情页经纪人补抓进度（当前/总数；nil 表示未进入补抓）
        var detailProgress: (current: Int, total: Int)?
    }

    /// 手机 UA：58 对手机浏览器风控宽松（实测 iPhone UA 加载 m 站手机版不弹验证码、关键词 key 生效）；
    /// 注意：桌面 UA + reform=pcfront 会被 58 反爬网关拦截（iOS WebKit 平台指纹与 UA 不符 → 弹验证码），
    /// 且 reform=pcfront 转 PC 站时会丢弃 key 参数导致抓到全城房源，故统一走手机站手机版
    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var pendingHouses: [F58House] = []
    /// 验证码命中后的自动重试（58 风控偶发，重试一次常可放行；仍失败才提示用户人工处理）
    private var retriedCaptcha = false
    /// 本次实际加载的 URL（自动重试时复用）
    private var lastLoadedURL = ""
    /// 详情页经纪人补抓进度回调（v2.2：current/total，nil 表示未开始）
    var onDetailProgress: ((Int, Int) -> Void)?

    // MARK: - 公开入口：抓取第一页（当前设置 URL）

    func fetchFirstPage(urlString: String) async throws -> FetchResult {
        pendingHouses = []
        retriedCaptcha = false
        // URL 归一：剥离 reform=pcfront（它会转 PC 站并丢弃 key 参数 → 抓到全城房源且触发反爬网关）
        var cleaned = urlString
            .replacingOccurrences(of: "&reform=pcfront", with: "")
            .replacingOccurrences(of: "?reform=pcfront", with: "")
            .replacingOccurrences(of: "&reform=pcfront&", with: "&")
        // PC 站列表 URL 归一为手机站（58 对 PC 站 URL 反爬严格，手机 UA 访问 PC 站会被 58 重定向回 m 站）
        cleaned = cleaned
            .replacingOccurrences(of: "https://sd.58.com/zufang/", with: "https://m.58.com/sd/zufang/")
            .replacingOccurrences(of: "http://sd.58.com/zufang/", with: "https://m.58.com/sd/zufang/")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FetchResult, Error>) in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            // 持久数据存储：与安居客一致，保存 58 cookie（58 详情/验证码校验依赖会话）
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            // 手机 UA：58 对真实手机浏览器风控宽松（实测 iPhone UA 不弹验证码、key 生效）
            wv.customUserAgent = Self.mobileUA
            let controller = wv.configuration.userContentController
            controller.add(self, name: "f58Scrape")
            self.webView = wv
            guard let url = URL(string: cleaned) else {
                self.continuation = nil
                cont.resume(returning: FetchResult(error: "列表页 URL 无效，请在设置里检查"))
                return
            }
            self.lastLoadedURL = cleaned
            wv.load(URLRequest(url: url))
            // 兜底超时（页面卡死/网络异常/验证码需人工处理时恢复）
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                if let c = self.continuation {
                    self.continuation = nil
                    self.webView?.stopLoading()
                    self.webView = nil
                    c.resume(throwing: F58Error.msg("页面加载超时，请检查网络后重试"))
                }
            }
        }
    }

    // MARK: - 导航回调

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等待列表渲染后注入抓取脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.runScrape(on: webView)
        }
    }

    // MARK: - 注入 JS：收集第一页房源卡片

    private func runScrape(on webView: WKWebView) {
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // 等待列表渲染出卡片（手机站 li[class*=realverify] / li.list-item，PC 前端 li.house-cell；最多 15 秒）
          var waited = 0;
          while (waited < 15000) {
            if (document.querySelector('li.house-cell') || document.querySelector('li[class*=realverify]') || document.querySelector('li.list-item')) break;
            await sleep(500); waited += 500;
          }
          // 验证码/反爬网关检测（58 风控偶发；命中时交给上层重试或人工处理，不硬抓）
          var bodyText = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          var titleText = norm(document.title || '');
          var hrefNow = location.href || '';
          if (bodyText.indexOf('请输入验证码') >= 0 || titleText.indexOf('验证码') >= 0 ||
              hrefNow.indexOf('antibot') >= 0 || hrefNow.indexOf('verifycode') >= 0 ||
              (document.getElementById && document.getElementById('@@xxzlGatewayUrl'))) {
            window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'captcha', text: titleText}));
            return;
          }
          var cards = [];
          var lis = document.querySelectorAll('li.house-cell');
          var mobile = lis.length === 0;
          if (mobile) {
            lis = document.querySelectorAll('li[class*=realverify]');
            if (lis.length === 0) lis = document.querySelectorAll('li.list-item');
          }
          for (var i = 0; i < lis.length; i++) {
            var li = lis[i];
            var a = li.querySelector('.des h2 a') || li.querySelector('a.list-item') || li.querySelector('a');
            if (!a) continue;
            var href = a.getAttribute('href') || '';
            var mm = href.match(/zufang\\/(\\d+)x\\.shtml/);
            var infoid = mm ? mm[1] : (li.getAttribute('infoid') || '');
            if (!infoid) continue;
            var img = li.querySelector('.img-list img');
            var cover = '';
            if (img) {
              cover = img.getAttribute('lazy_src') || img.getAttribute('data-src') || img.getAttribute('src') || '';
              if (cover.indexOf('lazy_pic.png') >= 0) cover = '';
            }
            if (!cover) {
              var imgBox = li.querySelector('.list-item-img');
              if (imgBox) cover = imgBox.getAttribute('bg-src') || '';
            }
            var dp = li.querySelector('.jjr_par_dp');
            var jjr = li.querySelector('.listjjr');
            var money = li.querySelector('.money b') || li.querySelector('.list-item-info-price');
            var addrEl = li.querySelector('.room') || li.querySelector('.list-item-info-addr-text');
            var infor = li.querySelector('.infor');
            var tip = li.querySelector('.ax-tip') || li.querySelector('.list-item-img-tag') || li.querySelector('.list-item-info-sp-tag');
            var ad = li.querySelector('.ad-icon');
            // 标题：PC 前端 .des h2 a；手机站 .list-item-info-title（innerText 即完整标题）
            var title = '';
            var price = '';
            var room = '', loc = '';
            if (mobile) {
              // —— m 站手机版精确结构（实测确认）——
              // 标题：li.list-item-info-title.strongbox → innerText 完整（如「米兰公馆，诚心出租，随时看房入住」）
              var titleEl = li.querySelector('.list-item-info-title');
              title = titleEl ? norm(titleEl.innerText) : '';
              if (!title) {
                var aText0 = norm(a.innerText || '');
                var lines0 = aText0.split(' ');
                title = (lines0.length > 1 ? lines0[1] : lines0[0]) || '';
              }
              // 价格：li.list-item-info-price i.strongbox 为单一数字（HTML <i class="strongbox">750</i>元）
              var priceEl = li.querySelector('.list-item-info-price i.strongbox');
              if (priceEl) {
                price = norm(priceEl.innerText).replace(/[^\\d]/g, '');
                // 只允许 ≤6 位纯数字：过滤混入日期/点击量等非价格文本（脏数据根因，实测曾取到 6478124/20001019）
                if (price.length > 6) price = '';
              }
              // 位置/户型：.list-item-info-addr-text = 「1室 龙江 -利保米兰公馆」
              var addrText = addrEl ? norm(addrEl.innerText) : '';
              var sp = addrText.indexOf(' ');
              room = sp > 0 ? addrText.slice(0, sp) : addrText;
              loc = sp > 0 ? addrText.slice(sp + 1).trim() : '';
              var aText = norm(a.innerText || '');
              if (!ad && aText.indexOf('广告') >= 0) ad = aText.indexOf('广告') >= 0 ? { innerText: '广告' } : null;
            } else {
              title = norm(a.innerText);
              room = addrEl ? norm(addrEl.innerText) : '';
              loc = infor ? norm(infor.innerText) : '';
              // PC 前端价格同样做 ≤6 位过滤
              var moneyText = money ? norm(money.innerText).replace(/[^\\d]/g, '') : '';
              if (moneyText.length <= 6) price = moneyText;
            }
            // 姓名清洗：去掉「X日内实拍验真/实拍验真」等徽标杂质
            var name = jjr ? norm(jjr.innerText) : '';
            name = name.replace(/\\d+日内?实拍验真/g, '').replace(/实拍验真/g, '').trim();
            cards.push({
              infoid: infoid,
              title: title,
              href: href,
              cover: cover,
              price: price,
              room: room,
              loc: loc,
              agentDp: dp ? norm(dp.innerText) : '',
              agentName: name,
              tip: tip ? norm(tip.innerText) : '',
              ad: ad ? norm(ad.innerText) : ''
            });
          }
          // 只取第一页前 40 条（用户口径：每次约 40 条）
          cards = cards.slice(0, 40);
          window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'page', cards: cards, page: 1}));
          window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'done', total: cards.length, error:''}));
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

    private func finish(error: String) {
        guard let c = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView = nil
        var result = FetchResult()
        result.error = error
        c.resume(returning: result)
    }

    // MARK: - 详情页经纪人补抓（v2.2；v2.3 修复：不再阻塞主线程）

    /// 逐个抓详情页补经纪人姓名/公司；每批 3 个并发、单请求 4 秒超时、整体可失败降级。
    /// 改 chunked 批处理（async 挂起，不占用主线程）——旧版用 DispatchSemaphore.wait() 在 MainActor 上
    /// 同步阻塞 + 40 条全超时时主线程被卡约 78 秒，表现为「刷不出来」。现在房源列表先返回，
    /// 补抓在后台进行，通过 onDetailProgress 汇报进度。
    func enrichAgents(_ houses: [F58House]) async -> [F58House] {
        var result = houses
        let total = result.count
        guard total > 0 else { return result }
        let batch = 3
        var start = 0
        while start < total {
            let end = min(start + batch, total)
            // 先把本批 href 拷成 let（Sendable 值），@Sendable 子任务只读捕获它，避免捕获可变数组
            let batchHrefs: [(Int, String)] = (start..<end).map { ($0, result[$0].href) }
            await withTaskGroup(of: (Int, String?, String?).self) { group in
                for (i, href) in batchHrefs {
                    group.addTask {
                        let detail = await Self.fetchAgentDetail(href: href)
                        return (i, detail.name, detail.dp)
                    }
                }
                for await (idx, name, dp) in group {
                    if let name, !name.isEmpty { result[idx].agentName = name }
                    if let dp, !dp.isEmpty { result[idx].agentDp = dp }
                    Task { @MainActor [weak self] in
                        self?.onDetailProgress?(idx + 1, total)
                    }
                }
            }
            start = end
        }
        return result
    }

    /// 详情页经纪人信息（m 站详情页实测 iPhone UA 直接放行、无验证码）：
    /// 姓名 `div.user ul.user-profile li.profile span.name`；身份 `span.tag`（经纪人/个人）；
    /// 公司 `div.agentCondition .cards.agent-company span`
    private static func fetchAgentDetail(href: String) async -> (name: String?, dp: String?) {
        let urlStr: String
        if href.hasPrefix("http") {
            urlStr = href
        } else if href.hasPrefix("/") {
            urlStr = "https://m.58.com" + href
        } else {
            urlStr = href
        }
        guard let url = URL(string: urlStr) else { return (nil, nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://m.58.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return (nil, nil) }
            return parseAgentDetail(html)
        } catch {
            return (nil, nil)
        }
    }

    private static func parseAgentDetail(_ html: String) -> (name: String?, dp: String?) {
        var name: String?
        var dp: String?
        if let m = firstCapture(html, pattern: #"class="name"[^>]*>\s*([^<]+?)\s*<"#) {
            name = m
        }
        if let m = firstCapture(html, pattern: #"agent-company[\s\S]{0,600}?<span[^>]*>\s*([^<]+?)\s*<"#) {
            dp = m
        }
        // 个人房东（无 agentCondition 公司块）也可能在 user-profile 有名字
        if name == nil {
            if let m = firstCapture(html, pattern: #"user-profile[\s\S]*?<span[^>]*>\s*([^<]+?)\s*<"#) {
                name = m
            }
        }
        return (name?.trimmingCharacters(in: .whitespacesAndNewlines), dp?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func firstCapture(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

extension F58WebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "f58Scrape",
              let body = message.body as? String,
              let dict = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "captcha" {
            guard let c = continuation else { return }
            // 58 风控偶发：自动重试一次（重建 WebView 重新加载，同一 continuation），仍失败才提示用户
            if !retriedCaptcha, let url = URL(string: lastLoadedURL) {
                retriedCaptcha = true
                userContentController.removeScriptMessageHandler(forName: "f58Scrape")
                webView?.stopLoading()
                webView = nil
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                let wv2 = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
                wv2.navigationDelegate = self
                wv2.customUserAgent = Self.mobileUA
                wv2.configuration.userContentController.add(self, name: "f58Scrape")
                self.webView = wv2
                wv2.load(URLRequest(url: url))
                DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                    if let cc = self.continuation {
                        self.continuation = nil
                        self.webView?.stopLoading()
                        self.webView = nil
                        cc.resume(throwing: F58Error.msg("页面加载超时，请检查网络后重试"))
                    }
                }
                return
            }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "f58Scrape")
            webView?.stopLoading()
            webView = nil
            var result = FetchResult()
            result.needCaptcha = true
            c.resume(returning: result)
            return
        }

        if type == "page" {
            guard let arr = dict["cards"] as? [[String: Any]] else { return }
            for obj in arr {
                let house = F58House(
                    infoid: (obj["infoid"] as? String) ?? "",
                    title: (obj["title"] as? String) ?? "",
                    href: (obj["href"] as? String) ?? "",
                    coverURL: (obj["cover"] as? String) ?? "",
                    coverPath: nil,
                    price: (obj["price"] as? String) ?? "",
                    room: (obj["room"] as? String) ?? "",
                    loc: (obj["loc"] as? String) ?? "",
                    agentDp: (obj["agentDp"] as? String) ?? "",
                    agentName: (obj["agentName"] as? String) ?? "",
                    tip: (obj["tip"] as? String) ?? "",
                    ad: (obj["ad"] as? String) ?? ""
                )
                if !house.infoid.isEmpty {
                    pendingHouses.append(house)
                }
            }
            return
        }

        if type == "done" {
            guard let c = continuation else { return }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "f58Scrape")
            webView?.stopLoading()
            webView = nil
            let houses = pendingHouses
            pendingHouses = []
            // v2.3（刷不出来修复）：列表立即返回展示（标题/价格/位置先可用），
            // 详情页经纪人补抓由 F58Store.fetch 在后台调用 enrichAgents 执行（进度走 onDetailProgress）
            var result = FetchResult()
            result.houses = houses
            c.resume(returning: result)
        }
    }
}

/// 抓取错误
enum F58Error: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        }
    }
}
