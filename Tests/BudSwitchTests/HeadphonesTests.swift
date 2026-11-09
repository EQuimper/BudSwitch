import CoreAudio
import IOBluetooth
import Testing
@testable import BudSwitch

private final class LinkedBeats: IOBluetoothDevice {
    var opened = 0
    var closed = 0
    override var addressString: String! { "00-00-00-00-00-01" }
    override func isConnected() -> Bool { true }
    override func openConnection(_ target: Any!) -> IOReturn {
        opened += 1
        return kIOReturnSuccess
    }
    override func closeConnection() -> IOReturn {
        closed += 1
        return kIOReturnSuccess
    }
}

private final class TestOutput: OutputRouting {
    var current: HeadphoneRoute = .unavailable
    var selections: [AudioDeviceID] = []

    func route(for address: String) -> HeadphoneRoute { current }
    func select(_ id: AudioDeviceID) -> Bool {
        selections.append(id)
        return true
    }
}

@Test @MainActor func bluetoothLinkWithoutAnAudioOutputDoesNotCheckMac() {
    #expect(!Headphones().isOnMac(LinkedBeats()))
}

@Test @MainActor func handoffUpdatesTheIndicatorWithoutABluetoothDisconnect() {
    let beats = LinkedBeats()
    let output = TestOutput()
    let headphones = Headphones(output: output)
    var states: [Bool] = []
    headphones.onChange = { states.append(headphones.isOnMac(beats)) }

    for route in [HeadphoneRoute.selected, .available(42), .unavailable, .selected] {
        output.current = route
        headphones.audioRouteChanged()
    }

    #expect(states == [true, false, false, true])
    #expect(output.selections.isEmpty)
    #expect(beats.opened == 0 && beats.closed == 0)
}

@Test @MainActor func shortcutReclaimsAnAvailableOutputAndWaitsForConfirmation() {
    let beats = LinkedBeats()
    let output = TestOutput()
    let headphones = Headphones(output: output)
    output.current = .available(42)

    headphones.toggle(beats)
    #expect(output.selections == [42])
    #expect(!headphones.isOnMac(beats))
    #expect(beats.opened == 0 && beats.closed == 0)

    output.current = .selected
    headphones.audioRouteChanged()
    #expect(headphones.isOnMac(beats))
    headphones.toggle(beats)
    #expect(beats.closed == 1)
}

@Test @MainActor func explicitConnectWaitsForTheAudioEndpoint() {
    let beats = LinkedBeats()
    let output = TestOutput()
    let headphones = Headphones(output: output)

    headphones.connect(beats)
    headphones.connect(beats)
    #expect(beats.closed == 1 && beats.opened == 1)
    #expect(!headphones.isOnMac(beats))

    output.current = .available(42)
    headphones.audioRouteChanged()
    headphones.audioRouteChanged()
    #expect(output.selections == [42])
    #expect(!headphones.isOnMac(beats))
}

@Test @MainActor func releasingAPendingConnectionDoesNotReclaimTheRoute() {
    let beats = LinkedBeats()
    let output = TestOutput()
    let headphones = Headphones(output: output)
    headphones.connect(beats)
    headphones.release(beats)
    output.current = .available(42)
    headphones.audioRouteChanged()
    #expect(output.selections.isEmpty)
    #expect(!headphones.isOnMac(beats))
}
