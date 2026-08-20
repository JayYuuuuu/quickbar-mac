import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var menuBar: MenuBarController?
    private var quickBar: QuickBarPanel?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Dock 图标、无窗口，纯后台。
        NSApp.setActivationPolicy(.accessory)

        MainMenu.install()

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
        menuBar?.onOpenNewestBatch = {
            guard let batch = MaterialFeed.shared.newest else { return }
            Actions.openFolder(batch.path)
        }

        FinderService.shared.start()
        Availability.shared.start()
        // 点素材批次的完成通知要能直接开那个文件夹，所以委托得在 MaterialFeed 起来之前装好。
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        MaterialFeed.shared.start()
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

    // MARK: - 通知

    /// QuickBar 平时在后台，横幅要在前台也能看到，否则「下完了」这条永远不弹。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 点通知 = 去开那个批次目录。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String, !path.isEmpty {
            Actions.openFolder(path)
        }
        completionHandler()
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
