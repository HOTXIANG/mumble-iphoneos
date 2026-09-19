import Foundation

struct MumbleActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var speakers: [String]
        var userCount: Int
        var channelName: String
        var isSelfMuted: Bool
        var isSelfDeafened: Bool
    }
    var serverName: String
}
struct ActivityContent<State: Sendable>: Sendable {
    var state: State
    var staleDate: Date?
}
enum ActivityState { case active, stale, ended, dismissed }
enum DismissalPolicy { case immediate }
struct ActivityAuthorizationInfo { var areActivitiesEnabled = true }

@MainActor
final class TestActivity {
    static var activities: [TestActivity] = []
    static var writeDelay: UInt64 = 50_000_000
    static var concurrentWrites = 0
    static var maxConcurrentWrites = 0
    let id = UUID().uuidString
    let attributes: MumbleActivityAttributes
    var activityState = ActivityState.active
    var content: ActivityContent<MumbleActivityAttributes.ContentState>
    var updates: [MumbleActivityAttributes.ContentState] = []
    var ended = false

    init(attributes: MumbleActivityAttributes, content: ActivityContent<MumbleActivityAttributes.ContentState>) {
        self.attributes = attributes
        self.content = content
    }
    static func request(attributes: MumbleActivityAttributes, content: ActivityContent<MumbleActivityAttributes.ContentState>, pushType: String?) throws -> TestActivity {
        let activity = TestActivity(attributes: attributes, content: content)
        activities.append(activity)
        return activity
    }
    func update(_ content: ActivityContent<MumbleActivityAttributes.ContentState>) async {
        Self.concurrentWrites += 1
        Self.maxConcurrentWrites = max(Self.maxConcurrentWrites, Self.concurrentWrites)
        let delay = Self.writeDelay
        await Task.detached { try? await Task.sleep(nanoseconds: delay) }.value
        updates.append(content.state)
        self.content = content
        Self.concurrentWrites -= 1
    }
    func end(_ content: ActivityContent<MumbleActivityAttributes.ContentState>, dismissalPolicy: DismissalPolicy) async {
        await Task.detached { try? await Task.sleep(nanoseconds: 200_000_000) }.value
        self.content = content
        ended = true
        activityState = .ended
        Self.activities.removeAll { $0 === self }
    }
}
struct Log { func info(_ message: String) {} ; func error(_ message: String) {} }
struct MumbleLogger { static let handoff = Log() }
@MainActor
final class MKUser {
    let sessionID: UInt
    var name: String
    var muted = false
    var serverMuted = false
    var deafened = false
    var talking = 0
    var currentChannel: MKChannel?
    init(_ session: UInt, _ name: String) { self.sessionID = session; self.name = name }
    func session() -> UInt { sessionID }
    func userName() -> String? { name }
    func talkState() -> (rawValue: Int, unused: Int) { (talking, 0) }
    func isMuted() -> Bool { serverMuted }
    func isSelfMuted() -> Bool { muted }
    func isSelfDeafened() -> Bool { deafened }
    func channel() -> MKChannel? { currentChannel }
}
@MainActor
final class MKChannel {
    var members: [MKUser]
    init(_ members: [MKUser]) { self.members = members }
    func users() -> Any? { members }
}
@MainActor
final class MKServerModel {
    let user: MKUser
    init(_ user: MKUser) { self.user = user }
    func connectedUser() -> MKUser? { user }
}
@MainActor
final class ServerModelManager {
    var isConnected = true
    var serverModel: MKServerModel?
    var serverName: String? = "Server A"
    var currentNotificationTitle = "Lounge"
    var boundListeningSessionScope: String? = "a:64738:me"
    var liveActivity: TestActivity?
    var liveActivitySessionScope: String?
    var lastLiveActivityContentState: MumbleActivityAttributes.ContentState?
    var pendingLiveActivityContent: (state: MumbleActivityAttributes.ContentState, forceRefresh: Bool)?
    var pendingLiveActivityUpdateTask: Task<Void, Never>?
    var liveActivityUpdateGeneration: UInt = 0
    var liveActivitiesBeingEnded: Set<String> = []
    var keepAliveTimer: Timer?
    var handoffUpdateCount = 0
    func updateHandoffAudioState() { handoffUpdateCount += 1 }
    func displayName(for user: MKUser) -> String { user.name }
}

@main
struct Harness {
    @MainActor
    static func waitFor(_ description: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for \(description)")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    static func main() async throws {
        let me = MKUser(1, "Me")
        let bob = MKUser(2, "Bob")
        bob.talking = 1
        let channel = MKChannel([bob, me])
        me.currentChannel = channel
        let manager = ServerModelManager()
        manager.serverModel = MKServerModel(me)
        manager.startLiveActivity()
        let first = manager.liveActivity!
        precondition(first.content.state.channelName == "Lounge" && first.content.state.userCount == 2)
        precondition(first.content.state.speakers == ["Bob"])
        for _ in 0..<30 { manager.updateLiveActivity(syncHandoffAudioState: false) }
        await manager.pendingLiveActivityUpdateTask?.value
        precondition(first.updates.isEmpty, "Identical snapshots should not write")
        for index in 0..<30 {
            manager.currentNotificationTitle = "Channel \(index)"
            manager.updateLiveActivity(syncHandoffAudioState: false)
        }
        await manager.pendingLiveActivityUpdateTask?.value
        precondition(first.updates.count == 1 && first.content.state.channelName == "Channel 29", "A burst must merge to its latest snapshot")
        bob.muted = true
        manager.updateLiveActivity(syncHandoffAudioState: false)
        await manager.pendingLiveActivityUpdateTask?.value
        precondition(first.content.state.speakers.isEmpty, "Muted users must not remain speaking")
        let initialTimer = manager.keepAliveTimer!
        initialTimer.invalidate()
        manager.keepAliveTimer = nil
        let updatesBeforeReconnect = first.updates.count
        first.activityState = .stale
        first.content.staleDate = Date().addingTimeInterval(-10)
        manager.startLiveActivity()
        precondition(manager.liveActivity === first && manager.keepAliveTimer!.isValid, "Reconnect must resume heartbeat on the same activity")
        await manager.pendingLiveActivityUpdateTask?.value
        precondition(first.updates.count == updatesBeforeReconnect + 1, "Reconnect must immediately refresh an identical stale snapshot")
        precondition(first.content.staleDate! > Date(), "Reconnect must extend staleDate without waiting for the timer")
        let beforeHeartbeat = manager.handoffUpdateCount
        let writesBeforeHeartbeat = first.updates.count
        manager.keepAliveTimer!.fire()
        try await waitFor("heartbeat write") { first.updates.count > writesBeforeHeartbeat }
        precondition(manager.handoffUpdateCount == beforeHeartbeat, "Heartbeat must not synchronize Handoff audio")

        // Enqueue a state, then return to the last delivered state while its write
        // is suspended. The second write must restore the newest state in order.
        TestActivity.writeDelay = 300_000_000
        let baseline = manager.currentNotificationTitle
        manager.currentNotificationTitle = "Transient"
        manager.updateLiveActivity(syncHandoffAudioState: false)
        try await waitFor("suspended transient write") { TestActivity.concurrentWrites == 1 }
        manager.currentNotificationTitle = baseline
        manager.updateLiveActivity(syncHandoffAudioState: false)
        await manager.pendingLiveActivityUpdateTask?.value
        precondition(first.content.state.channelName == baseline, "Reverting during an in-flight write must not be dropped")
        precondition(TestActivity.maxConcurrentWrites == 1, "Updates for one activity must be serial")

        manager.currentNotificationTitle = "In flight"
        manager.updateLiveActivity(syncHandoffAudioState: false)
        try await waitFor("suspended write before ending") { TestActivity.concurrentWrites == 1 }
        manager.endLiveActivity()
        precondition(manager.liveActivity == nil && manager.keepAliveTimer == nil)
        manager.startLiveActivity()
        let second = manager.liveActivity!
        precondition(second !== first, "An activity being ended must not be reused")
        try await waitFor("old activity to end") { first.ended }
        precondition(first.ended && manager.liveActivity === second, "Old async end must not detach the new activity")

        manager.serverName = "Server B"
        manager.boundListeningSessionScope = "b:64738:me"
        manager.startLiveActivity()
        let third = manager.liveActivity!
        precondition(third !== second && third.attributes.serverName == "Server B")
        try await waitFor("previous server activity to end") { second.ended }
        precondition(second.ended && manager.liveActivity === third)
        let writesBeforeCancellation = third.updates.count
        manager.currentNotificationTitle = "Must be cancelled"
        manager.updateLiveActivity(syncHandoffAudioState: false)
        manager.endLiveActivity()
        try await waitFor("activity with a cancelled write to end") { third.ended }
        precondition(third.updates.count == writesBeforeCancellation, "Ending during the debounce window must cancel the queued write")
        print("PASS: accurate initial content, deduplication, burst coalescing, mute filtering, reconnect heartbeat and immediate staleDate refresh, Handoff isolation, serial writes, in-flight reversion, end/reconnect race, server switching, debounce cancellation")
    }
}
