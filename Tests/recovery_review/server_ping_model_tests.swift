import Foundation
import SwiftUI

struct PingerHarnessLogger {
    func debug(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}
enum MumbleLogger { static let network = PingerHarnessLogger() }

@main
struct ServerPingModelTests {
    @MainActor
    static func waitFor(_ reason: String, until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            precondition(Date() < deadline, "Timed out: \(reason)")
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    static func drainCallbacks() async {
        // Let both the detached constructor continuation and main actor work run.
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    @MainActor
    static func deliver(_ model: ServerPingModel, ping: Double, users: UInt32 = 2) {
        var result = MKServerPingerResult(version: 0, cur_users: users, max_users: 20, bandwidth: 0, ping: ping)
        model.serverPingerResult(&result)
    }

    @MainActor
    static func stopBeforeDNSReturns() async {
        MUTestPingerReset()
        let gate = MUTestPingerGateNextCreation()!
        let model = ServerPingModel(hostname: "unit.test", port: 64738)
        model.startPinging()
        await waitFor("DNS creation entered") { gate.entered }
        model.stopPinging()
        gate.releaseCreation()
        await waitFor("DNS creation returned") { gate.completed }
        await drainCallbacks()
        let pinger = MUTestPingerAtIndex(0)!
        precondition(!pinger.startedInInitializer, "DNS constructor started the transport before generation validation")
        precondition(pinger.startCount == 0 && pinger.nonNilDelegateCount == 0 && !pinger.active)
        precondition(pinger.delegate() == nil)
        print("PASS stop before DNS completion never binds or starts the result")
    }

    @MainActor
    static func replacementIgnoresOldDNSResult() async {
        MUTestPingerReset()
        let oldGate = MUTestPingerGateNextCreation()!
        let newGate = MUTestPingerGateNextCreation()!
        let model = ServerPingModel(hostname: "unit.test", port: 64738)
        model.startPinging()
        await waitFor("old DNS creation entered") { oldGate.entered }
        model.stopPinging()
        model.startPinging()
        await waitFor("new DNS creation entered") { newGate.entered }
        newGate.releaseCreation()
        await waitFor("new transport started") { MUTestPingerAtIndex(1)!.startCount == 1 }
        let current = MUTestPingerAtIndex(1)!
        precondition((current.delegate() as AnyObject?) === model)
        oldGate.releaseCreation()
        await waitFor("old DNS result returned") { oldGate.completed }
        await drainCallbacks()
        let stale = MUTestPingerAtIndex(0)!
        precondition(stale.startCount == 0 && stale.nonNilDelegateCount == 0 && !stale.active)
        precondition((current.delegate() as AnyObject?) === model && current.active)
        model.stopPinging()
        precondition(current.stopCount == 1 && current.delegate() == nil && !current.active)
        print("PASS start-stop-start installs only the new generation's DNS result")
    }

    @MainActor
    static func startIsIdempotent() async {
        MUTestPingerReset()
        let gate = MUTestPingerGateNextCreation()!
        let model = ServerPingModel(hostname: "unit.test", port: 64738)
        model.startPinging()
        await waitFor("pending creation entered") { gate.entered }
        for _ in 0..<20 { model.startPinging() }
        await drainCallbacks()
        precondition(MUTestPingerCount() == 1, "Repeated start created duplicate pending pingers")
        gate.releaseCreation()
        await waitFor("single transport started") { MUTestPingerAtIndex(0)!.startCount == 1 }
        for _ in 0..<20 { model.startPinging() }
        await drainCallbacks()
        let pinger = MUTestPingerAtIndex(0)!
        precondition(MUTestPingerCount() == 1 && pinger.startCount == 1)
        precondition(pinger.nonNilDelegateCount == 1)
        model.stopPinging()
        print("PASS repeated starts share one pending or active transport")
    }

    @MainActor
    static func pendingDNSDoesNotRetainModel() async {
        MUTestPingerReset()
        let gate = MUTestPingerGateNextCreation()!
        var model: ServerPingModel? = ServerPingModel(hostname: "unit.test", port: 64738)
        weak var weakModel = model
        model?.startPinging()
        await waitFor("pending DNS creation entered") { gate.entered }
        model = nil
        precondition(weakModel == nil, "Detached DNS task retained the model until DNS returned")
        weakModel = nil
        gate.releaseCreation()
        await waitFor("orphaned creation returned") { gate.completed }
        await drainCallbacks()
        let pinger = MUTestPingerAtIndex(0)!
        precondition(pinger.startCount == 0 && pinger.nonNilDelegateCount == 0 && !pinger.active)
        print("PASS model deinitializes while its DNS constructor remains blocked")
    }

    @MainActor
    static func deinitStopsActiveTransport() async {
        MUTestPingerReset()
        var model: ServerPingModel? = ServerPingModel(hostname: "unit.test", port: 64738)
        weak var weakModel = model
        model?.startPinging()
        await waitFor("active transport created") { MUTestPingerCount() == 1 && MUTestPingerAtIndex(0)!.active }
        let pinger = MUTestPingerAtIndex(0)!
        model = nil
        precondition(weakModel == nil)
        weakModel = nil
        precondition(!pinger.active && pinger.stopCount == 1 && pinger.delegate() == nil)
        print("PASS model deinit stops and detaches the active transport")
    }

    @MainActor
    static func callbacksAfterStopAreIgnored() async {
        MUTestPingerReset()
        let model = ServerPingModel(hostname: "unit.test", port: 64738)
        model.startPinging()
        await waitFor("callback transport started") { MUTestPingerCount() == 1 && MUTestPingerAtIndex(0)!.active }
        deliver(model, ping: 0.05)
        // Active callbacks are synchronous on the main queue, not queued Tasks
        // that can leak from the previous run into the next run.
        precondition(model.pingLabel == "50 ms" && model.usersLabel == "2/20")
        model.stopPinging()
        let stoppedPing = model.pingLabel
        let stoppedUsers = model.usersLabel
        deliver(model, ping: 0.999, users: 19)
        await drainCallbacks()
        precondition(model.pingLabel == stoppedPing && model.usersLabel == stoppedUsers)
        print("PASS stopped callbacks do not mutate labels and active callbacks finish synchronously")
    }

    @MainActor
    static func emptyHostDoesNotCreateTransport() async {
        MUTestPingerReset()
        let model = ServerPingModel(hostname: "", port: 64738)
        model.startPinging()
        await drainCallbacks()
        precondition(MUTestPingerCount() == 0)
        print("PASS empty host remains idle")
    }

    @MainActor
    static func main() async {
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { fatalError("ServerPingModel tests did not finish within 20 seconds") }
        }
        defer { watchdog.cancel() }
        await stopBeforeDNSReturns()
        await replacementIgnoresOldDNSResult()
        await startIsIdempotent()
        await pendingDNSDoesNotRetainModel()
        await deinitStopsActiveTransport()
        await callbacksAfterStopAreIgnored()
        await emptyHostDoesNotCreateTransport()
        print("ServerPingModel production-source harness: 7 scenarios passed")
    }
}
