import Combine
import Foundation
import Testing
@testable import bitchat

struct WeshInternetStateMachineTests {
    private typealias Inputs = WeshInternetStateMachine.Inputs

    @Test func defaultsOffAndIgnoresInputsWhileOff() {
        var machine = WeshInternetStateMachine()
        #expect(machine.state == .off)
        machine.handle(.inputs(Inputs(torReady: true, torProgress: 100, relayConnected: true)))
        #expect(machine.state == .off)
        machine.handle(.stallTimeout)
        machine.handle(.retry)
        machine.handle(.foreground)
        #expect(machine.state == .off)
    }

    @Test func toggleOnConnectsThenOnlyTorPlusRelayIsOn() {
        var machine = WeshInternetStateMachine()
        machine.handle(.toggle(true))
        #expect(machine.state == .connecting(torProgress: 0))
        machine.handle(.inputs(Inputs(torProgress: 40)))
        #expect(machine.state == .connecting(torProgress: 40))
        machine.handle(.inputs(Inputs(torReady: true, torProgress: 100)))
        #expect(machine.state == .connecting(torProgress: 100))
        machine.handle(.inputs(Inputs(torReady: true, torProgress: 100, relayConnected: true)))
        #expect(machine.state == .on)
    }

    @Test func losingRelaysReturnsToConnecting() {
        var machine = WeshInternetStateMachine(enabled: true, inputs: Inputs(torReady: true, torProgress: 100, relayConnected: true))
        #expect(machine.state == .on)
        machine.handle(.inputs(Inputs(torReady: true, torProgress: 100, relayConnected: false)))
        #expect(machine.state == .connecting(torProgress: 100))
        machine.handle(.inputs(Inputs(torReady: false, torProgress: 30, relayConnected: false)))
        #expect(machine.state == .connecting(torProgress: 30))
    }

    @Test func aRelayWithoutReadyTorIsAStickyRouteFault() {
        for start in [Inputs(torReady: true, torProgress: 100, relayConnected: true), Inputs(torProgress: 40)] {
            var machine = WeshInternetStateMachine(enabled: true, inputs: start)
            machine.handle(.inputs(Inputs(torReady: false, torProgress: 30, relayConnected: true)))
            #expect(machine.state == .error(.routeFault))
            // Neither recovery of Tor, a network change, a stall nor a resume clears it.
            machine.handle(.inputs(Inputs(networkReachable: false)))
            machine.handle(.inputs(Inputs(torReady: true, torProgress: 100, relayConnected: true)))
            machine.handle(.stallTimeout)
            machine.handle(.background)
            machine.handle(.foreground)
            #expect(machine.state == .error(.routeFault))
            machine.handle(.retry)
            #expect(machine.state == .on)
        }
        var machine = WeshInternetStateMachine(enabled: true, inputs: Inputs(torProgress: 10, relayConnected: true))
        #expect(machine.state == .error(.routeFault))
        machine.handle(.toggle(false))
        #expect(machine.state == .off)
    }

    @Test func stallAndNoNetworkAreErrors() {
        var machine = WeshInternetStateMachine(enabled: true)
        machine.handle(.stallTimeout)
        #expect(machine.state == .error(.torBlocked))

        machine = WeshInternetStateMachine(enabled: true, inputs: Inputs(torReady: true, torProgress: 100))
        machine.handle(.stallTimeout)
        #expect(machine.state == .error(.relaysUnreachable))

        machine = WeshInternetStateMachine(enabled: true)
        machine.handle(.inputs(Inputs(networkReachable: false)))
        #expect(machine.state == .error(.noNetwork))
        // A stall timer from before cannot overwrite a more specific error.
        machine.handle(.stallTimeout)
        #expect(machine.state == .error(.noNetwork))
    }

    @Test func errorLeavesOnRetryOrNetworkChangeOnly() {
        var machine = WeshInternetStateMachine(enabled: true)
        machine.handle(.stallTimeout)
        machine.handle(.inputs(Inputs(torProgress: 50)))
        #expect(machine.state == .error(.torBlocked))
        machine.handle(.retry)
        #expect(machine.state == .connecting(torProgress: 50))

        machine.handle(.inputs(Inputs(networkReachable: false, torProgress: 50)))
        #expect(machine.state == .error(.noNetwork))
        machine.handle(.inputs(Inputs(networkReachable: true, torProgress: 50)))
        #expect(machine.state == .connecting(torProgress: 50))
    }

    @Test func backgroundPausesAndResumeReconnects() {
        var machine = WeshInternetStateMachine(enabled: true, inputs: Inputs(torReady: true, torProgress: 100, relayConnected: true))
        machine.handle(.background)
        #expect(machine.state == .paused)
        machine.handle(.inputs(Inputs()))
        #expect(machine.state == .paused)
        machine.handle(.foreground)
        #expect(machine.state == .connecting(torProgress: 0))
    }

    @Test func toggleOffAndPanicAlwaysWin() {
        for event in [WeshInternetStateMachine.Event.toggle(false), .panic] {
            var machine = WeshInternetStateMachine(enabled: true, inputs: Inputs(torReady: true, torProgress: 100, relayConnected: true))
            machine.handle(event)
            #expect(machine.state == .off)
            machine = WeshInternetStateMachine(enabled: true)
            machine.handle(.background)
            machine.handle(event)
            #expect(machine.state == .off)
            machine.handle(.foreground)
            #expect(machine.state == .off)
        }
    }
}

@MainActor
@Suite(.serialized)
struct WeshInternetModeTests {
    private final class Harness {
        let defaults: UserDefaults
        let inputs = CurrentValueSubject<WeshInternetStateMachine.Inputs, Never>(.init())
        var events: [String] = []
        var torForcible = true
        var keyStorable = true
        var artiExitsInTime = true
        var deleteResults: [Bool] = []
        var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

        init() {
            let suite = "wesh.internet.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }

        var networkEnabled: [Bool] {
            events.compactMap { $0 == "network:on" ? true : $0 == "network:off" ? false : nil }
        }

        @MainActor func make() -> WeshInternetMode {
            WeshInternetMode(defaults: defaults, dependencies: .init(
                forceTor: { self.events.append("forceTor"); return self.torForcible },
                ensureNostrIdentity: { self.events.append("ensureKey"); return self.keyStorable },
                setNetworkEnabled: { self.events.append($0 ? "network:on" : "network:off") },
                retryConnections: { self.events.append("retry") },
                stopTorAndWait: { self.events.append("stopTor"); return self.artiExitsInTime },
                deleteArtiDirectory: {
                    self.events.append("deleteArti")
                    return self.deleteResults.isEmpty ? true : self.deleteResults.removeFirst()
                },
                inputs: inputs.eraseToAnyPublisher(),
                scheduleAfter: { delay, action in self.scheduled.append((delay, action)) }
            ))
        }

        @MainActor func runScheduled() {
            let pending = scheduled
            scheduled.removeAll()
            pending.forEach { $0.action() }
        }
    }

    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private func enabledMode(_ harness: Harness) -> WeshInternetMode {
        let mode = harness.make()
        mode.start()
        mode.acceptDisclosure()
        mode.setEnabled(true)
        return mode
    }

    @Test func defaultOffKeepsTheNetworkDisabledAndClearsArtiAtLaunch() {
        let harness = Harness()
        let mode = harness.make()
        mode.start()
        #expect(mode.state == .off)
        #expect(!mode.isEnabled)
        #expect(mode.needsDisclosure)
        // Off at launch also completes any interrupted panic wipe.
        #expect(harness.events == ["network:off", "deleteArti"])
        #expect(harness.scheduled.isEmpty)
    }

    @Test func firstActivationRequiresTheDisclosureAndForcesTorFirst() {
        let harness = Harness()
        let mode = harness.make()
        mode.start()
        harness.events.removeAll()
        #expect(!mode.setEnabled(true))
        #expect(mode.state == .off)
        #expect(harness.events.isEmpty)

        mode.acceptDisclosure()
        #expect(mode.setEnabled(true))
        #expect(harness.events == ["forceTor", "ensureKey", "network:on"])
        #expect(mode.state == .connecting(torProgress: 0))
        #expect(harness.defaults.bool(forKey: WeshInternetSettings.enabledKey))
        #expect(harness.defaults.bool(forKey: WeshInternetSettings.disclosureAcceptedKey))

        // A new process forces Tor again before restoring the toggle.
        let relaunched = harness.make()
        harness.events.removeAll()
        relaunched.start()
        #expect(harness.events == ["forceTor", "network:on"])
        #expect(relaunched.state == .connecting(torProgress: 0))

        #expect(relaunched.setEnabled(false))
        #expect(relaunched.state == .off)
        #expect(!harness.defaults.bool(forKey: WeshInternetSettings.enabledKey))
        #expect(harness.networkEnabled.last == false)
    }

    @Test func enablingIsRefusedWhenTorCannotBeForced() {
        let harness = Harness()
        harness.torForcible = false
        let mode = harness.make()
        mode.acceptDisclosure()
        #expect(!mode.setEnabled(true))
        #expect(mode.state == .off)
        #expect(!harness.defaults.bool(forKey: WeshInternetSettings.enabledKey))
        #expect(!harness.networkEnabled.contains(true))
        #expect(!harness.events.contains("ensureKey"), "no key is created when Tor cannot be forced")

        harness.torForcible = true
        harness.keyStorable = false
        #expect(!mode.setEnabled(true))
        #expect(!harness.networkEnabled.contains(true))
        harness.torForcible = false

        // Persisted ON but Tor no longer forcible: fault, network stays off.
        harness.defaults.set(true, forKey: WeshInternetSettings.enabledKey)
        let relaunched = harness.make()
        relaunched.start()
        #expect(relaunched.state == .error(.routeFault))
        #expect(!harness.networkEnabled.contains(true))
        relaunched.retry()
        #expect(relaunched.state == .error(.routeFault))
        #expect(!harness.networkEnabled.contains(true))
    }

    @Test func relayWithoutReadyTorDisablesTheNetworkUntilRetry() async {
        let harness = Harness()
        let mode = enabledMode(harness)
        harness.inputs.send(.init(torReady: true, torProgress: 100, relayConnected: true))
        await settle()
        #expect(mode.state == .on)
        harness.events.removeAll()

        harness.inputs.send(.init(torReady: false, torProgress: 90, relayConnected: true))
        await settle()
        #expect(mode.state == .error(.routeFault))
        #expect(harness.events == ["network:off"])

        // Retry while the stale relay flag persists: still faulted, network still off.
        mode.retry()
        #expect(mode.state == .error(.routeFault))
        #expect(harness.networkEnabled == [false])

        harness.inputs.send(.init(torReady: false, torProgress: 90, relayConnected: false))
        await settle()
        mode.retry()
        #expect(mode.state == .connecting(torProgress: 90))
        #expect(Array(harness.events.suffix(3)) == ["forceTor", "network:on", "retry"])
    }

    @Test func connectingStallsIntoErrorAndRetryRestartsTor() async {
        let harness = Harness()
        let mode = enabledMode(harness)
        #expect(harness.scheduled.map(\.delay) == [WeshInternetPolicy.connectingStallSeconds])
        harness.inputs.send(.init(torProgress: 30))
        await settle()
        #expect(mode.state == .connecting(torProgress: 30))
        // Progress does not re-arm the deadline.
        #expect(harness.scheduled.count == 1)
        harness.runScheduled()
        #expect(mode.state == .error(.torBlocked))

        mode.retry()
        #expect(mode.state == .connecting(torProgress: 30))
        #expect(harness.events.last == "retry")
        harness.inputs.send(.init(torReady: true, torProgress: 100, relayConnected: true))
        await settle()
        #expect(mode.state == .on)
        // The stall timer armed by the retry is void once On.
        harness.runScheduled()
        #expect(mode.state == .on)
    }

    @Test func backgroundPausesAndForegroundReconnects() async {
        let harness = Harness()
        let mode = enabledMode(harness)
        harness.inputs.send(.init(torReady: true, torProgress: 100, relayConnected: true))
        await settle()
        #expect(mode.state == .on)
        mode.appDidEnterBackground()
        #expect(mode.state == .paused)
        harness.inputs.send(.init())
        await settle()
        mode.appWillEnterForeground()
        #expect(mode.state == .connecting(torProgress: 0))
    }

    @Test func panicResetsEverythingAndWaitsForArtiBeforeDeleting() async {
        let harness = Harness()
        let mode = enabledMode(harness)
        harness.inputs.send(.init(torReady: true, torProgress: 100, relayConnected: true))
        await settle()
        #expect(mode.state == .on)
        harness.events.removeAll()
        harness.deleteResults = [false, true]

        #expect(mode.wipeForPanic())
        #expect(mode.state == .off)
        #expect(!mode.isEnabled)
        #expect(mode.needsDisclosure)
        #expect(harness.defaults.object(forKey: WeshInternetSettings.enabledKey) == nil)
        #expect(harness.defaults.object(forKey: WeshInternetSettings.disclosureAcceptedKey) == nil)
        // Synchronous: network off, Arti stopped and awaited, then delete and verify (retried inline).
        #expect(harness.events == ["network:off", "stopTor", "deleteArti", "deleteArti"])

        // Inputs after the wipe cannot turn anything back on.
        harness.inputs.send(.init(torReady: true, torProgress: 100, relayConnected: true))
        await settle()
        #expect(mode.state == .off)
        #expect(!mode.setEnabled(true))
        #expect(harness.make().state == .off)
    }

    @Test func panicDeletesArtiEvenIfItDidNotStopButReportsFailure() {
        let harness = Harness()
        let mode = enabledMode(harness)
        harness.events.removeAll()
        harness.artiExitsInTime = false
        // Under duress the directory goes now, not at the next launch.
        #expect(!mode.wipeForPanic())
        #expect(harness.events == ["network:off", "stopTor", "deleteArti"])
        #expect(mode.state == .off)
        // The toggle is absent, so the next launch deletes again whatever Arti recreated.
        harness.events.removeAll()
        harness.make().start()
        #expect(harness.events == ["network:off", "deleteArti"])
    }

    @Test func anInterruptedArtiWipeCompletesAtNextLaunch() {
        let harness = Harness()
        let mode = enabledMode(harness)
        // Arti stopped but the directory survived every attempt.
        harness.deleteResults = [false, false, false]
        #expect(!mode.wipeForPanic())
        harness.events.removeAll()
        // The toggle is absent after panic, so the next launch deletes again.
        harness.make().start()
        #expect(harness.events == ["network:off", "deleteArti"])
        // Arti did not stop: deleted at panic anyway, and again at the next launch.
        let stuck = Harness()
        let stuckMode = enabledMode(stuck)
        stuck.artiExitsInTime = false
        #expect(!stuckMode.wipeForPanic())
        #expect(stuck.events.suffix(2) == ["stopTor", "deleteArti"])
        stuck.events.removeAll()
        stuck.make().start()
        #expect(stuck.events == ["network:off", "deleteArti"])
    }

    @Test func artiDataDirectoryIsTheDirectoryTorManagerUses() throws {
        let url = try #require(WeshInternetPolicy.artiDataDirectory())
        #expect(url.path.hasSuffix("Application Support/bitchat/arti"))
    }

    @Test func pinnedRelaysAreTheSharedUpstreamDefaults() {
        #expect(WeshInternetPolicy.pinnedRelays == ["wss://relay.damus.io", "wss://relay.primal.net", "wss://offchain.pub"])
    }
}
