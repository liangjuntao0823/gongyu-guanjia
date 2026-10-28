//
//  MeterWebViewProvider.swift
//  公寓管家 · 电表数据兜底方案：WebView 页面环境执行官方接口
//  背景：官方服务端当前只放行「页面环境」请求（打开页面后 JS 建立会话，直接 POST 被拒）。
//  本方案加载官方页面（微信 UA、非持久会话），在真实页面环境内用 fetch 完成
//  index→getBindList→electricMeterQuery→electricPayRecordList 全链路，一次加载查全部。
//  与直连方案共用同一数据出口（MeterLedger），设置页可切换。仅读取，不做任何资金操作。
//

import Foundation
import WebKit

/// WebView 兜底方案（@MainActor：WKWebView 只能在主线程操作）
@MainActor
final class MeterWebViewProvider: NSObject, MeterQuerying, WKNavigationDelegate {

    static let shared = MeterWebViewProvider()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[PageItemResult], Error>?
    private var progress: ((Int, Int, String) -> Void)?
    private var total = 0
    private var pendingTask: PageTask = .refresh([])
    private var pendingUIDs: [String] = []

    /// 单页任务的逐项结果（refresh：uid+查询结果；records：payload 为原始记录 JSON）
    private struct PageItemResult {
        let uid: String
        let ok: Bool
        let result: MeterQueryResult?
        let payloadText: String
    }

    private enum PageTask {
        case refresh([String])
        case records(String)
        case bindings
    }

    // MARK: - 批量刷新（一次加载查全部，串行限速）

    /// 拉取当前微信身份绑定的全部电表用户号（页面环境 getBindList）
    func fetchBindings(store: MeterStore) async throws -> [String] {
        guard !store.settings.openId.isEmpty else { throw MeterQueryError.msg("未配置电表查询链接") }
        struct ListResp: Decodable {
            struct D: Decodable { let list: [Item]? }
            struct Item: Decodable { let electricUserUid: String? }
            let code: Int?
            let data: D?
        }
        // 复用页面环境：加载一次页面后执行 index + getBindList
        let items = try await runInPage(openId: store.settings.openId, task: .bindings)
        guard let payload = items.first?.payloadText, !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let resp = try? JSONDecoder().decode(ListResp.self, from: data),
              resp.code == 0 else {
            throw MeterQueryError.msg("获取绑定列表失败")
        }
        let list = resp.data?.list?.compactMap { $0.electricUserUid } ?? []
        guard !list.isEmpty else { throw MeterQueryError.msg("当前微信身份下没有绑定电表") }
        return list
    }

    func refreshAll(store: MeterStore, progress: @escaping (Int, Int, String) -> Void) async throws -> Int {
        guard !store.settings.openId.isEmpty else { throw MeterQueryError.msg("未配置电表查询链接") }
        let uids = store.meters.map { $0.uid }
        guard !uids.isEmpty else { throw MeterQueryError.msg("暂无电表") }
        self.progress = progress
        self.total = uids.count

        let results = try await runInPage(openId: store.settings.openId, task: .refresh(uids))
        var ok = 0
        for item in results {
            if item.ok, let r = item.result {
                store.applyQueryResult(uid: item.uid, result: r)
                ok += 1
            }
        }
        store.sendLowAlertIfNeeded()
        if ok == 0 { throw MeterQueryError.msg("网页抓取未取到数据，请检查链接或稍后重试") }
        return ok
    }

    /// 单台刷新
    func query(store: MeterStore, uid: String) async throws -> MeterQueryResult {
        guard !store.settings.openId.isEmpty else { throw MeterQueryError.msg("未配置电表查询链接") }
        let results = try await runInPage(openId: store.settings.openId, task: .refresh([uid]))
        guard let first = results.first, first.ok, let r = first.result else {
            throw MeterQueryError.msg("查询失败（\(uid)）")
        }
        return r
    }

    /// 充值记录（页面环境拉取官方列表）
    func payRecords(store: MeterStore, uid: String) async throws -> [MeterPayRecord] {
        guard !store.settings.openId.isEmpty else { throw MeterQueryError.msg("未配置电表查询链接") }
        struct RecordsResp: Decodable {
            struct D: Decodable { let list: [MeterPayRecord]? }
            let code: Int?
            let data: D?
        }
        let items = try await runInPage(openId: store.settings.openId, task: .records(uid))
        guard let s = items.first?.payloadText, !s.isEmpty else {
            return []
        }
        if let data = s.data(using: .utf8),
           let resp = try? JSONDecoder().decode(RecordsResp.self, from: data),
           resp.code == 0 {
            return resp.data?.list ?? []
        }
        throw MeterQueryError.msg("获取充值记录失败（\(uid)）")
    }

    // MARK: - 页面任务

    /// 加载页面并在页面环境执行 JS 任务，返回逐项结果
    private func runInPage(openId: String, task: PageTask) async throws -> [PageItemResult] {
        pendingTask = task
        switch task {
        case .refresh(let uids): pendingUIDs = uids
        case .records(let uid): pendingUIDs = [uid]
        case .bindings: pendingUIDs = []
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[PageItemResult], Error>) in
            self.continuation = cont
            let url = URL(string: "http://wy.mlh-china.com/electricmeter/?openId=\(openId)")!
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = MeterQueryService.wechatUA
            let controller = wv.configuration.userContentController
            controller.add(self, name: "meterScrape")
            self.webView = wv
            wv.load(URLRequest(url: url))
            // 兜底超时（页面卡死/网络异常时恢复，避免无限等待）
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if let c = self.continuation {
                    self.continuation = nil
                    c.resume(throwing: MeterQueryError.msg("网页加载超时，请检查网络"))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // SPA 异步渲染 + 页面会话建立后注入脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.runScrape(on: webView)
        }
    }

    /// 按任务类型注入 JS：refresh 查全部电表；records 查充值记录
    private func runScrape(on webView: WKWebView) {
        let store = MeterStore.shared
        let openId = store.settings.openId
        let uidsJSON = pendingUIDs.map { "\"\($0)\"" }.joined(separator: ",")
        let taskType: String
        switch pendingTask {
        case .refresh: taskType = "refresh"
        case .records: taskType = "records"
        case .bindings: taskType = "bindings"
        }
        let js = """
        (async function(){
          var out = {type:'result', uid:'', payload:'', error:''};
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          async function post(path, obj){
            try {
              var parts = Object.keys(obj).map(function(k){ return encodeURIComponent(k)+'='+encodeURIComponent(String(obj[k])); });
              var r = await fetch(path, {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: parts.join('&')});
              var t = await r.text();
              try { return JSON.parse(t); } catch(e){ return {code:-1, raw:t}; }
            } catch(e){ return {code:-2, err:String(e)}; }
          }
          try {
            var idx = await post('/kddz/electricmeterpost/index', {openId:'\(openId)'});
            var wid = (idx && idx.code === 0 && idx.data && idx.data.wechatId) ? idx.data.wechatId : '';
            if (!wid){ window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'done', payload:'', error:'会话建立失败，请检查链接'})); return; }
            var uids = [\(uidsJSON)];
            var task = '\(taskType)';
            if (task === 'records'){
              var uid = uids[0];
              window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'progress', uid:uid, done:1, total:1}));
              var q = null;
              for (var a=0;a<2;a++){
                try { q = await post('/kddz/electricmeterpost/electricPayRecordList', {wechatUserId:wid, electricUserUid:uid}); if (q && q.code===0) break; } catch(e){}
                await sleep(600);
              }
              window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'done', payload: q ? JSON.stringify(q) : '', error:''}));
              return;
            }
            if (task === 'bindings'){
              var b = await post('/kddz/electricmeterpost/getBindList', {wechatUserId:wid});
              window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'done', payload: b ? JSON.stringify(b) : '', error:''}));
              return;
            }
            var results = [];
            for (var i=0;i<uids.length;i++){
              var uid = uids[i];
              window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'progress', uid:uid, done:i+1, total:uids.length}));
              var q = null;
              for (var a=0;a<2;a++){
                try { q = await post('/kddz/electricmeterpost/electricMeterQuery', {wechatUserId:wid, electricUserUid:uid}); if (q && q.code===0 && q.data) break; } catch(e){}
                await sleep(600);
              }
              if (q && q.code===0 && q.data){
                results.push({uid:uid, ok:true, shengyu:(q.data.shengyu||'0'), leiji:(q.data.leiji||'0'), zhuangtai:(q.data.zhuangtai||'合闸'), shijian:(q.data.shijian||'')});
              } else {
                results.push({uid:uid, ok:false});
              }
              if (i < uids.length-1) await sleep(1500);
            }
            window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'done', payload:JSON.stringify(results), error:''}));
          } catch(e){
            window.webkit.messageHandlers.meterScrape.postMessage(JSON.stringify({type:'done', payload:'', error:String(e)}));
          }
        })();
        """
        webView.evaluateJavaScript(js) { _, _ in }
    }
}

extension MeterWebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "meterScrape",
              let body = message.body as? String,
              let dict = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "progress" {
            let done = (dict["done"] as? Int) ?? 0
            let totalN = (dict["total"] as? Int) ?? total
            let uid = (dict["uid"] as? String) ?? ""
            progress?(done, totalN, uid)
            return
        }

        // done：结束任务
        guard let c = continuation else { return }
        continuation = nil
        userContentController.removeScriptMessageHandler(forName: "meterScrape")
        webView?.stopLoading()
        webView = nil
        let error = (dict["error"] as? String) ?? ""
        let payload = (dict["payload"] as? String) ?? ""
        if !error.isEmpty {
            c.resume(throwing: MeterQueryError.msg(error))
            return
        }
        // refresh → [{uid,ok,shengyu,...}]；records → payload 原样带回
        struct RawItem: Decodable {
            let uid: String
            let ok: Bool
            let shengyu: String?
            let leiji: String?
            let zhuangtai: String?
            let shijian: String?
        }
        var results: [MeterWebViewProvider.PageItemResult] = []
        if let data = payload.data(using: .utf8),
           let arr = try? JSONDecoder().decode([RawItem].self, from: data) {
            results = arr.map { item in
                let r = MeterQueryResult(shengyu: item.shengyu ?? "0",
                                         leiji: item.leiji ?? "0",
                                         zhuangtai: item.zhuangtai ?? "合闸",
                                         shijian: item.shijian ?? "")
                return MeterWebViewProvider.PageItemResult(uid: item.uid, ok: item.ok, result: r, payloadText: "")
            }
        } else if !payload.isEmpty {
            // records/bindings：payload 原样带回（原始 JSON 文本）
            results = [MeterWebViewProvider.PageItemResult(uid: pendingUIDs.first ?? "", ok: true, result: nil, payloadText: payload)]
        }
        c.resume(returning: results)
    }
}
