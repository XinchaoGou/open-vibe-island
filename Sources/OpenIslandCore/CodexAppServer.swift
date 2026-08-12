import Foundation

// MARK: - Protocol models

/// A Codex thread as reported by the app-server JSON-RPC protocol.
public struct CodexThread: Codable, Sendable {
    public let id: String
    public let cwd: String
    public let name: String?
    public let preview: String
    public let modelProvider: String
    public let createdAt: Int
    public let updatedAt: Int
    public let ephemeral: Bool
    public let path: String?
    public let status: CodexThreadStatus
    public let source: CodexThreadSource?

    /// Turns are only populated on `thread/resume` and `thread/fork`
    /// responses, empty otherwise.
    public let turns: [CodexTurn]?
}

public enum CodexThreadStatusType: String, Codable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active
}

public struct CodexThreadStatus: Codable, Sendable {
    public let type: CodexThreadStatusType
    /// Only present when `type == .active`.
    public let activeFlags: [String]?

    public var isWaitingOnApproval: Bool {
        activeFlags?.contains("waitingOnApproval") == true
    }

    public var isWaitingOnUserInput: Bool {
        activeFlags?.contains("waitingOnUserInput") == true
    }
}

public enum CodexThreadSource: String, Codable, Sendable {
    case cli
    case vscode
    case appServer = "app-server"
    case codexExec = "codex-exec"
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = CodexThreadSource(rawValue: value) ?? .unknown
    }
}

public struct CodexTurn: Codable, Sendable {
    public let id: String
    public let status: CodexTurnStatus
}

public enum CodexTurnStatus: String, Codable, Sendable {
    case completed
    case interrupted
    case failed
    case inProgress
}

// MARK: - Notifications

public enum CodexAppServerNotification: Sendable {
    case threadStarted(thread: CodexThread)
    case threadStatusChanged(threadId: String, status: CodexThreadStatus)
    case threadClosed(threadId: String)
    case threadNameUpdated(threadId: String, name: String?)
    case turnStarted(threadId: String, turn: CodexTurn)
    case turnCompleted(threadId: String, turn: CodexTurn)
    case accountRateLimitsUpdated
    case unknown(method: String)
}

public struct CodexAccountRateLimitWindow: Codable, Sendable {
    public let usedPercent: Int
    public let windowDurationMins: Int?
    public let resetsAt: Int?
}

public struct CodexAccountRateLimitSnapshot: Codable, Sendable {
    public let limitId: String?
    public let planType: String?
    public let primary: CodexAccountRateLimitWindow?
    public let secondary: CodexAccountRateLimitWindow?
}

public enum CodexAppServerTransport: Sendable {
    case jsonLines
    case webSocket
}

// MARK: - JSON-RPC transport

/// A lightweight JSON-RPC client that communicates with Codex app-server
/// over a stdio-based `Process`.  Uses newline-delimited JSON messages
/// (one JSON object per line, no Content-Length framing).
public final class CodexAppServerClient: @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let transport: CodexAppServerTransport
    private var process: Process?
    /// Internal access so tests can inject a discard `Pipe` and drive
    /// the request path without launching a real codex subprocess.
    var stdin: FileHandle?
    /// Per-request timeout. App-server RPC calls (initialize,
    /// thread/list, …) normally complete in tens of milliseconds; a
    /// hang past 30 s means codex is wedged and we must release the
    /// caller rather than pin its `Task` forever.
    var requestTimeoutSeconds: TimeInterval = 30
    private var readBuffer = Data()
    private var webSocketUpgraded = false
    private var webSocketHandshakeContinuation: CheckedContinuation<Void, any Error>?
    private var fragmentedOpcode: UInt8?
    private var fragmentedPayload = Data()

    /// Test-only accessor for asserting buffer state after `handleIncomingData`.
    var readBufferCountForTests: Int {
        readBuffer.count
    }
    private var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextRequestID = 1
    private let lock = NSLock()

    public var onNotification: (@Sendable (CodexAppServerNotification) -> Void)?

    public init(codexPath: String = "/Applications/Codex.app/Contents/Resources/codex") {
        self.executablePath = codexPath
        self.arguments = ["app-server", "--listen", "stdio://"]
        self.transport = .jsonLines
    }

    public init(
        executablePath: String,
        arguments: [String],
        transport: CodexAppServerTransport
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.transport = transport
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    // MARK: - Lifecycle

    /// Launch the app-server subprocess and perform the `initialize` handshake.
    public func start() async throws {
        guard !isRunning else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        self.stdin = stdinPipe.fileHandleForWriting
        self.process = proc

        // Read stdout in a background thread.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleIncomingData(data)
        }

        // Drain stderr so a full pipe can't block the child process.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try proc.run()

        if transport == .webSocket {
            try await performWebSocketUpgrade()
        }

        // Send initialize request.
        struct InitializeParams: Encodable {
            struct ClientInfo: Encodable {
                let name: String
                let version: String
            }
            let clientInfo: ClientInfo
        }
        _ = try await sendRequest(
            method: "initialize",
            params: InitializeParams(clientInfo: .init(name: "OpenIsland", version: "1.0.0"))
        )
        sendNotification(method: "initialized")
    }

    /// Stop the app-server subprocess.
    public func stop() {
        process?.terminate()
        process = nil
        stdin = nil
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        let handshake = webSocketHandshakeContinuation
        webSocketHandshakeContinuation = nil
        lock.unlock()
        for (_, continuation) in pending {
            continuation.resume(throwing: CodexAppServerError.disconnected)
        }
        handshake?.resume(throwing: CodexAppServerError.disconnected)
    }

    // MARK: - Requests

    /// List currently loaded threads from the app-server.
    public func listLoadedThreads() async throws -> [CodexThread] {
        struct Params: Encodable {}
        struct Result: Decodable { let threads: [CodexThread] }
        let data = try await sendRequest(method: "thread/loaded/list", params: Params())
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.threads
    }

    /// List all threads (including not-loaded) from the app-server.
    public func listThreads(limit: Int? = nil) async throws -> [CodexThread] {
        struct Params: Encodable { let limit: Int? }
        struct Result: Decodable { let data: [CodexThread] }
        let data = try await sendRequest(method: "thread/list", params: Params(limit: limit))
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.data
    }

    public func readAccountRateLimits() async throws -> CodexAccountRateLimitSnapshot {
        struct Result: Decodable {
            let rateLimits: CodexAccountRateLimitSnapshot
            let rateLimitsByLimitId: [String: CodexAccountRateLimitSnapshot]?
        }

        let data = try await sendRequestWithoutParams(method: "account/rateLimits/read")
        let result = try JSONDecoder().decode(Result.self, from: data)
        return result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
    }

    // MARK: - JSON-RPC transport

    /// Returns raw JSON `result` bytes from the response.
    @discardableResult
    private func sendRequest<P: Encodable>(
        method: String,
        params: P
    ) async throws -> Data {
        let paramsData = try JSONEncoder().encode(params)
        let paramsObject = try JSONSerialization.jsonObject(with: paramsData)
        return try await sendRequest(method: method, paramsObject: paramsObject)
    }

    private func sendRequestWithoutParams(method: String) async throws -> Data {
        try await sendRequest(method: method, paramsObject: NSNull())
    }

    private func sendRequest(method: String, paramsObject: Any) async throws -> Data {
        guard let stdin else {
            throw CodexAppServerError.notConnected
        }

        let requestID: Int = lock.withLock {
            let id = nextRequestID
            nextRequestID += 1
            return id
        }

        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": paramsObject,
        ]
        let message = try JSONSerialization.data(withJSONObject: envelope)
        let outgoingData = framedOutgoingData(message)

        // Race the response continuation against a timeout task.
        // Without this, a wedged app-server (no disconnect, no reply)
        // would leave the `await` suspended forever — pinning the
        // continuation, the caller's Task, and any memory referenced
        // by either.
        let timeoutSeconds = requestTimeoutSeconds
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.failPendingRequest(id: requestID, with: .timeout)
        }
        defer { timeoutTask.cancel() }

        // Register the continuation BEFORE writing — a fast app-server can
        // reply between write() and registration, which would cause
        // handleResponse to drop the reply and hang the await forever.
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[requestID] = continuation
            lock.unlock()
            stdin.write(outgoingData)
        }
    }

    private func sendNotification(method: String) {
        guard let stdin,
              let message = try? JSONSerialization.data(withJSONObject: ["method": method])
        else { return }
        stdin.write(framedOutgoingData(message))
    }

    private func framedOutgoingData(_ message: Data) -> Data {
        switch transport {
        case .jsonLines:
            var line = message
            line.append(UInt8(ascii: "\n"))
            return line
        case .webSocket:
            return CodexWebSocketCodec.clientFrame(opcode: 0x1, payload: message)
        }
    }

    private func performWebSocketUpgrade() async throws {
        guard let stdin else { throw CodexAppServerError.notConnected }
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = """
        GET / HTTP/1.1\r
        Host: localhost\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r

        """

        let timeoutSeconds = requestTimeoutSeconds
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.failWebSocketHandshake(with: .timeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            webSocketHandshakeContinuation = continuation
            lock.unlock()
            stdin.write(Data(request.utf8))
        }
    }

    private func failWebSocketHandshake(with error: CodexAppServerError) {
        lock.lock()
        let continuation = webSocketHandshakeContinuation
        webSocketHandshakeContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// Atomically removes a pending request and resumes its
    /// continuation with the given error. Safe to call concurrently
    /// with `handleResponse`: whichever side wins the dictionary
    /// removal performs the resume; the other side gets `nil` and
    /// no-ops.
    private func failPendingRequest(id: Int, with error: CodexAppServerError) {
        lock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    // MARK: - Incoming data

    /// Maximum bytes we will accumulate without seeing a newline. Codex
    /// app-server RPC messages are line-delimited JSON; lines past this
    /// size indicate either a malformed stream or a runaway result. We
    /// drop the buffer rather than let it grow without bound (would OOM
    /// if the producer never sends `\n`).
    static let maxLineByteCount = 8 * 1_024 * 1_024

    func handleIncomingData(_ data: Data) {
        switch transport {
        case .jsonLines:
            handleJSONLines(data)
        case .webSocket:
            handleWebSocketData(data)
        }
    }

    private func handleJSONLines(_ data: Data) {
        readBuffer.append(data)

        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            // Slice the line out, then trim the consumed prefix in place
            // with `removeSubrange`. The previous `readBuffer = Data(...)`
            // re-allocated and copied the whole tail on every line, so a
            // burst of N lines from codex was O(N²) — measurable when a
            // tool result emits hundreds of progress events back-to-back.
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            let consumeUpTo = readBuffer.index(after: newlineIndex)
            defer { readBuffer.removeSubrange(readBuffer.startIndex..<consumeUpTo) }

            handleJSONMessage(Data(lineData))
        }

        if readBuffer.count > Self.maxLineByteCount {
            // Drop the runaway prefix; keep the connection up so the next
            // well-framed line still has a chance. The peer will likely
            // emit a protocol error which propagates as a normal `rpcError`.
            readBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func handleWebSocketData(_ data: Data) {
        readBuffer.append(data)

        if !webSocketUpgraded {
            let delimiter = Data("\r\n\r\n".utf8)
            guard let headerRange = readBuffer.range(of: delimiter) else {
                if readBuffer.count > 16 * 1_024 {
                    readBuffer.removeAll()
                    failWebSocketHandshake(with: .invalidWebSocketHandshake)
                }
                return
            }

            let header = String(decoding: readBuffer[..<headerRange.upperBound], as: UTF8.self)
            readBuffer.removeSubrange(readBuffer.startIndex..<headerRange.upperBound)
            guard header.hasPrefix("HTTP/1.1 101") || header.hasPrefix("HTTP/1.0 101") else {
                failWebSocketHandshake(with: .invalidWebSocketHandshake)
                return
            }

            webSocketUpgraded = true
            lock.lock()
            let continuation = webSocketHandshakeContinuation
            webSocketHandshakeContinuation = nil
            lock.unlock()
            continuation?.resume()
        }

        do {
            for frame in try CodexWebSocketCodec.decodeFrames(from: &readBuffer) {
                handleWebSocketFrame(frame)
            }
        } catch {
            readBuffer.removeAll()
        }
    }

    private func handleWebSocketFrame(_ frame: CodexWebSocketCodec.Frame) {
        switch frame.opcode {
        case 0x0:
            guard fragmentedOpcode != nil else { return }
            fragmentedPayload.append(frame.payload)
            if frame.isFinal {
                handleJSONMessage(fragmentedPayload)
                fragmentedOpcode = nil
                fragmentedPayload.removeAll(keepingCapacity: true)
            }
        case 0x1, 0x2:
            if frame.isFinal {
                handleJSONMessage(frame.payload)
            } else {
                fragmentedOpcode = frame.opcode
                fragmentedPayload = frame.payload
            }
        case 0x8:
            stop()
        case 0x9:
            stdin?.write(CodexWebSocketCodec.clientFrame(opcode: 0xA, payload: frame.payload))
        default:
            break
        }
    }

    private func handleJSONMessage(_ message: Data) {
        guard !message.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        else { return }

        if let id = json["id"] as? Int {
            handleResponse(id: id, json: json)
        } else if let method = json["method"] as? String {
            handleNotification(method: method, json: json)
        }
    }

    private func handleResponse(id: Int, json: [String: Any]) {
        lock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        lock.unlock()

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            continuation?.resume(throwing: CodexAppServerError.rpcError(message))
        } else {
            let result = json["result"] ?? [String: Any]()
            let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            continuation?.resume(returning: data)
        }
    }

    private func handleNotification(method: String, json: [String: Any]) {
        guard let params = json["params"] else { return }
        let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        let decoder = JSONDecoder()

        let notification: CodexAppServerNotification
        switch method {
        case "thread/started":
            guard let n = try? decoder.decode(ThreadStartedParams.self, from: paramsData) else { return }
            notification = .threadStarted(thread: n.thread)
        case "thread/status/changed":
            guard let n = try? decoder.decode(ThreadStatusChangedParams.self, from: paramsData) else { return }
            notification = .threadStatusChanged(threadId: n.threadId, status: n.status)
        case "thread/closed":
            guard let n = try? decoder.decode(ThreadClosedParams.self, from: paramsData) else { return }
            notification = .threadClosed(threadId: n.threadId)
        case "thread/name/updated":
            guard let n = try? decoder.decode(ThreadNameUpdatedParams.self, from: paramsData) else { return }
            notification = .threadNameUpdated(threadId: n.threadId, name: n.name)
        case "turn/started":
            guard let n = try? decoder.decode(TurnNotificationParams.self, from: paramsData) else { return }
            notification = .turnStarted(threadId: n.threadId, turn: n.turn)
        case "turn/completed":
            guard let n = try? decoder.decode(TurnNotificationParams.self, from: paramsData) else { return }
            notification = .turnCompleted(threadId: n.threadId, turn: n.turn)
        case "account/rateLimits/updated":
            notification = .accountRateLimitsUpdated
        default:
            notification = .unknown(method: method)
        }

        onNotification?(notification)
    }
}

// MARK: - Notification param structs (private)

private struct ThreadStartedParams: Codable {
    let thread: CodexThread
}

private struct ThreadStatusChangedParams: Codable {
    let threadId: String
    let status: CodexThreadStatus
}

private struct ThreadClosedParams: Codable {
    let threadId: String
}

private struct ThreadNameUpdatedParams: Codable {
    let threadId: String
    let name: String?
}

private struct TurnNotificationParams: Codable {
    let threadId: String
    let turn: CodexTurn
}

// MARK: - Errors

public enum CodexAppServerError: Error, LocalizedError {
    case notConnected
    case disconnected
    case rpcError(String)
    case timeout
    case invalidWebSocketHandshake

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Codex app-server is not connected."
        case .disconnected: "Codex app-server connection was lost."
        case .rpcError(let msg): "Codex app-server error: \(msg)"
        case .timeout: "Codex app-server request timed out."
        case .invalidWebSocketHandshake: "Codex app-server returned an invalid WebSocket handshake."
        }
    }
}
