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
        // 去水印那道工序的入口：Finder 里选中几个商品文件夹 → 主图全部在 PS 里打开（见 MainImages）
        menuBar?.onMainImagesToPhotoshop = {
            MainImages.openInPhotoshop(FinderService.shared.selectionNow())
        }
        // 去水印的收尾：改完的那张按原路径覆盖存回（见 Core/Photoshop.swift）
        menuBar?.onSaveBackAll = { Photoshop.saveBackAll() }
        menuBar?.onRevealPhotoshopFront = { Photoshop.revealFront() }
        menuBar?.onOpenBatchLinksDir = { BatchLinks.revealInFinder() }

        FinderService.shared.start()
        FinderWindowService.shared.start()
        Availability.shared.start()
        // 点素材批次的完成通知要能直接开那个文件夹，所以委托得在 MaterialFeed 起来之前装好。
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        MaterialFeed.shared.start()
        PanelService.shared.startWatchingPanelSize()
        // Finder 里选中商品文件夹 → 旁边浮一颗「主图丢进 PS」（只在 Finder 在前台时才有定时器）
        MainImagesPill.shared.start()

        EventTapService.shared.onTrigger = { [weak self] _ in self?.quickBar?.toggle() }
        EventTapService.shared.onJumpToFinder = { [weak self] in self?.jumpToFinder() }

        if Permissions.allGranted {
            EventTapService.shared.start()
            LoginItem.set(Store.shared.settings.launchAtLogin)
        } else {
            showOnboarding()
        }

        Updater.shared.startScheduledChecks()

        // `quickbar://reveal?path=…` —— 网页上「在 Finder 打开」那个按钮的落点（见 URLScheme.swift）。
        // 🔴 自己装 GetURL 处理器，不只靠 `application(_:open:)`：那个走的是 AppKit 装的默认处理器，
        //    LSUIElement 的后台程序上不同系统版本表现不一致，装了这个才稳。两条都到 URLScheme.handle，
        //    真撞上了那边有两秒去重，不会开两次访达。
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else { return }
        URLScheme.handle(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLScheme.handle(url) }
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
        let folder = FinderService.shared.refresh()
        guard let panel = PanelService.shared.currentPanel() else {
            Actions.openFolder(folder)
            return
        }
        // 打开窗：Finder 里正好只选中一个文件，就直接跳到那个文件。
        // 「前往文件夹」吃完整文件路径，落地就是选中状态（macOS 26 实测），
        // 省掉在长列表里再找一次。
        // 保存窗不这么干：文件路径会被填进名字栏，等于默认覆盖同名文件。
        let target = (panel.kind == .open ? FinderService.shared.currentSelection : nil) ?? folder
        PanelService.shared.jump(to: target)
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
