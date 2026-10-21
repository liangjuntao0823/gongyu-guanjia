import SwiftUI
import SwiftData
import UIKit

struct UtilityView: View {
    var presetProperty: Property? = nil
    var onWriteSuccess: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Property.roomNumber) private var properties: [Property]
    @State private var selectedProperty: Property?
    @State private var includesMaster = false
    @State private var electricPriceText = "0.8"
    @State private var waterPriceText = "5.5"
    @State private var electricTotalText = ""
    @State private var electricSubText = ""
    @State private var electricBaseText = ""
    @State private var waterTotalText = ""
    @State private var waterSubText = ""
    @State private var waterBaseText = ""
    @State private var prepaymentText = ""
    @State private var showHistory = false
    @State private var copied = false
    @State private var showWechatPrompt = false
    @State private var showSaved = false
    @State private var pendingHistory: UtilitySettlementHistory?
    @State private var showPeriodChoice = false
    @AppStorage("defaultElectricPrice") private var defaultElectricPrice = "0.8"
    @AppStorage("defaultWaterPrice") private var defaultWaterPrice = "5.5"
    @AppStorage("defaultUtilityPrepayment") private var defaultUtilityPrepayment = "0"

    private var room: String { selectedProperty?.roomNumber ?? "" }
    private var ePrice: Double { Double(electricPriceText) ?? 0.8 }; private var wPrice: Double { Double(waterPriceText) ?? 5.5 }
    private var eTotal: Double { Double(electricTotalText) ?? 0 }; private var eSub: Double { Double(electricSubText) ?? 0 }; private var eBase: Double { Double(electricBaseText) ?? 0 }
    private var wTotal: Double { Double(waterTotalText) ?? 0 }; private var wSub: Double { Double(waterSubText) ?? 0 }; private var wBase: Double { Double(waterBaseText) ?? 0 }
    private var prepay: Double { Double(prepaymentText) ?? 0 }
    private var eLatest: Double { includesMaster ? eTotal - eSub : eSub }; private var wLatest: Double { includesMaster ? wTotal - wSub : wSub }
    private var eUsage: Double { eLatest - eBase }; private var wUsage: Double { wLatest - wBase }
    private var hasElectric: Bool { !electricSubText.isEmpty || (includesMaster && !electricTotalText.isEmpty) }; private var hasWater: Bool { !waterSubText.isEmpty || (includesMaster && !waterTotalText.isEmpty) }
    private var eCost: Int { hasElectric ? Int((eUsage * ePrice).rounded()) : 0 }; private var wCost: Int { hasWater ? Int((wUsage * wPrice).rounded()) : 0 }
    private var balance: Int { Int(prepay.rounded()) - eCost - wCost }
    private func n(_ v: Double) -> String { String(format: v.rounded() == v ? "%.0f" : "%.2f", v) }
    private var statement: String {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"
        var lines = ["\(room.isEmpty ? "XXX" : room)房截止\(f.string(from: Date()))"]
        if includesMaster {
            if hasElectric { lines.append("用电：\(n(eTotal))-\(n(eSub))=\(n(eLatest))-\(n(eBase))=\(n(eUsage))x\(n(ePrice))=\(eCost)元") } else { lines.append("用电：暂不结算") }
            if hasWater { lines.append("用水：\(n(wTotal))-\(n(wSub))=\(n(wLatest))-\(n(wBase))=\(n(wUsage))x\(n(wPrice))=\(wCost)元") } else { lines.append("用水：暂不结算") }
        } else {
            if hasElectric { lines.append("用电：\(n(eSub))-\(n(eBase))=\(n(eUsage))x\(n(ePrice))=\(eCost)元") } else { lines.append("用电：暂不结算") }
            if hasWater { lines.append("用水：\(n(wSub))-\(n(wBase))=\(n(wUsage))x\(n(wPrice))=\(wCost)元") } else { lines.append("用水：暂不结算") }
        }
        lines.append("预存结算：\(Int(prepay.rounded()))-\(eCost)-\(wCost)=\(balance)元")
        return lines.joined(separator: "\n")
    }

    private func periodTitle(_ record: UtilitySettlementRecord) -> String { if let date=record.dueDate { let f=DateFormatter();f.dateFormat="yyyy年M月d日";return f.string(from:date) }; return "\(record.year)年\(record.period)月" }
    var body: some View {
        NavigationStack {
            Form {
                Section("房源信息") {
                    Picker("房号", selection: $selectedProperty) { Text("请选择").tag(nil as Property?); ForEach(properties.filter { !$0.isTerminated }) { Text($0.roomNumber).tag($0 as Property?) } }
                    Picker("是否带总表计算", selection: $includesMaster) { Text("不带总表").tag(false); Text("带总表").tag(true) }.pickerStyle(.segmented)
                }
                Section("单价设置") { amountRow("电费单价", $electricPriceText, unit: "元/度"); amountRow("水费单价", $waterPriceText, unit: "元/吨") }
                Section("电费计算") {
                    if includesMaster { amountRow("总表读数", $electricTotalText) }
                    amountRow("分表读数", $electricSubText); amountRow("登记底数", $electricBaseText)
                    LabeledContent("用电量", value: "\(n(eUsage))度"); LabeledContent("电费", value: "\(eCost)元")
                }
                Section("水费计算") {
                    if includesMaster { amountRow("总表读数", $waterTotalText) }
                    amountRow("分表读数", $waterSubText); amountRow("登记底数", $waterBaseText)
                    LabeledContent("用水量", value: "\(n(wUsage))吨"); LabeledContent("水费", value: "\(wCost)元")
                }
                Section("预存结算") { amountRow("总预存", $prepaymentText); LabeledContent("结余", value: "\(balance)元") }
                Section("结算单") { Text(statement).font(.system(size: 14)).textSelection(.enabled).padding(.vertical, 8) }
                Section { Button { UIPasteboard.general.string = statement; copied = true; showWechatPrompt = true } label: { HStack { Spacer(); Label(copied ? "已复制" : "一键复制", systemImage: "doc.on.doc"); Spacer() } } }
            }
            .navigationTitle("水电结算").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("计算历史") { showHistory = true } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("保存", action: save).disabled(selectedProperty == nil || (!hasElectric && !hasWater)) }
            }
            .sheet(isPresented: $showHistory) { UtilityHistoryView() }
            .sheet(isPresented: $showPeriodChoice) { if let p=selectedProperty, let h=pendingHistory { UtilityPeriodChoiceView(property:p, history:h) { showPeriodChoice=false; showSaved=true } } }
            .alert("写入成功", isPresented:$showSaved) { Button("确定", role:.cancel){ onWriteSuccess?(); dismiss() } } message:{Text("水电金额、结余和结算单已写入所选周期。") }
            .alert("是否打开微信发给租客？", isPresented:$showWechatPrompt) { Button("取消",role:.cancel){}; Button("打开") { if let url=URL(string:"weixin://"), UIApplication.shared.canOpenURL(url){UIApplication.shared.open(url)} } } message:{Text("结算单已复制")}
            .onAppear { electricPriceText=defaultElectricPrice;waterPriceText=defaultWaterPrice;prepaymentText=defaultUtilityPrepayment;if let p=presetProperty{selectedProperty=p;electricBaseText=String(p.electricMeterBase);waterBaseText=String(p.waterMeterBase)} }
            .onChange(of: selectedProperty) { _, p in if let p { electricBaseText=String(p.electricMeterBase); waterBaseText=String(p.waterMeterBase) } }
        }
    }
    private func amountRow(_ title: String, _ text: Binding<String>, unit: String = "") -> some View { HStack { Text(title); Spacer(); TextField("请输入", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110); if !unit.isEmpty { Text(unit).foregroundColor(.themeText3) } } }
    private func reset() { electricTotalText="";electricSubText="";waterTotalText="";waterSubText="";copied=false;prepaymentText=defaultUtilityPrepayment; if let p=selectedProperty { electricBaseText=String(p.electricMeterBase);waterBaseText=String(p.waterMeterBase) } }
    private func save() { guard let p=selectedProperty else{return}; if hasElectric {p.electricMeterBase=Int(eLatest.rounded())};if hasWater {p.waterMeterBase=Int(wLatest.rounded())};let maxOrder=((try? modelContext.fetch(FetchDescriptor<UtilitySettlementHistory>())) ?? []).map(\.sortOrder).max() ?? -1;let h=UtilitySettlementHistory(roomNumber:p.roomNumber,statement:statement,settledAt:Date(),includesMaster:includesMaster,electricLatest:eLatest,waterLatest:wLatest,electricCost:eCost,waterCost:wCost,balance:balance,sortOrder:maxOrder+1);modelContext.insert(h);try? modelContext.save();pendingHistory=h;showPeriodChoice=true }
}

@Model final class UtilitySettlementHistory {
    var id: UUID; var roomNumber: String; var statement: String; var settledAt: Date; var includesMaster: Bool; var electricLatest: Double; var waterLatest: Double; var electricCost: Int; var waterCost: Int; var balance: Int; var sortOrder: Int
    init(id:UUID=UUID(),roomNumber:String,statement:String,settledAt:Date,includesMaster:Bool,electricLatest:Double,waterLatest:Double,electricCost:Int,waterCost:Int,balance:Int,sortOrder:Int){self.id=id;self.roomNumber=roomNumber;self.statement=statement;self.settledAt=settledAt;self.includesMaster=includesMaster;self.electricLatest=electricLatest;self.waterLatest=waterLatest;self.electricCost=electricCost;self.waterCost=waterCost;self.balance=balance;self.sortOrder=sortOrder}
}


struct UtilityHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\UtilitySettlementHistory.settledAt, order: .reverse)]) private var histories: [UtilitySettlementHistory]
    @State private var searchText=""
    @State private var selected: UtilitySettlementHistory?
    @State private var editing: UtilitySettlementHistory?
    @State private var deleting: UtilitySettlementHistory?
    var body: some View {
        NavigationStack {
            VStack(spacing:8){
            HStack{Image(systemName:"magnifyingglass").foregroundColor(.themeText3);TextField("搜索房号或结算内容",text:$searchText);if !searchText.isEmpty{Button{searchText=""}label:{Image(systemName:"xmark.circle.fill")}}}.padding(.horizontal,12).padding(.vertical,8).background(Color.themePanel).cornerRadius(10).overlay(RoundedRectangle(cornerRadius:10).stroke(Color.themeBorder)).padding(.horizontal).padding(.top,8)
            List {
                ForEach(histories.filter{searchText.isEmpty || $0.roomNumber.localizedCaseInsensitiveContains(searchText) || $0.statement.localizedCaseInsensitiveContains(searchText)}) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.roomNumber+"房").font(.headline)
                        Text(item.settledAt.formatted(date: .numeric,time:.shortened)).font(.caption).foregroundColor(.themeText3)
                        Text(item.statement).font(.caption).fixedSize(horizontal:false,vertical:true)
                    }.contentShape(Rectangle()).onTapGesture { selected=item }
                    .contextMenu {
                        Button {
                            let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 HH:mm"
                            UIPasteboard.general.string = "\(item.roomNumber)房 \(f.string(from: item.settledAt))\n\(item.statement)"
                        } label: { Label("复制", systemImage: "doc.on.doc") }
                    }
                    .swipeActions {
                        Button(role:.destructive){ deleting=item } label:{Label("删除",systemImage:"trash")}
                        Button{editing=item} label:{Label("编辑",systemImage:"pencil")}.tint(.blue)
                    }
                }.onMove(perform: move)
            }}.navigationTitle("计算历史").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}} }
            .sheet(item:$selected){UtilityHistoryPreview(history:$0)}
            .sheet(item:$editing){UtilityHistoryEditView(history:$0)}
            .alert("确认删除",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})){
                Button("取消",role:.cancel){deleting=nil};Button("确定删除",role:.destructive){if let d=deleting{modelContext.delete(d);try? modelContext.save()};deleting=nil}
            } message:{Text("删除后无法恢复。")}
        }
    }
    private func move(from source:IndexSet,to destination:Int){var ordered=histories;ordered.move(fromOffsets:source,toOffset:destination);for(i,h)in ordered.enumerated(){h.sortOrder=i};try? modelContext.save()}
}

struct UtilityHistoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let history: UtilitySettlementHistory
    @State private var text:String
    init(history:UtilitySettlementHistory){self.history=history;_text=State(initialValue:history.statement)}
    var body:some View{NavigationStack{Form{TextEditor(text:$text).frame(minHeight:260)}.navigationTitle("编辑结算单").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){history.statement=text;try? modelContext.save();dismiss()}}}}}
}

struct UtilityHistoryPreview: View {
    @Environment(\.dismiss) private var dismiss
    let history:UtilitySettlementHistory
    @State private var image:UIImage?
    @State private var sharing=false
    @State private var previewing=false
    var body:some View{NavigationStack{ScrollView{UtilityStatementCard(history:history).padding()}.navigationTitle(history.roomNumber+"房结算单").navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.navigationBarLeading){Button{makeImage()}label:{Image(systemName:"square.and.arrow.up")}};ToolbarItem(placement:.confirmationAction){Button("关闭"){dismiss()}}}.sheet(isPresented:$sharing){if let image{ActivityView(activityItems:[image])}}}}
    private func makeImage(){let renderer=ImageRenderer(content:UtilityStatementCard(history:history).frame(width:360).padding().background(Color.white));renderer.scale=3;if let result=renderer.uiImage{image=result;sharing=true}}
}

struct UtilityStatementCard: View {
    let history:UtilitySettlementHistory
    var body:some View{VStack(alignment:.leading,spacing:14){Text(history.roomNumber+"房水电结算单").font(.title2.bold());Text(history.settledAt.formatted(date:.long,time:.omitted)).foregroundColor(.secondary);Divider();Text(history.statement).font(.system(size:16)).fixedSize(horizontal:false,vertical:true);Divider();HStack{Text(verbatim: "电费 \(history.electricCost)元");Spacer();Text(verbatim: "水费 \(history.waterCost)元")};Text(verbatim: "预存结余 \(history.balance)元").font(.headline)}.padding(20).background(Color.white).foregroundColor(.black).cornerRadius(14)}

}


struct UtilityPeriodChoiceView: View {
    let property: Property
    let history: UtilitySettlementHistory
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    private var uniqueRecords:[UtilitySettlementRecord] { var seen=Set<String>();let f=DateFormatter();f.dateFormat="yyyyMMdd";return property.utilitySettlementRecords.sorted{($0.dueDate ?? .distantFuture)<($1.dueDate ?? .distantFuture)}.filter{seen.insert(f.string(from:$0.dueDate ?? .distantFuture)).inserted} }
    private func periodTitle(_ record: UtilitySettlementRecord) -> String { if let date=record.dueDate { let f=DateFormatter();f.dateFormat="yyyy年M月d日";return f.string(from:date) }; return "\(record.year)年\(record.period)月" }
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(uniqueRecords)) { record in
                    Button {
                        record.electricAmount=Double(history.electricCost);record.waterAmount=Double(history.waterCost);record.balance=Double(history.balance);record.isSettled=true;record.statement=history.statement;record.settledAt=history.settledAt
                        if let d=record.dueDate { let cal=Calendar.current; if let rent=property.monthlyRentRecords.first(where:{ $0.year==cal.component(.year,from:d) && $0.month==cal.component(.month,from:d) }) { rent.amount = property.rent + property.prepayment - record.balance } }
                        try? modelContext.save();dismiss();onDone()
                    } label: {
                        VStack(alignment:.leading,spacing:5){Text(periodTitle(record)).font(.headline);HStack{Text(record.isSettled ? "已结算" : "未结算").font(.system(size:16,weight:.semibold));Spacer();Text(verbatim: "电\(Int(record.electricAmount)) 水\(Int(record.waterAmount)) 余\(Int(record.balance))").font(.system(size:15,weight:.medium))}.font(.caption).foregroundColor(.secondary)}
                    }.foregroundColor(.primary)
                }
            }.navigationTitle("写入结算周期").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}}}
        }
    }
}
