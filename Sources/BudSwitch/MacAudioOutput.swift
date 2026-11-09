import CoreAudio
import Foundation

enum HeadphoneRoute: Equatable {
    case unavailable, available(AudioDeviceID), selected
}

protocol OutputRouting {
    func route(for address: String) -> HeadphoneRoute
    func select(_ id: AudioDeviceID) -> Bool
}

struct MacAudioOutput: OutputRouting {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    fileprivate static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func value(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> UInt32? {
        var address = property(selector)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: result))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }

    static func deviceID(for address: String) -> AudioDeviceID? {
        // The Bluetooth address in a Core Audio output UID can use either separator.
        let address = address.uppercased()
        for prefix in [address.replacingOccurrences(of: ":", with: "-"), address.replacingOccurrences(of: "-", with: ":")] {
            var uid = "\(prefix):output" as CFString
            var property = property(kAudioHardwarePropertyTranslateUIDToDevice)
            var id = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout.size(ofValue: id))
            let status = withUnsafePointer(to: &uid) {
                AudioObjectGetPropertyData(system, &property, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
            }
            if status == noErr, id != kAudioObjectUnknown, value(kAudioDevicePropertyDeviceIsAlive, on: id) == 1 {
                return id
            }
        }
        return nil
    }

    func route(for address: String) -> HeadphoneRoute {
        guard let id = Self.deviceID(for: address) else { return .unavailable }
        return Self.value(kAudioHardwarePropertyDefaultOutputDevice, on: Self.system) == id ? .selected : .available(id)
    }

    func select(_ id: AudioDeviceID) -> Bool {
        var property = Self.property(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        return AudioObjectSetPropertyData(Self.system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id) == noErr
    }
}

/// A handoff can change the audio route without a Bluetooth disconnect.
final class AudioOutputObservation {
    private let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]
    private let listener: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        listener = { _, _ in MainActor.assumeIsolated { onChange() } }
        for selector in selectors {
            var property = MacAudioOutput.property(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
    }

    deinit {
        for selector in selectors {
            var property = MacAudioOutput.property(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
    }
}
