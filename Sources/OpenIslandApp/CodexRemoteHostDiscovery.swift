import Foundation

/// Finds SSH hosts that Codex Desktop currently uses for remote app-server
/// proxies. The process is the local, read-only source of truth for which
/// remote environments are connected right now.
struct CodexRemoteHostDiscovery: Sendable {
    typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) -> String?

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = Self.commandOutput) {
        self.commandRunner = commandRunner
    }

    func discover() -> [String] {
        guard let output = commandRunner("/bin/ps", ["-Ao", "pid=,command="]) else {
            return []
        }
        return Self.hosts(fromProcessList: output)
    }

    static func hosts(fromProcessList processList: String) -> [String] {
        var hosts: Set<String> = []

        for line in processList.split(whereSeparator: \.isNewline) {
            let command = String(line)
            guard command.contains("app-server proxy") else { continue }
            let tokens = shellTokens(in: command)
            guard let sshIndex = tokens.firstIndex(where: {
                $0 == "ssh" || $0.hasSuffix("/ssh")
            }) else { continue }
            guard let host = sshHost(in: Array(tokens.dropFirst(sshIndex + 1))) else {
                continue
            }
            hosts.insert(host)
        }

        return hosts.sorted()
    }

    private static let optionsWithValue: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
        "-L", "-l", "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S",
        "-W", "-w",
    ]

    private static func sshHost(in arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }
            if argument.hasPrefix("-") {
                if optionsWithValue.contains(argument) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            return argument
        }
        return nil
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
