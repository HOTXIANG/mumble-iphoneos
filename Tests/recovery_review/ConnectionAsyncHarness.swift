import Foundation

// Only the controller and logging boundary are faked. The runner compiles the
// production ConnectionAsync.swift directly, so continuation/observer behavior
// is exercised by the same code shipped in the app.
final class MUConnectionController: NSObject {
    var connectionRequestGeneration: UInt = 0
    var connectCount = 0
    var disconnectCount = 0
    var hasRequest = false

    func connect(toHostname: String, port: UInt, withUsername: String,
                 andPassword: String?, certificateRef: Data?, displayName: String?) {
        if hasRequest { emit(.muConnectionClosed) }
        connectionRequestGeneration &+= 1
        connectCount += 1
        hasRequest = true
        emit(.muConnectionConnecting)
    }
    func disconnectFromServer() {
        disconnectCount += 1
        hasRequest = false
        emit(.muConnectionClosed)
    }
    func isConnected() -> Bool { hasRequest }
    func emit(_ name: Notification.Name, generation: UInt? = nil, message: String? = nil) {
        var info: [AnyHashable: Any] = ["requestGeneration": NSNumber(value: generation ?? connectionRequestGeneration)]
        if let message { info["message"] = message }
        NotificationCenter.default.post(name: name, object: self, userInfo: info)
    }
}

enum MumbleError: Error, Equatable { case connectionFailed(reason: String) }
struct TestLogger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
enum MumbleLogger { static let connection = TestLogger() }
extension Notification.Name {
    static let muConnectionOpened = Notification.Name("MUConnectionOpenedNotification")
    static let muConnectionClosed = Notification.Name("MUConnectionClosedNotification")
    static let muConnectionConnecting = Notification.Name("MUConnectionConnectingNotification")
    static let muConnectionError = Notification.Name("MUConnectionErrorNotification")
}

@main
struct ConnectionAsyncHarness {
    @MainActor static func start(_ controller: MUConnectionController) -> Task<Void, Error> {
        Task { try await controller.connectAsync(to: "127.0.0.1", port: 64738, username: "test") }
    }
    @MainActor static func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    static func expectCancelled(_ task: Task<Void, Error>) async {
        do { try await task.value; fatalError("Expected CancellationError") }
        catch is CancellationError {}
        catch { fatalError("Unexpected error: \(error)") }
    }
    @MainActor static func main() async throws {
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { fatalError("Continuation did not complete within 10 seconds") }
        }
        defer { watchdog.cancel() }

        let controller = MUConnectionController()
        let successful = start(controller)
        await settle()
        precondition(controller.connectCount == 1)
        controller.emit(.muConnectionOpened)
        controller.emit(.muConnectionOpened)
        controller.emit(.muConnectionError, message: "late failure")
        controller.emit(.muConnectionClosed)
        try await successful.value
        controller.emit(.muConnectionOpened)
        await settle()
        precondition(controller.disconnectCount == 0)
        print("PASS success followed by duplicate/error/closed events completes once")

        let failed = start(controller)
        await settle()
        controller.emit(.muConnectionError, message: "intentional transport error")
        controller.emit(.muConnectionClosed)
        do { try await failed.value; fatalError("Expected transport failure") }
        catch let error as MumbleError {
            precondition(error == .connectionFailed(reason: "intentional transport error"))
        }
        print("PASS error followed by closed preserves the original error")

        let cancelled = start(controller)
        await settle()
        cancelled.cancel()
        await expectCancelled(cancelled)
        precondition(controller.disconnectCount == 1)
        controller.emit(.muConnectionOpened)
        print("PASS Task cancellation ends only its own pending connection")

        let preCancelled = start(controller)
        preCancelled.cancel()
        let countBefore = controller.connectCount
        await expectCancelled(preCancelled)
        precondition(controller.connectCount == countBefore)
        print("PASS already cancelled Task does not begin a connection")

        let externallyClosed = start(controller)
        await settle()
        controller.disconnectFromServer()
        await expectCancelled(externallyClosed)
        precondition(controller.disconnectCount == 2)
        print("PASS external disconnect releases the suspended continuation")

        let superseded = start(controller)
        await settle()
        let oldGeneration = controller.connectionRequestGeneration
        let replacement = start(controller)
        await settle()
        superseded.cancel()
        controller.emit(.muConnectionOpened, generation: oldGeneration)
        controller.emit(.muConnectionError, generation: oldGeneration, message: "stale")
        controller.emit(.muConnectionOpened)
        await expectCancelled(superseded)
        try await replacement.value
        precondition(controller.disconnectCount == 2)
        print("PASS replacement isolates generations and stale Task cancellation")

        let isolated = start(controller)
        await settle()
        let otherController = MUConnectionController()
        otherController.connectionRequestGeneration = controller.connectionRequestGeneration
        otherController.emit(.muConnectionError, message: "unrelated controller")
        otherController.emit(.muConnectionOpened)
        await settle()
        controller.emit(.muConnectionOpened)
        try await isolated.value
        print("PASS unrelated controller notifications are ignored")
        print("ConnectionAsync production-source harness: 7 scenarios passed")
    }
}
