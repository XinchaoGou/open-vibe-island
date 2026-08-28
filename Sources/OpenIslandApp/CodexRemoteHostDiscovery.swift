import Foundation

/// Finds SSH hosts that Codex Desktop currently uses for remote app-server
/// proxies. The process is the local, read-only source of truth for which
/// remote environments are connected right now.
struct CodexRemoteHostDiscovery: Sendable {
    struct Connection: Equatable, Hashable, Sendable {
        let host: String
        let sshOptions: [String]
        let remoteCommand: String
    }

    typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) -> String?

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = Self.commandOutput) {
        self.commandRunner = commandRunner
    }

    func discover() -> [Connection]? {
        guard let output = commandRunner("/bin/ps", ["-Ao", "pid=,ppid=,command="]) else {
            return nil
        }
        return Self.connections(
            fromProcessList: output,
            excludingParentPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    static func hosts(fromProcessList processList: String) -> [String] {
        connections(fromProcessList: processList).map(\.host)
    }

    static func connections(
        fromProcessList processList: String,
        excludingParentPID: Int32? = nil
    ) -> [Connection] {
        struct ProcessRecord {
            let pid: Int32?
            let parentPID: Int32?
            let command: String
            let tokens: [String]
        }
        let records = processList.split(whereSeparator: \.isNewline).map { line in
            let command = String(line)
            let tokens = shellTokens(in: command)
            return ProcessRecord(
                pid: tokens.first.flatMap(Int32.init),
                parentPID: tokens.dropFirst().first.flatMap(Int32.init),
                command: command,
                tokens: tokens
            )
        }
        let recordsByPID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.pid.map { ($0, record) }
        })
        var connectionsByHost: [String: Connection] = [:]

        for record in records {
            guard record.command.contains("app-server proxy") else { continue }
            let tokens = record.tokens
            guard let sshIndex = tokens.firstIndex(where: {
                $0 == "ssh" || $0.hasSuffix("/ssh")
            }) else { continue }
            if record.parentPID == excludingParentPID {
                continue
            }
            if let parentPID = record.parentPID,
               let parent = recordsByPID[parentPID],
               !isCodexDesktopProcess(parent.command) {
                continue
            }
            let sshArguments = Array(tokens.dropFirst(sshIndex + 1))
            guard let target = sshTarget(in: sshArguments) else {
                continue
            }
            let remoteArguments = Array(sshArguments.dropFirst(target.index + 1))
            guard let remoteCommand = sanitizedRemoteCommand(from: remoteArguments) else {
                continue
            }
            connectionsByHost[target.host] = Connection(
                host: target.host,
                sshOptions: Array(sshArguments[..<target.index]),
                remoteCommand: remoteCommand
            )
        }

        return connectionsByHost.values.sorted { $0.host < $1.host }
    }

    private static let optionsWithValue: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
        "-L", "-l", "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S",
        "-W", "-w",
    ]

    private static func sshTarget(in arguments: [String]) -> (host: String, index: Int)? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                guard arguments.indices.contains(index + 1) else { return nil }
                return (arguments[index + 1], index + 1)
            }
            if argument.hasPrefix("-") {
                if optionsWithValue.contains(argument) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            return (argument, index)
        }
        return nil
    }

    private static func sanitizedRemoteCommand(from arguments: [String]) -> String? {
        guard !arguments.isEmpty else { return nil }
        var sanitized = arguments
        if let payloadIndex = sanitized.indices.last,
           sanitized[payloadIndex].contains("app-server proxy") {
            let payload = sanitized[payloadIndex]
            if payload.trimmingCharacters(in: .whitespaces).hasPrefix("printf "),
               let separator = payload.firstIndex(of: ";") {
                sanitized[payloadIndex] = String(payload[payload.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard sanitized.joined(separator: " ").contains("app-server proxy") else { return nil }
        return sanitized.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isCodexDesktopProcess(_ command: String) -> Bool {
        command.contains("/ChatGPT.app/Contents/MacOS/ChatGPT")
            || command.contains("/Codex.app/Contents/MacOS/Codex")
    }

    /// A deliberately small POSIX shell tokenizer. It only needs to preserve
    /// the argv boundaries printed by `ps`; no expansion or execution occurs.
    private static func shellTokens(in command: String) -> [String] {
        enum Quote { case single, double }
        var quote: Quote?
        var escaping = false
        var current = ""
        var result: [String] = []

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            switch (quote, character) {
            case (.single, "'"):
                quote = nil
            case (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (.single, _):
                current.append(character)
            case (_, "\\"):
                escaping = true
            case (nil, let character) where character.isWhitespace:
                if !current.isEmpty {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            default:
                current.append(character)
            }
        }

        if escaping { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func commandOutput(_ executablePath: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain before waiting: Codex Desktop's SSH bootstrap command is
            // very long, and a busy process list can exceed the pipe buffer.
            // Waiting first would deadlock the main actor while `ps` blocks
            // trying to finish its write.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Debounces transient `ps` gaps so a single missed sample does not remove
/// every task for an otherwise connected SSH environment.
struct CodexRemoteHostPresence {
    private(set) var missCounts: [String: Int] = [:]

    mutating func hostsToDisconnect(
        currentHosts: Set<String>,
        discoveredHosts: Set<String>,
        requiredMisses: Int = 2
    ) -> Set<String> {
        for host in discoveredHosts {
            missCounts[host] = nil
        }

        var disconnected: Set<String> = []
        for host in currentHosts where !discoveredHosts.contains(host) {
            let misses = (missCounts[host] ?? 0) + 1
            missCounts[host] = misses
            if misses >= requiredMisses {
                disconnected.insert(host)
                missCounts[host] = nil
            }
        }
        return disconnected
    }

    mutating func reset() {
        missCounts.removeAll()
    }
}
