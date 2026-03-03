//
//  MUStatusBarController.swift
//  Mumble
//
//  macOS menu bar status item — shows current voice state (talking / muted / deafened).
//

#if os(macOS)
import AppKit
import SwiftUI

/// Manages an NSStatusItem that reflects the local user's voice state.
///
/// States (priority high → low):
///   1. **Self-deafened** → red speaker.slash  (不听)
///   2. **Self-muted**   → orange mic.slash   (闭麦)
///   3. **Talking**      → green person.fill  (说话中)
///   4. **Passive**      → gray person.fill   (未说话)
///   5. **Disconnected** → dim person.fill    (未连接，半透明)
@MainActor
final class MUStatusBarController: NSObject {

    // MARK: - State enum

    enum VoiceState: Equatable {
        case disconnected
        case passive        // in channel, not talking
        case talking        // in channel, actively talking
        case selfMuted      // 闭麦
        case selfDeafened   // 不听
    }

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var currentState: VoiceState = .disconnected
    private var observers: [NSObjectProtocol] = []
    private var menu: NSMenu?

    // MARK: - Lifecycle

    func setup() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        // Build the right-click menu
        buildMenu()

        // Set initial icon
        updateIcon()

        // Register for all relevant notifications
        registerNotifications()

        print("🔵 MUStatusBarController: Status bar item created")
    }

    func teardown() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let m = NSMenu()

        let muteItem = NSMenuItem(
            title: NSLocalizedString("Mute / Unmute", comment: ""),
            action: #selector(toggleMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.image = makeMenuItemImage(symbolName: "mic.slash.fill")
        m.addItem(muteItem)

        let deafenItem = NSMenuItem(
            title: NSLocalizedString("Deafen / Undeafen", comment: ""),
            action: #selector(toggleDeafen),
            keyEquivalent: ""
        )
        deafenItem.target = self
        deafenItem.image = makeMenuItemImage(symbolName: "speaker.slash.fill")
        m.addItem(deafenItem)

        m.addItem(NSMenuItem.separator())

        let disconnectItem = NSMenuItem(
            title: NSLocalizedString("Disconnect", comment: ""),
            action: #selector(disconnect),
            keyEquivalent: ""
        )
        disconnectItem.target = self
        disconnectItem.image = makeMenuItemImage(symbolName: "xmark.circle")
        m.addItem(disconnectItem)

        menu = m
        statusItem?.menu = m
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        guard let m = menu else { return }

        let isConnected = MUConnectionController.shared()?.isConnected() == true

        // Mute item
        if let muteItem = m.items.first(where: { $0.action == #selector(toggleMute) }) {
            muteItem.isEnabled = isConnected
            if isConnected, let user = MUConnectionController.shared()?.serverModel?.connectedUser() {
                muteItem.title = user.isSelfMuted()
                    ? NSLocalizedString("Unmute", comment: "")
                    : NSLocalizedString("Mute", comment: "")
                muteItem.image = makeMenuItemImage(
                    symbolName: user.isSelfMuted() ? "mic.fill" : "mic.slash.fill"
                )
            } else {
                muteItem.title = NSLocalizedString("Mute / Unmute", comment: "")
                muteItem.image = makeMenuItemImage(symbolName: "mic.slash.fill")
            }
        }

        // Deafen item
        if let deafenItem = m.items.first(where: { $0.action == #selector(toggleDeafen) }) {
            deafenItem.isEnabled = isConnected
            if isConnected, let user = MUConnectionController.shared()?.serverModel?.connectedUser() {
                deafenItem.title = user.isSelfDeafened()
                    ? NSLocalizedString("Undeafen", comment: "")
                    : NSLocalizedString("Deafen", comment: "")
                deafenItem.image = makeMenuItemImage(
                    symbolName: user.isSelfDeafened() ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
            } else {
                deafenItem.title = NSLocalizedString("Deafen / Undeafen", comment: "")
                deafenItem.image = makeMenuItemImage(symbolName: "speaker.slash.fill")
            }
        }

        // Disconnect item
        if let disconnectItem = m.items.first(where: { $0.action == #selector(disconnect) }) {
            disconnectItem.title = NSLocalizedString("Disconnect", comment: "")
            disconnectItem.isEnabled = isConnected
            disconnectItem.image = makeMenuItemImage(symbolName: "xmark.circle")
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleMute() {
        guard let serverModel = MUConnectionController.shared()?.serverModel,
              let user = serverModel.connectedUser() else { return }
        let newMuted = !user.isSelfMuted()
        serverModel.setSelfMuted(newMuted, andSelfDeafened: user.isSelfDeafened())
        // The delegate notification will update the icon automatically
    }

    @objc private func toggleDeafen() {
        guard let serverModel = MUConnectionController.shared()?.serverModel,
              let user = serverModel.connectedUser() else { return }
        let newDeafened = !user.isSelfDeafened()
        if newDeafened {
            serverModel.setSelfMuted(true, andSelfDeafened: true)
        } else {
            serverModel.setSelfMuted(false, andSelfDeafened: false)
        }
    }

    @objc private func disconnect() {
        NotificationCenter.default.post(name: .mumbleInitiateDisconnect, object: nil)
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default

        // Connection open / close
        observers.append(center.addObserver(
            forName: .muConnectionOpened, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onConnectionChanged(connected: true)
            }
        })

        observers.append(center.addObserver(
            forName: .muConnectionClosed, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onConnectionChanged(connected: false)
            }
        })

        // User talk state changed   (carries userSession + talkState)
        observers.append(center.addObserver(
            forName: ServerModelNotificationManager.userTalkStateChangedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let userSession = userInfo["userSession"] as? UInt,
                  let talkState = userInfo["talkState"] as? MKTalkState else { return }
            Task { @MainActor in
                self?.onTalkStateChanged(userSession: userSession, talkState: talkState)
            }
        })

        // User self-mute/deafen state changed (carries userSession)
        observers.append(center.addObserver(
            forName: ServerModelNotificationManager.userStateUpdatedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let userSession = userInfo["userSession"] as? UInt else { return }
            Task { @MainActor in
                self?.onUserStateUpdated(userSession: userSession)
            }
        })
    }

    // MARK: - Notification Handlers

    private func onConnectionChanged(connected: Bool) {
        if connected {
            // Start as passive; will update when talk-state notifications arrive
            currentState = .passive
            // Immediately check mute/deafen
            refreshFromConnectedUser()
        } else {
            currentState = .disconnected
        }
        updateIcon()
        refreshMenuItems()
    }

    private func onTalkStateChanged(userSession: UInt, talkState: MKTalkState) {
        guard let connectedUser = MUConnectionController.shared()?.serverModel?.connectedUser(),
              connectedUser.session() == userSession else { return }

        // Mute / deafen takes precedence
        if connectedUser.isSelfDeafened() {
            currentState = .selfDeafened
        } else if connectedUser.isSelfMuted() {
            currentState = .selfMuted
        } else {
            currentState = (talkState == MKTalkStateTalking ||
                            talkState == MKTalkStateWhispering ||
                            talkState == MKTalkStateShouting) ? .talking : .passive
        }
        updateIcon()
    }

    private func onUserStateUpdated(userSession: UInt) {
        guard let connectedUser = MUConnectionController.shared()?.serverModel?.connectedUser(),
              connectedUser.session() == userSession else { return }
        refreshFromConnectedUser()
        updateIcon()
        refreshMenuItems()
    }

    /// Read current state directly from MKUser
    private func refreshFromConnectedUser() {
        guard let user = MUConnectionController.shared()?.serverModel?.connectedUser() else {
            currentState = .disconnected
            return
        }
        if user.isSelfDeafened() {
            currentState = .selfDeafened
        } else if user.isSelfMuted() {
            currentState = .selfMuted
        } else if user.talkState() == MKTalkStateTalking ||
                    user.talkState() == MKTalkStateWhispering ||
                    user.talkState() == MKTalkStateShouting {
            currentState = .talking
        } else {
            currentState = .passive
        }
    }

    // MARK: - Icon rendering

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let config: (symbolName: String, color: NSColor, accessibilityLabel: String)

        switch currentState {
        case .disconnected:
            config = ("person.fill", .tertiaryLabelColor, "Mumble — Disconnected")
        case .passive:
            config = ("person.fill", .secondaryLabelColor, "Mumble — Idle")
        case .talking:
            config = ("person.fill", .systemGreen, "Mumble — Talking")
        case .selfMuted:
            config = ("mic.slash.fill", .systemOrange, NSLocalizedString("Mumble — Muted", comment: ""))
        case .selfDeafened:
            config = ("speaker.slash.fill", .systemRed, NSLocalizedString("Mumble — Deafened", comment: ""))
        }

        let image = makeStatusBarImage(symbolName: config.symbolName, tintColor: config.color)
        button.image = image
        button.toolTip = config.accessibilityLabel

        // Menu will be refreshed on open via NSMenuDelegate, but
        // we also refresh on state changes preemptively.
    }

    /// Renders an SF Symbol at the proper size for the macOS menu bar,
    /// tinted with the given color. We draw it as **non-template** so the tint persists.
    private func makeStatusBarImage(symbolName: String, tintColor: NSColor) -> NSImage? {
        let pointSize: CGFloat = 16
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(paletteColors: [tintColor]))

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) else {
            return nil
        }

        image.isTemplate = false
        return image
    }

    /// Renders a template SF Symbol used for NSMenuItem leading icon.
    private func makeMenuItemImage(symbolName: String) -> NSImage? {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) else {
            return nil
        }
        image.isTemplate = true
        return image
    }
}
#endif

