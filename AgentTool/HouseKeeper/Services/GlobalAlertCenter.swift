import SwiftUI

/// v1.71（#95）：全局提示中心——把「信息提示（完成/错误）」从各板块页面的 .alert 上移到根 TabView 层级呈现。
/// 此前完成提示挂在房源页，用户切到其他板块后按钮被禁用变灰、只能重启 App；
/// 现在提示覆盖在全部板块之上，任何页面都能点「好」关闭。
@MainActor
final class GlobalAlertCenter: ObservableObject {
    static let shared = GlobalAlertCenter()
    @Published var message: String?
    func show(_ msg: String) { message = msg }
    func dismiss() { message = nil }
}

/// 全局提示遮罩（置于 MainTabView 最上层，不受 Tab 切换 disabled 影响）
struct GlobalAlertOverlay: View {
    @ObservedObject private var center = GlobalAlertCenter.shared
    var body: some View {
        if let msg = center.message {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { center.dismiss() }
                VStack(spacing: 14) {
                    Text("提示")
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
