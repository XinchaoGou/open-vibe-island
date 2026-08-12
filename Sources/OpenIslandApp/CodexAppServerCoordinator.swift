import AppKit
import Foundation
import OpenIslandCore

/// Manages the lifecycle of the Codex app-server connection.
///
/// Automatically starts the app-server subprocess when Codex.app is
/// detected, and tears it down when the app quits.  Converts incoming
/// app-server notifications into `AgentEvent`s that flow through the
/// standard `SessionState` reducer.
@Observable
@MainActor
final class CodexAppServerCoordinator {
    @ObservationIgnored
    private var client: CodexAppServerClient?

    @ObservationIgnored
    private var connectTask: Task<Void, Never>?

    @ObservationIgnored
    private var remoteClients: [String: CodexAppServerClient] = [:]

    @ObservationIgnored
    private var remoteConnectTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var remoteConnections: [String: CodexRemoteHostDiscovery.Connection] = [:]

    @ObservationIgnored
    private var remoteHostPresence = CodexRemoteHostPresence()

    @ObservationIgnored
    private let remoteHostDiscovery = CodexRemoteHostDiscovery()

    @ObservationIgnored
    private var lastRateLimitsRefreshAt = Date.distantPast

    @ObservationIgnored
    private var lastThreadSnapshotAt = Date.distantPast

    @ObservationIgnored
    private var lastRemoteHostDiscoveryAt = Date.distantPast

    private static let rateLimitsRefreshInterval: TimeInterval = 60
    private static let threadSnapshotInterval: TimeInterval = 10

    /// Callback to emit AgentEvents into AppModel.
    @ObservationIgnored
    var onEvent: ((AgentEvent) -> Void)?

    /// Callback to log status messages.
    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    /// Publishes authoritative account usage read directly from Codex.
    @ObservationIgnored
    var onUsageSnapshot: ((CodexUsageSnapshot) -> Void)?

    /// Publishes Codex's authoritative task identity snapshot.
    @ObservationIgnored
    var onThreadSnapshot: (([CodexThread], String?) -> Void)?

    /// Returns `true` if a session with the given id is already tracked.
    /// Used to avoid re-emitting `sessionStarted` (which rebuilds the
    /// session and wipes richer state from hooks/rediscovery).
    @ObservationIgnored
    var isSessionTracked: ((String) -> Bool)?

    private(set) var isConnected = false

    // MARK: - Public API

    /// Ensure a connection exists.  Called from the monitoring loop when
    /// Codex.app is detected as running.  Idempotent — does nothing if
    /// already connected or a connection attempt is in progress.
    func ensureConnected() {
        guard !isConnected, connectTask == nil else { return }

        // Resolve the Codex.app bundle location dynamically — users may
        // have installed Codex outside `/Applications` (e.g. ~/Applications).
        guard let bundleURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            return
        }
        let codexPath = bundleURL
            .appendingPathComponent("Contents/Resources/codex")
            .path
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            return
        }

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let newClient = CodexAppServerClient(codexPath: codexPath)
                newClient.onNotification = { [weak self] notification in
                    Task { @MainActor [weak self] in
                        self?.handleNotification(notification, remoteHost: nil)
                    }
                }
                try await newClient.start()

                self.client = newClient
                self.isConnected = true
                self.connectTask = nil

                self.onStatusMessage?("Connected to Codex app-server.")

                // This app-server process has no loaded-thread state of its
                // own. Sync recent account threads and live account usage.
                await self.syncRecentThreads(client: newClient, remoteHost: nil)
                await self.refreshAccountRateLimits()
            } catch {
                self.connectTask = nil
                self.onStatusMessage?("Failed to connect to Codex app-server: \(error.localizedDescription)")
            }
        }
    }

    /// Disconnect and clean up.  Called when Codex.app is no longer running.
    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        client?.stop()
        client = nil
        for task in remoteConnectTasks.values { task.cancel() }
        remoteConnectTasks.removeAll()
        for client in remoteClients.values { client.stop() }
        remoteClients.removeAll()
        remoteConnections.removeAll()
        remoteHostPresence.reset()
        isConnected = false
        lastRateLimitsRefreshAt = .distantPast
        lastThreadSnapshotAt = .distantPast
        lastRemoteHostDiscoveryAt = .distantPast
    }

    /// Refresh account usage while connected, throttled for the monitor's
    /// frequent maintenance cadence.
    func maintenanceTick(now: Date = .now) {
        if now.timeIntervalSince(lastRemoteHostDiscoveryAt) >= Self.threadSnapshotInterval {
            lastRemoteHostDiscoveryAt = now
            let discovery = remoteHostDiscovery
            Task.detached(priority: .utility) { [weak self] in
                guard let connections = discovery.discover() else { return }
                await self?.synchronizeRemoteHosts(connections)
            }
        }

        guard isConnected else { return }

        if now.timeIntervalSince(lastThreadSnapshotAt) >= Self.threadSnapshotInterval {
            lastThreadSnapshotAt = now
            Task { [weak self] in
                guard let self, let client = self.client else { return }
                await self.syncRecentThreads(client: client, remoteHost: nil)
                for (host, remoteClient) in self.remoteClients {
                    await self.syncRecentThreads(client: remoteClient, remoteHost: host)
                }
            }
        }

        if now.timeIntervalSince(lastRateLimitsRefreshAt) >= Self.rateLimitsRefreshInterval {
            lastRateLimitsRefreshAt = now
            Task { [weak self] in
                await self?.refreshAccountRateLimits()
            }
        }
    }

    // MARK: - Thread sync

    private func syncRecentThreads(client: CodexAppServerClient, remoteHost: String?) async {
        lastThreadSnapshotAt = .now
        do {
            let threads = try await client.listThreads(limit: 40)
            let cutoff = Int(Date.now.addingTimeInterval(-86_400).timeIntervalSince1970)
            let recentThreads = threads.filter { !$0.ephemeral && $0.updatedAt >= cutoff }
            var created = 0
            for thread in recentThreads {
                // Skip threads already tracked — re-emitting sessionStarted
                // rebuilds the AgentSession and would wipe richer state
                // already accumulated from hooks or rediscovery.
                if isSessionTracked?(thread.id) == true { continue }
                emitSessionStarted(from: thread, remoteHost: remoteHost)
                created += 1
            }
            onThreadSnapshot?(recentThreads, remoteHost)
            if created > 0 {
                let source = remoteHost.map { " SSH host \($0)" } ?? " app-server"
                onStatusMessage?("Synced \(created) recent Codex thread(s) from\(source).")
            }
        } catch {
            let source = remoteHost.map { " on \($0)" } ?? ""
            onStatusMessage?("Failed to list recent Codex threads\(source): \(error.localizedDescription)")
        }
    }

    private func synchronizeRemoteHosts(_ connections: [CodexRemoteHostDiscovery.Connection]) {
        let discoveredByHost = Dictionary(uniqueKeysWithValues: connections.map { ($0.host, $0) })
        let discoveredHosts = Set(discoveredByHost.keys)

        for (host, client) in Array(remoteClients) where !client.isRunning {
            remoteClients[host] = nil
            client.stop()
        }

        for (host, connection) in discoveredByHost
        where remoteConnections[host] != nil && remoteConnections[host] != connection {
            remoteClients.removeValue(forKey: host)?.stop()
            remoteConnectTasks.removeValue(forKey: host)?.cancel()
            remoteConnections[host] = nil
        }

        let trackedHosts = Set(remoteConnections.keys)
        let disconnectedHosts = remoteHostPresence.hostsToDisconnect(
            currentHosts: trackedHosts,
            discoveredHosts: discoveredHosts
        )
        for host in disconnectedHosts {
            remoteClients.removeValue(forKey: host)?.stop()
            remoteConnectTasks.removeValue(forKey: host)?.cancel()
            remoteConnections[host] = nil
            onThreadSnapshot?([], host)
        }

        for connection in connections
        where remoteClients[connection.host] == nil && remoteConnectTasks[connection.host] == nil {
            remoteConnections[connection.host] = connection
            connectRemoteHost(connection)
        }
    }

    private func connectRemoteHost(_ connection: CodexRemoteHostDiscovery.Connection) {
        let host = connection.host
        let task = Task { [weak self] in
            guard let self else { return }
            let remoteClient = CodexAppServerClient(
                executablePath: "/usr/bin/ssh",
                arguments: connection.sshOptions + [host, connection.remoteCommand],
                transport: .webSocket
            )
            remoteClient.onNotification = { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleNotification(notification, remoteHost: host)
                }
            }

            do {
                try await remoteClient.start()
                guard !Task.isCancelled else {
                    remoteClient.stop()
                    return
                }
                self.remoteClients[host] = remoteClient
                self.remoteConnectTasks[host] = nil
                self.onStatusMessage?("Connected to Codex SSH host \(host).")
                await self.syncRecentThreads(client: remoteClient, remoteHost: host)
            } catch {
                remoteClient.stop()
                self.remoteConnectTasks[host] = nil
                self.onStatusMessage?("Failed to connect to Codex SSH host \(host): \(error.localizedDescription)")
            }
        }
        remoteConnectTasks[host] = task
    }

    private func refreshAccountRateLimits() async {
        guard let client else { return }
        lastRateLimitsRefreshAt = .now
        do {
            let rateLimits = try await client.readAccountRateLimits()
            onUsageSnapshot?(CodexUsageSnapshot(rateLimits: rateLimits))
        } catch {
            onStatusMessage?("Failed to read Codex rate limits: \(error.localizedDescription)")
        }
    }

    // MARK: - Notification handling

    private func handleNotification(
        _ notification: CodexAppServerNotification,
        remoteHost: String?
    ) {
        switch notification {
        case .threadStarted(let thread):
            guard !thread.ephemeral else { return }
            guard isSessionTracked?(thread.id) != true else { return }
            emitSessionStarted(from: thread, remoteHost: remoteHost)

        case .threadStatusChanged(let threadId, let status):
            switch status.type {
            case .active:
                if status.isWaitingOnApproval {
                    onEvent?(.permissionRequested(
                        PermissionRequested(
                            sessionID: threadId,
                            request: PermissionRequest(
                                title: "Approval Required",
                                summary: "Codex is waiting for approval.",
                                affectedPath: ""
                            ),
                            timestamp: .now
                        )
                    ))
                } else if status.isWaitingOnUserInput {
                    onEvent?(.questionAsked(
                        QuestionAsked(
                            sessionID: threadId,
                            prompt: QuestionPrompt(
                                title: "Codex is waiting for input.",
                                options: []
                            ),
                            timestamp: .now
                        )
                    ))
                } else {
                    onEvent?(.activityUpdated(
                        SessionActivityUpdated(
                            sessionID: threadId,
                            summary: "Codex is working…",
                            phase: .running,
                            timestamp: .now
                        )
                    ))
                }
            case .idle:
                // Idle means "between turns" in the same thread — the thread
                // is still open.  Only `thread/closed` truly ends a session.
                onEvent?(.activityUpdated(
                    SessionActivityUpdated(
                        sessionID: threadId,
                        summary: "Idle.",
                        phase: .completed,
                        timestamp: .now
                    )
                ))
            case .systemError:
                // Quota limits and other hard failures can leave the thread in
                // systemError without a turn/completed notification. Mark the
                // turn as finished so the island does not stay stuck running.
                onEvent?(.activityUpdated(
                    SessionActivityUpdated(
                        sessionID: threadId,
                        summary: "Turn failed.",
                        phase: .completed,
                        timestamp: .now
                    )
                ))
            case .notLoaded:
                break
            }

        case .threadClosed(let threadId):
            onEvent?(.sessionCompleted(
                SessionCompleted(
                    sessionID: threadId,
                    summary: "Codex thread closed.",
                    timestamp: .now,
                    isSessionEnd: true
                )
            ))

        case .threadNameUpdated:
            // Title updates don't have a dedicated AgentEvent and we can't
            // safely overwrite phase/summary here (would clobber running or
            // waiting-for-approval state).  Skip for now — the title is
            // populated at sessionStarted time which is usually enough.
            break

        case .turnStarted(let threadId, _):
            onEvent?(.activityUpdated(
                SessionActivityUpdated(
                    sessionID: threadId,
                    summary: "Codex is working…",
                    phase: .running,
                    timestamp: .now
                )
            ))

        case .turnCompleted(let threadId, let turn):
            // A turn completing doesn't end the thread — the user can send
            // another message.  Use activityUpdated(phase: .completed) so the
            // session stays visible as "Completed" rather than being torn
            // down.  `thread/closed` is the authoritative end signal.
            let summary: String
            switch turn.status {
            case .completed: summary = "Turn completed."
            case .interrupted: summary = "Turn interrupted."
            case .failed: summary = "Turn failed."
            case .inProgress: summary = "Turn in progress."
            }
            onEvent?(.activityUpdated(
                SessionActivityUpdated(
                    sessionID: threadId,
                    summary: summary,
                    phase: .completed,
                    timestamp: .now
                )
            ))

        case .accountRateLimitsUpdated:
            Task { [weak self] in
                await self?.refreshAccountRateLimits()
            }

        case .unknown:
            break
        }
    }

    // MARK: - Helpers

    private func emitSessionStarted(from thread: CodexThread, remoteHost: String?) {
        let workspaceName = URL(fileURLWithPath: thread.cwd).lastPathComponent
        let title = thread.name ?? workspaceName
        let summary = thread.preview.isEmpty ? "Codex session." : String(thread.preview.prefix(120))

        let phase: SessionPhase
        switch thread.status.type {
        case .active: phase = .running
        case .idle: phase = .completed
        case .notLoaded, .systemError: phase = .completed
        }

        onEvent?(.sessionStarted(
            SessionStarted(
                sessionID: thread.id,
                title: title,
                tool: .codex,
                origin: .live,
                initialPhase: phase,
                summary: summary,
                timestamp: .now,
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: workspaceName,
                    paneTitle: title,
                    workingDirectory: thread.cwd,
                    codexThreadID: thread.id
                ),
                codexMetadata: CodexSessionMetadata(
                    transcriptPath: thread.path,
                    initialUserPrompt: thread.preview.isEmpty ? nil : thread.preview,
                    remoteHost: remoteHost
                ),
                isRemote: remoteHost != nil
            )
        ))
    }
}
