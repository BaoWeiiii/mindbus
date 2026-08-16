import Cocoa
import SwiftUI
import Carbon.HIToolbox

/// accessory App 抢前台的唯一正确姿势。
/// macOS 14+ 用 cooperative `activate()`——在「用户刚双击启动 / 点击菜单栏 / 按全局热键」
/// 这些有用户意图授权的上下文里会真正激活；老式 `activate(ignoringOtherApps:)`
/// 在 14+ 被系统降权忽略，表现为「窗口浮着但不获焦、菜单栏还是别人的」。
@MainActor
func activateApp() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 把窗口唤到当前 Space 并置前。
/// 不给窗口常驻 `.moveToActiveSpace`：常驻时每次切 Space 窗口都会被重新插入
/// 目标桌面的窗口栈、丢掉原有 z-order——表现为「切走再切回，别的窗口盖上来了」。
/// 只在唤起瞬间挂 flag 把窗口拉到当前桌面，落地即摘，窗口固定回所在 Space。
@MainActor
func summonToActiveSpace(_ window: NSWindow) {
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async {
        window.collectionBehavior.remove(.moveToActiveSpace)
    }
}

/// Menubar 图标 + Popover 管理
/// 左键 = TrayPanel popover；右键 = NSMenu（打开聊天记录 / 设置 / 退出）。
@MainActor
class StatusBarController {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover
    private var onboardingWindow: NSWindow?

    init() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua) // 强制亮色

        setupStatusItem()
        setupPopoverContent()
        registerGlobalShortcuts()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        button.setAccessibilityLabel("MindBus")

        // 菜单栏专用单色伴生符号：紧裁切 + template tint，自动适配浅色、深色和彩色菜单栏。
        if let url = Bundle.module.url(forResource: "menubar-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 20, height: 16)
            image.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: "MindBus")?
                .withSymbolConfiguration(config)
        }
        button.action = #selector(togglePopover)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopoverContent() {
        popover.contentViewController = NSHostingController(rootView: TrayPanelView())
    }

    @objc private func togglePopover() {
        // 右键 → 快捷菜单（打开聊天记录/设置/退出）；左键保持 popover
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopoverContent()
        }
    }

    /// 右键菜单：临时挂 menu → performClick 弹出 → 立刻置 nil。
    /// 若常驻 statusItem.menu，左键也会弹菜单、popover 永远打不开——所以弹完必须摘掉。
    private func showContextMenu() {
        guard let statusItem else { return }
        if popover.isShown { popover.performClose(nil) }

        // 每次右键都重建菜单，标题实时读 L10n——语言切换后无需任何刷新钩子
        let s = L10n.shared.s
        let menu = NSMenu()
        let open = NSMenuItem(title: s.openConversationBrowser, action: #selector(openConversationBrowser), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: s.settingsTitle, action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: s.quitMindBus, action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func togglePopoverContent() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // accessory app 弹 popover 时不 active，首次点击会被「窗口激活」吃掉。
            // 不切 .regular，避免关窗退出 / Dock 闪烁。
            activateApp()
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc @MainActor private func openConversationBrowser() {
        ConversationBrowserWindow.shared.show()
    }

    // MARK: - Onboarding

    func showOnboarding() {
        let wizardView = SetupWizardView {
            self.onboardingWindow?.close()
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            // 完成页承诺「对话都在这了」——点完成直接带用户去看，
            // 否则窗口一关只剩菜单栏图标，新用户不知道对话库在哪。
            ConversationBrowserWindow.shared.show()
        }

        let hostingController = NSHostingController(rootView: wizardView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.shared.s.wizardWindowTitle
        window.setContentSize(NSSize(width: 700, height: 500))
        window.styleMask = [.titled, .closable]
        window.level = .floating // 保持在最前面，不被系统设置盖住
        // 程序化 NSWindow 默认 isReleasedWhenClosed=true，与 ARC 强引用叠加
        // 是关窗后间歇 EXC_BAD_ACCESS 的经典来源（Browser/Settings 窗均已设 false）
        window.isReleasedWhenClosed = false
        // 窗口跟人走：在哪个桌面（Space）唤起就出现在哪——默认行为是系统切去
        // 窗口上次所在的 Space「找窗口」，多桌面下体感即「打开跑到别的桌面去了」。
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.appearance = NSAppearance(named: .aqua) // 内容为 DSLight 亮色 token，暗色系统下必须锁亮色
        window.center()
        window.makeKeyAndOrderFront(nil)
        // 首启双击 = 用户意图授权，cooperative activate 会真正把向导带到前台并获焦
        activateApp()

        self.onboardingWindow = window
    }

    // MARK: - 全局快捷键

    private func registerGlobalShortcuts() {
        // Cmd+Shift+H — 打开聊天记录。Carbon RegisterEventHotKey（替代
        // NSEvent.addGlobalMonitorForEvents）：免辅助功能授权（monitor 未授权 = 死键且从不提示）、
        // 免逐键唤醒本进程（系统只在命中组合键时回调）、自家窗口前台时同样生效（monitor 收不到）。
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_H),
                                     modifiers: UInt32(cmdKey | shiftKey)) {
            Task { @MainActor in ConversationBrowserWindow.shared.show() }
        }

        // TrayPanel「打开聊天记录」点击：关 popover + 打开独立窗口
        NotificationCenter.default.addObserver(forName: .openConversationBrowser, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
                ConversationBrowserWindow.shared.show()
            }
        }
    }

}

// MARK: - Carbon 全局热键

/// Carbon RegisterEventHotKey 的最小封装（不引第三方库）。
/// 回调经 GetApplicationEventTarget 派发到主线程 RunLoop；handler 内自行切 MainActor。
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private init() {}

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1
    private static let signature: OSType = 0x4D42_4855   // 'MBHU'

    /// keyCode 用 Carbon kVK_* 常量；modifiers 用 Carbon cmdKey/shiftKey/optionKey/controlKey 组合。
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if eventHandlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            // C 函数指针不能捕获上下文——self 经 userData 传入
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(event,
                                            EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil,
                                            MemoryLayout<EventHotKeyID>.size,
                                            nil,
                                            &hkID)
                guard err == noErr, hkID.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.handlers[hkID.id]?()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        }

        let id = nextId
        nextId += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs.append(ref)   // 持有引用：app 生命周期内不注销
        } else {
            NSLog("[hotkey] RegisterEventHotKey failed (status=%d)", status)
        }
    }
}
