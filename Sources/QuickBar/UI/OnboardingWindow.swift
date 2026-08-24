import AppKit
import SwiftUI

/// 首次启动（或权限掉了）时的引导页。只做一件事：把三项授权补齐。
/// 版式来自设计稿 `QuickBar 快捷条.dc.html` 的 `1f Onboarding`。
final class OnboardingWindowController: NSWindowController {

    convenience init(onFinish: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: OnboardingView(onFinish: onFinish))
        let window = NSWindow(contentViewController: hosting)
        window.title = "欢迎使用 QuickBar"
        window.styleMask = [.titled, .closable]
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 440, height: 452))
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var granted: Set<Permissions.Kind> = []
    private let heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var missingCount: Int { Permissions.Kind.core.count - granted.count }
    private var ready: Bool { missingCount == 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            // 唯一一句解释性文字。留着是因为「输入监控」这四个字天生吓人，
            // 而这句话正好回答人此刻最想问的那个问题（设计稿 1f）。
            Text("按键只用于识别唤出手势，不记录、不上传。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 9)

            Spacer(minLength: 12)
            Divider()
            footer
        }
        .onReceive(heartbeat) { _ in refresh() }
        .onAppear { refresh() }
    }

    // MARK: - 上半

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 11) {
            if ready {
                // 就绪态换成一个绿色的对勾：这一屏的任务完成了，不该再摆着应用标识
                ZStack {
                    Circle().fill(Color.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                Text("全部就绪").font(.system(size: 18, weight: .semibold))
                Text("连按两下 ⌘ 试试")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                AppMark().frame(width: 56, height: 56)
                HStack(spacing: 9) {
                    Circle().fill(Color.orange).frame(width: 9, height: 9)
                    Text("还差 \(missingCount) 项授权").font(.system(size: 19, weight: .semibold))
                }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(Permissions.Kind.core.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    // 分隔线从文字起始处开始（设计稿 1f：左缩进 41），
                    // 让三行读起来是一张卡片、不是三块。
                    Divider().padding(.leading, 41)
                }
                PermissionRow(kind: kind, granted: granted.contains(kind))
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(.separator, lineWidth: 0.5)
        }
        .padding(.horizontal, 18)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Toggle("开机自动启动", isOn: Binding(
                get: { Store.shared.settings.launchAtLogin },
                set: { Store.shared.settings.launchAtLogin = $0; LoginItem.set($0) }
            ))
            .toggleStyle(.checkbox)
            Spacer()
            if !ready {
                Button("稍后") { onFinish() }
            }
            Button("开始使用") { onFinish() }
                .buttonStyle(.borderedProminent)
                .disabled(!ready)
                .help(ready ? "" : "三项都授权后才能开始。")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func refresh() {
        granted = Set(Permissions.Kind.core.filter { Permissions.isGranted($0) })
    }
}

/// 一行授权。**状态用徽标不用句子**：「未授权」是个状态，写成一句话只会占掉一行还看不快。
private struct PermissionRow: View {
    let kind: Permissions.Kind
    let granted: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(kind.title).font(.system(size: 13))
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background((granted ? Color.green : Color.orange).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 5))
            if !granted {
                Button("去授权") { Permissions.request(kind) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .help(kind.why)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }
}

/// 应用标识：三条**等长**的横杠 + 一个右尖角，和菜单栏模板图同一套形，
/// 只是加了容器和更粗的描边（设计稿 1g 的便签）。
struct AppMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let u = s / 16                       // 设计稿是在 16×16 的格子里画的
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.232)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                         startPoint: .top, endPoint: .bottom))
                Path { p in
                    for y in [4.6, 8.0, 11.4] {
                        p.move(to: CGPoint(x: 3 * u, y: y * u))
                        p.addLine(to: CGPoint(x: 9.4 * u, y: y * u))
                    }
                    p.move(to: CGPoint(x: 11.6 * u, y: 5.6 * u))
                    p.addLine(to: CGPoint(x: 13.6 * u, y: 8 * u))
                    p.addLine(to: CGPoint(x: 11.6 * u, y: 10.4 * u))
                }
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
