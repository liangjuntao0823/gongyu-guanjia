import SwiftUI

/// v1.71（#95）：全局提示中心——把「信息提示（完成/错误）」从各板块页面的 .alert 上移到根 TabView 层级呈现。
/// 此前完成提示挂在房源页，用户切到其他板块后按钮被禁用变灰、只能重启 App；
/// 现在提示覆盖在全部板块之上，任何页面都能点「好」关闭。
/// b119（清单4：同步任务全局化）：新增「全局确认框」能力——房源页的同步/补媒体确认
/// 不再挂在房源页 .alert（切页后看不到、任务卡住），改为全局呈现，任意页面可确认继续。
@MainActor
final class GlobalAlertCenter: ObservableObject {
    static let shared = GlobalAlertCenter()
    @Published var message: String?
    @Published var title: String = "提示"
    func show(_ msg: String, title: String = "提示") { self.message = msg; self.title = title }
    func dismiss() { message = nil; title = "提示" }

    // MARK: - b119 全局确认框

    final class ConfirmBox {
        let title: String
        let message: String
        let confirmTitle: String
        let onConfirm: () -> Void
        let onCancel: () -> Void
        init(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
            self.onConfirm = onConfirm
            self.onCancel = onCancel
        }
    }
    @Published var confirmBox: ConfirmBox?
    /// 弹出全局确认框（覆盖全部板块，切页也能看到并确认，任务不被打断）
    func confirm(title: String, message: String, confirmTitle: String = "确认", onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}) {
        self.confirmBox = ConfirmBox(title: title, message: message, confirmTitle: confirmTitle, onConfirm: onConfirm, onCancel: onCancel)
    }
    /// 关闭确认框并执行对应回调（confirmed=true 执行确认，false 执行取消）
    func resolveConfirm(_ confirmed: Bool) {
        guard let box = confirmBox else { return }
        confirmBox = nil
        if confirmed { box.onConfirm() } else { box.onCancel() }
    }
}

/// 全局提示遮罩（置于 MainTabView 最上层，不受 Tab 切换 disabled 影响）
struct GlobalAlertOverlay: View {
    @ObservedObject private var center = GlobalAlertCenter.shared
    var body: some View {
        if let box = center.confirmBox {
            // b119：全局确认框（优先于信息提示呈现）
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { center.resolveConfirm(false) }
                VStack(spacing: 14) {
                    Text(box.title)
                        .font(.headline)
                    Text(box.message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button {
                            center.resolveConfirm(false)
                        } label: {
                            Text("取消")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                        Button {
                            center.resolveConfirm(true)
                        } label: {
                            Text(box.confirmTitle)
                                .font(.body.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.accentColor)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .padding(30)
            }
            .transition(.opacity)
            .zIndex(100)
        } else if let msg = center.message {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { center.dismiss() }
                VStack(spacing: 14) {
                    Text(center.title)
                        .font(.headline)
                    Text(msg)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        center.dismiss()
                    } label: {
                        Text("好")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .cornerRadius(10)
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .padding(30)
            }
            .transition(.opacity)
            .zIndex(100)
        }
    }
}
