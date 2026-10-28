import AppKit
import Carbon.HIToolbox
import IOBluetooth
import ServiceManagement

@main
@MainActor
enum BudSwitch {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let headphones = Headphones()
    private var hotKey: HotKey?
    private var lockRelease: LockRelease?
    private var updateCheck: UpdateCheck?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        headphones.onChange = { [weak self] in self?.updateIcon() }
        headphones.start()
        hotKey = HotKey(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggle()
        }
        lockRelease = LockRelease(headphones: headphones)
        updateCheck = UpdateCheck()
        registerLoginItemOnFirstLaunch()
        updateIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        headphones.reload()
        let selected = headphones.selected
        let onMac = selected.map(headphones.isOnMac) ?? false

        menu.removeAllItems()
        menu.addItem(item("Mac", checked: onMac, enabled: selected != nil, action: #selector(useMac)))
        menu.addItem(item("iPhone", checked: selected != nil && !onMac, enabled: selected != nil, action: #selector(useIPhone)))
        menu.addItem(.separator())
        menu.addItem(picker(selected: selected))
        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", checked: SMAppService.mainApp.status == .enabled, action: #selector(toggleLaunchAtLogin)))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func picker(selected: IOBluetoothDevice?) -> NSMenuItem {
        let picker = NSMenuItem(title: selected?.displayName ?? "No Headphones", action: nil, keyEquivalent: "")
        guard !headphones.all.isEmpty else {
            picker.isEnabled = false
            return picker
        }
        let submenu = NSMenu()
        for device in headphones.all {
            let row = item(device.displayName, checked: device.addressString == selected?.addressString, action: #selector(select(_:)))
            row.representedObject = device
            submenu.addItem(row)
        }
        picker.submenu = submenu
        return picker
    }

    private func item(_ title: String, checked: Bool, enabled: Bool = true, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func updateIcon() {
        let selected = headphones.selected
        statusItem.button?.image = .menuBarIcon(accessibilityDescription: selected?.displayName ?? "Headphones")
        statusItem.button?.appearsDisabled = !(selected.map(headphones.isOnMac) ?? false)
    }

    private func toggle() {
        guard let device = headphones.selected else { return NSSound.beep() }
        if headphones.isOnMac(device) {
            headphones.release(device)
        } else {
            headphones.connect(device)
        }
    }

    @objc private func useMac() {
        if let device = headphones.selected {
            headphones.connect(device)
        }
    }

    @objc private func useIPhone() {
        if let device = headphones.selected {
            headphones.release(device)
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? IOBluetoothDevice {
            headphones.select(device)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    private func registerLoginItemOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "registeredLoginItem") else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: "registeredLoginItem")
    }
}
