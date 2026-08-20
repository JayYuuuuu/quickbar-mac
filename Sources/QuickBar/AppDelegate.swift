import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var quickBar: QuickBarPanel?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Dock 图标、无窗口，纯后台。
        NSApp.setActivationPolicy(.accessory)

        _ = Store.shared
        quickBar = QuickBarPanel()

        menuBar = MenuBarController()
        menuBar?.onShowQuickBar = { [weak self] in
            // 菜单关掉之后再弹，否则菜单本身会立刻把 key window 抢回去。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.quickBar?.show() }
        }
        menuBar?.onOpenSettings = { [weak self] in self?.showSettings(.items) }
        menuBar?.onOpenPermissions = { [weak self] in self?.showOnboarding() }
        menuBar?.onToggleTrigger = { [weak self] in self?.toggleTrigger() }
        menuBar?.onJumpToFinder = { [weak self] in self?.jumpToFinder() }

        FinderService.shared.start()
        PanelService.shared.startWatchingPanelSize()

        EventTapService.shared.onTrigger = { [weak self] _ in self?.quickBar?.toggle() }
        EventTapService.shared.onJumpToFinder = { [weak self] in self?.jumpToFinder() }

        if Permissions.allGranted {
            EventTapService.shared.start()
            LoginItem.set(Store.shared.settings.launchAtLogin)
        } else {
            showOnboarding()
        }

        Updater.shared.startScheduledChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.saveNow()
        EventTapService.shared.stop()
    }

    // MARK: - 动作

    private func jumpToFinder() {
        let path = FinderService.shared.refresh()
        if PanelService.shared.currentPanel() != nil {
            PanelService.shared.jump(to: path)
        } else {
            Actions.openFolder(path)
        }
    }

    private func toggleTrigger() {
        if EventTapService.shared.isRunning {
            EventTapService.shared.stop()
        } else {
            EventTapService.shared.start()
        }
    }

    private func showSettings(_ section: SettingsSection) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(section: section) }
        settingsWindow?.present()
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                if Permissions.allGranted {
                    EventTapService.shared.start()
                    LoginItem.set(Store.shared.settings.launchAtLogin)
                }
            }
        }
        onboardingWindow?.present()
    }
}
