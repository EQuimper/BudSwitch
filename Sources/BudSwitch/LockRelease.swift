import AppKit
import CoreAudio
import IOBluetooth

/// Lets go of the selected headphones when the Mac locks or sleeps, so the iPhone can take them.
/// On lock it waits while the Mac is still playing through them, checking again every 15 seconds.
@MainActor
final class LockRelease {
    private let headphones: Headphones
    private var observers: [NSObjectProtocol] = []
    private var retry: Timer?

    init(headphones: Headphones) {
        self.headphones = headphones
        let distributed = DistributedNotificationCenter.default()
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked() }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRetrying() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
        ]
    }

    private func screenLocked() {
        stopRetrying()
        retry = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseWhenIdle() }
        }
        releaseWhenIdle()
    }

    private func releaseWhenIdle() {
        guard let device = headphones.selected, device.isConnected() else { return stopRetrying() }
        guard !isPlaying(device) else { return }
        headphones.release(device)
        stopRetrying()
    }

    private func willSleep() {
        stopRetrying()
        if let device = headphones.selected, device.isConnected() {
            headphones.release(device)
        }
    }

    private func stopRetrying() {
        retry?.invalidate()
        retry = nil
    }

    /// Whether any app has audio running on the headphones' output, which CoreAudio names "<ADDRESS>:output".
    private func isPlaying(_ device: IOBluetoothDevice) -> Bool {
        var uid = "\(device.addressString.uppercased()):output" as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) { uid in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), uid, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running)
        return running != 0
    }
}
