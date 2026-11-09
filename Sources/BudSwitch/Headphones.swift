import AppKit
import IOBluetooth

/// Paired Bluetooth headphones, and moving the selected pair on and off this Mac.
@MainActor
final class Headphones: NSObject {
    var onChange: () -> Void = {}
    private(set) var all: [IOBluetoothDevice] = []

    private let output: any OutputRouting
    private var outputObservation: AudioOutputObservation?
    /// Only an explicit Mac request may select an output when it becomes available.
    private var pending: (address: String, timeout: Task<Void, Never>)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    init(output: any OutputRouting = MacAudioOutput()) {
        self.output = output
    }

    var selected: IOBluetoothDevice? {
        let address = UserDefaults.standard.string(forKey: "selectedAddress")
        return all.first { $0.addressString == address } ?? all.first { $0.isConnected() } ?? all.first
    }

    func start() {
        outputObservation = AudioOutputObservation { [weak self] in self?.audioRouteChanged() }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        reload()
    }

    /// Re-reads the paired list so newly paired headphones show up.
    func reload() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        all = paired.filter(\.isHeadphones).sorted { $0.displayName < $1.displayName }
        for device in all where device.isConnected() { watchDisconnect(device) }
    }

    func select(_ device: IOBluetoothDevice) {
        UserDefaults.standard.set(device.addressString, forKey: "selectedAddress")
        onChange()
    }

    func isOnMac(_ device: IOBluetoothDevice) -> Bool {
        output.route(for: device.addressString) == .selected
    }

    func connect(_ device: IOBluetoothDevice) {
        let address: String = device.addressString
        guard pending?.address != address else { return }
        cancelPending()
        switch output.route(for: address) {
        case .selected:
            return
        case .available(let id):
            if !output.select(id) { NSSound.beep() }
            onChange()
        case .unavailable:
            // A lingering baseband link cannot be opened again. Reconnect to request an audio endpoint.
            if device.isConnected(), device.closeConnection() != kIOReturnSuccess { return NSSound.beep() }
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.pending = nil
                NSSound.beep()
            }
            pending = (address, timeout)
            if device.openConnection(self) != kIOReturnSuccess {
                cancelPending()
                NSSound.beep()
            }
        }
    }

    func release(_ device: IOBluetoothDevice) {
        cancelPending()
        device.closeConnection()
        onChange()
    }

    func toggle(_ device: IOBluetoothDevice) {
        if pending?.address == device.addressString || isOnMac(device) {
            release(device)
        } else {
            connect(device)
        }
    }

    func audioRouteChanged() {
        defer { onChange() }
        guard let address = pending?.address else { return }
        switch output.route(for: address) {
        case .unavailable:
            return
        case .selected:
            cancelPending()
        case .available(let id):
            cancelPending()
            if !output.select(id) { NSSound.beep() }
        }
    }

    func cancelPending() {
        pending?.timeout.cancel()
        pending = nil
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard disconnectNotifications[device.addressString] == nil else { return }
        disconnectNotifications[device.addressString] = device.register(
            forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    }

    /// Called by IOBluetooth when an `openConnection(_:)` request finishes.
    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard pending?.address == device.addressString else { return }
        if status != kIOReturnSuccess {
            cancelPending()
            NSSound.beep()
        }
        audioRouteChanged()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.isHeadphones else { return }
        if !all.contains(where: { $0.addressString == device.addressString }) {
            reload()
        }
        watchDisconnect(device)
        // Whichever pair lands on the Mac becomes the one the menu, shortcut and lock rule control.
        select(device)
        audioRouteChanged()
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
