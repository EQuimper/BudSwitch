import AppKit
import IOBluetooth

/// Paired Bluetooth headphones, and moving the selected pair on and off this Mac.
@MainActor
final class Headphones: NSObject {
    var onChange: () -> Void = {}
    private(set) var all: [IOBluetoothDevice] = []

    /// Connections requested but not confirmed yet. They count as on the Mac so the menu reacts right away.
    private var pending: Set<String> = []
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    var selected: IOBluetoothDevice? {
        let address = UserDefaults.standard.string(forKey: "selectedAddress")
        return all.first { $0.addressString == address } ?? all.first { $0.isConnected() } ?? all.first
    }

    func start() {
        reload()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        for device in all where device.isConnected() {
            watchDisconnect(device)
        }
    }

    /// Re-reads the paired list so newly paired headphones show up.
    func reload() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        all = paired.filter(\.isHeadphones).sorted { $0.displayName < $1.displayName }
    }

    func select(_ device: IOBluetoothDevice) {
        UserDefaults.standard.set(device.addressString, forKey: "selectedAddress")
        onChange()
    }

    func isOnMac(_ device: IOBluetoothDevice) -> Bool {
        device.isConnected() || pending.contains(device.addressString)
    }

    func connect(_ device: IOBluetoothDevice) {
        guard !isOnMac(device) else { return }
        guard device.openConnection(self) == kIOReturnSuccess else { return NSSound.beep() }
        let address: String = device.addressString
        pending.insert(address)
        onChange()
        // A connection that reports success but never shows up shouldn't stay "on the Mac" forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if self?.pending.remove(address) != nil {
                self?.onChange()
            }
        }
    }

    func release(_ device: IOBluetoothDevice) {
        pending.remove(device.addressString)
        device.closeConnection()
        onChange()
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard disconnectNotifications[device.addressString] == nil else { return }
        disconnectNotifications[device.addressString] = device.register(
            forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    }

    /// Called by IOBluetooth when an `openConnection(_:)` request finishes.
    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard status != kIOReturnSuccess else { return }
        pending.remove(device.addressString)
        NSSound.beep()
        onChange()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.isHeadphones else { return }
        if !all.contains(where: { $0.addressString == device.addressString }) {
            reload()
        }
        pending.remove(device.addressString)
        watchDisconnect(device)
        // Whichever pair lands on the Mac becomes the one the menu, shortcut and lock rule control.
        select(device)
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        disconnectNotifications[device.addressString] = nil
        onChange()
    }
}

extension IOBluetoothDevice {
    var isHeadphones: Bool {
        deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }

    /// The name without the owner prefix macOS adds to Apple headphones ("Emanuel’s AirPods Pro" → "AirPods Pro").
    var displayName: String {
        let name = self.name ?? addressString ?? "Headphones"
        guard let owner = name.range(of: "’s ") ?? name.range(of: "'s ") else { return name }
        return String(name[owner.upperBound...])
    }
}
