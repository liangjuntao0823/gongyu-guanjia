import SwiftUI

struct UserGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                guide("工作台", "查看待办、收租、包租、到期提醒和经营指标；标题栏可折叠。")
                guide("成交管理", "登记成交、租期、租金、中介费；填写交租日后可联动新增收租。")
                guide("收租管理", "管理房源、月度收租计划、按月/按季水电计划、退租及账单分享。")
                guide("水电结算", "支持带总表和不带总表计算，可写入指定周期并保存历史。")
                guide("包租管理", "登记包租房、付款计划、水电及付款提醒。")
                guide("待办事项", "新增、编辑、排序、归档，并可设置每小时提醒。")
                guide("备份恢复", "建议重要修改后手动总备份；自动备份保留最近记录。")
                guide("本地通知", "首次使用需允许通知；收租、包租、到期和待办均可提醒。")
                guide("桌面小组件", "安装包含Widget的IPA后，在桌面或锁屏添加公寓管家组件。")
            }
            .navigationTitle("使用手册")
            .toolbar { ToolbarItem(placement:.confirmationAction){Button("关闭"){dismiss()}} }
        }
    }
    private func guide(_ title:String,_ text:String)->some View { Section(title){Text(text).font(.system(size:14)).foregroundColor(.themeText2)} }
}
