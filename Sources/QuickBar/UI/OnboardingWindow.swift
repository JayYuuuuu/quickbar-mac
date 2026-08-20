import AppKit
import SwiftUI

/// 首次启动（或权限掉了）时的引导页。只做一件事：把三项授权补齐。
final class OnboardingWindowController: NSWindowController {

    convenience init(onFinish: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: OnboardingView(onFinish: onFinish))
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuickBar"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 440, height: 464))
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

    private var missingCount: Int { Permissions.Kind.allCases.count - granted.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                AppMark().frame(width: 60, height: 60)
                Text(missingCount == 0 ? "全部就绪" : "还差 \(missingCount) 项授权")
                    .font(.system(size: 19, weight: .semibold))
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                ForEach(Permissions.Kind.allCases) { kind in
                    PermissionCard(kind: kind, granted: granted.contains(kind))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)

            Spacer()

            HStack(spacing: 10) {
                Toggle("开机自动启动", isOn: Binding(
                    get: { Store.shared.settings.launchAtLogin },
                    set: { Store.shared.settings.launchAtLogin = $0; LoginItem.set($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("稍后") { onFinish() }
                Button("开始使用") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(missingCount > 0)
                    .help(missingCount > 0 ? "三项都授权后才能开始。" : "")
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 24)
        }
        .onReceive(heartbeat) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        granted = Set(Permissions.Kind.allCases.filter { Permissions.isGranted($0) })
    }
}

private struct PermissionCard: View {
    let kind: Permissions.Kind
    let granted: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill((granted ? Color.green : Color.orange).opacity(0.16))
                Image(systemName: granted ? "checkmark" : "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(granted ? Color.green : Color.orange)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 13))
                Text(granted ? "已授权" : "未授权")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(kind.why)
            }
            Spacer()
            if !granted {
                Button("去授权") { Permissions.request(kind) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(granted ? Color.clear : Color.orange.opacity(0.6), lineWidth: 0.5)
        }
    }
}

/// 应用标识：三条横杠 + 一个右尖角，和菜单栏图标同一套形。
struct AppMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: s * 0.25).fill(Color.accentColor)
                bar(width: s * 0.34, y: s * 0.27, size: s, opacity: 1)
                bar(width: s * 0.46, y: s * 0.46, size: s, opacity: 0.78)
                bar(width: s * 0.25, y: s * 0.65, size: s, opacity: 0.55)
                Path { path in
                    path.move(to: CGPoint(x: s * 0.65, y: s * 0.62))
                    path.addLine(to: CGPoint(x: s * 0.74, y: s * 0.70))
                    path.addLine(to: CGPoint(x: s * 0.65, y: s * 0.78))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: s * 0.06, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func bar(width: CGFloat, y: CGFloat, size: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: size * 0.04)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: size * 0.078)
            .offset(x: size * 0.23, y: y)
    }
}
