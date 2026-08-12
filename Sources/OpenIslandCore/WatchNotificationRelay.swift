import Foundation
import os

/// Monitors AppModel state changes and relays relevant events to the WatchHTTPEndpoint as SSE pushes.
/// Also handles resolution callbacks from the Watch/iPhone back to the bridge.
public final class WatchNotificationRelay: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.openisland", category: "WatchNotificationRelay")

    public let endpoint: WatchHTTPEndpoint

    /// Callback to resolve a permission request (sessionID, approved).
    public var onResolvePermission: (@Sendable (_ sessionID: String, _ approved: Bool) -> Void)?

    /// Callback to answer a question (sessionID, answer).
    public var onAnswerQuestion: (@Sendable (_ sessionID: String, _ answer: String) -> Void)?

    /// Provider for looking up session by ID (needed to map requestID → sessionID).
    public var sessionLookup: (@Sendable (_ requestID: String) -> (sessionID: String, kind: PendingRequestKind)?)?

    public enum PendingRequestKind: Sendable {
        case permission
        case question
    }

    // Maps requestID → (sessionID, kind) for pending requests
    private let queue = DispatchQueue(label: "app.openisland.watch.relay")
    private var pendingRequests: [String: (sessionID: String, kind: PendingRequestKind)] = [:]
    private var pendingPermissionTasks: [String: Task<Void, Never>] = [:]
    private let permissionNotificationDelay: Duration

    public init(
        endpoint: WatchHTTPEndpoint = WatchHTTPEndpoint(),
        permissionNotificationDelay: Duration = .seconds(5)
    ) {
        self.endpoint = endpoint
        self.permissionNotificationDelay = permissionNotificationDelay
        setupResolutionHandler()
    }

    // MARK: - Event Notification

    /// Called by AppModel after applying a tracked event. Filters for events that should
    /// be pushed to the Watch and constructs the appropriate SSE event.
    public func notifyEvent(_ event: AgentEvent, session: AgentSession?) {
        switch event {
        case let .permissionRequested(payload):
            guard let session else { return }
            schedulePermissionNotification(payload, session: session)

        case .questionAsked:
            break

        case let .sessionCompleted(payload):
            guard let session else { return }
            resolvePendingRequests(forSession: payload.sessionID)
            let sseEvent = WatchSSEEvent.sessionCompleted(WatchCompletionEvent(
                sessionID: payload.sessionID,
                agentTool: session.tool.displayName,
                summary: payload.summary
            ))
            endpoint.pushEvent(sseEvent)
            Self.logger.info("Pushed sessionCompleted for session \(payload.sessionID)")

        case let .actionableStateResolved(payload):
            resolvePendingRequests(forSession: payload.sessionID)

        default:
            break
        }
    }

    // MARK: - Lifecycle

    public func start() {
        endpoint.start()
    }

    public func stop() {
        let tasks = queue.sync {
            let tasks = Array(pendingPermissionTasks.values)
            pendingPermissionTasks.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
        endpoint.stop()
    }

    // MARK: - Private

    private func trackPendingRequest(requestID: String, sessionID: String, kind: PendingRequestKind) {
        queue.sync {
            pendingRequests[requestID] = (sessionID: sessionID, kind: kind)
        }
    }

    private func schedulePermissionNotification(
        _ payload: PermissionRequested,
        session: AgentSession
    ) {
        if permissionNotificationDelay == .zero {
            publishPermissionNotification(payload, session: session)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: permissionNotificationDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            publishPermissionNotification(payload, session: session)
            clearPendingPermissionTask(forSession: payload.sessionID)
        }

        let previous = queue.sync {
            pendingPermissionTasks.updateValue(task, forKey: payload.sessionID)
        }
        previous?.cancel()
    }

    private func publishPermissionNotification(
        _ payload: PermissionRequested,
        session: AgentSession
    ) {
        let requestID = payload.request.id.uuidString
        trackPendingRequest(requestID: requestID, sessionID: payload.sessionID, kind: .permission)

        endpoint.pushEvent(.permissionRequested(WatchPermissionEvent(
            sessionID: payload.sessionID,
            agentTool: session.tool.displayName,
            title: payload.request.title,
            summary: payload.request.summary,
            workingDirectory: session.jumpTarget?.workingDirectory,
            primaryAction: payload.request.primaryActionTitle,
            secondaryAction: payload.request.secondaryActionTitle,
            requestID: requestID
        )))
        Self.logger.info("Pushed permissionRequested for session \(payload.sessionID)")
    }

    private func cancelPendingPermissionNotification(forSession sessionID: String) {
        let task = queue.sync {
            pendingPermissionTasks.removeValue(forKey: sessionID)
        }
        task?.cancel()
    }

    private func clearPendingPermissionTask(forSession sessionID: String) {
        _ = queue.sync {
            pendingPermissionTasks.removeValue(forKey: sessionID)
        }
    }

    private func lookupPendingRequest(requestID: String) -> (sessionID: String, kind: PendingRequestKind)? {
        queue.sync {
            pendingRequests.removeValue(forKey: requestID)
        }
    }

    /// Removes every pending request belonging to a session and returns
    /// the cleared requestIDs in the order they were originally inserted
    /// (best effort — `Dictionary` iteration order is undefined, so callers
    /// must not rely on order for correctness).
    private func removeAllPendingRequests(forSession sessionID: String) -> [String] {
        queue.sync {
            let matchingKeys = pendingRequests.compactMap { key, value in
                value.sessionID == sessionID ? key : nil
            }
            for key in matchingKeys {
                pendingRequests.removeValue(forKey: key)
            }
            return matchingKeys
        }
    }

    private func resolvePendingRequests(forSession sessionID: String) {
        cancelPendingPermissionNotification(forSession: sessionID)

        // Remove ALL pending requests for this session. A single session can
        // have multiple pending entries when subagents fan out permission
        // prompts in parallel.
        let requestIDs = removeAllPendingRequests(forSession: sessionID)
        if requestIDs.isEmpty {
            Self.logger.debug("No pending request found for resolved session \(sessionID)")
            return
        }

        for requestID in requestIDs {
            endpoint.pushEvent(.actionableStateResolved(WatchResolvedEvent(
                requestID: requestID,
                sessionID: sessionID
            )))
        }
        Self.logger.info("Pushed actionableStateResolved for \(requestIDs.count) request(s) on session \(sessionID)")
    }

    /// Test-only accessor for verifying pending-request cleanup.
    func pendingRequestCountForTests(sessionID: String? = nil) -> Int {
        queue.sync {
            guard let sessionID else { return pendingRequests.count }
            return pendingRequests.values.filter { $0.sessionID == sessionID }.count
        }
    }

    private func setupResolutionHandler() {
        endpoint.onResolution = { [weak self] resolution in
            guard let self else { return }

            guard let pending = self.lookupPendingRequest(requestID: resolution.requestID)
                    ?? self.sessionLookup?(resolution.requestID) else {
                Self.logger.warning("Resolution for unknown requestID: \(resolution.requestID)")
                return
            }

            switch pending.kind {
            case .permission:
                let approved = resolution.action.lowercased() == "allow"
                Self.logger.info("Resolving permission for session \(pending.sessionID): \(resolution.action)")
                self.onResolvePermission?(pending.sessionID, approved)

            case .question:
                Self.logger.info("Answering question for session \(pending.sessionID): \(resolution.action)")
                self.onAnswerQuestion?(pending.sessionID, resolution.action)
            }
        }
    }
}
