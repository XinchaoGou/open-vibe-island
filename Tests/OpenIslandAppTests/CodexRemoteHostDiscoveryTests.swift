import Foundation
import Testing
@testable import OpenIslandApp
@testable import OpenIslandCore

struct CodexRemoteHostDiscoveryTests {
    @Test
    func remoteProxyIntegrationWhenHostIsProvided() async throws {
        guard let host = ProcessInfo.processInfo.environment["OPEN_ISLAND_TEST_REMOTE_HOST"] else {
            return
        }
        let connection = try #require(
            CodexRemoteHostDiscovery().discover()?.first { $0.host == host }
        )
        let client = CodexAppServerClient(
            executablePath: "/usr/bin/ssh",
            arguments: connection.sshOptions + [host, connection.remoteCommand],
            transport: .webSocket
        )
        client.requestTimeoutSeconds = 5
        defer { client.stop() }

        try await client.start()
        let threads = try await client.listThreads(limit: 40)
        #expect(threads.contains { $0.name == "清理 StarVLA runtime 并统一 dry-run HOLD" })
    }

    @Test
    func discoversCodexDesktopSSHProxyHost() {
        let processList = #"""
        33113 656 /usr/bin/ssh -T -v -o BatchMode=yes -o ServerAliveInterval=15 station sh -c 'exec codex app-server proxy'
        44527 1491 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
        """#

        let connection = CodexRemoteHostDiscovery.connections(fromProcessList: processList).first
        #expect(connection?.host == "station")
        #expect(connection?.sshOptions == ["-T", "-v", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15"])
    }

    @Test
    func ignoresOrdinarySSHAndDeduplicatesHosts() {
        let processList = #"""
        100 1 /usr/bin/ssh station
        101 50 /usr/bin/ssh -T station sh -c 'exec codex app-server proxy'
        102 50 /usr/bin/ssh -T -o BatchMode=yes station sh -c 'exec codex app-server proxy'
        """#

        let connection = CodexRemoteHostDiscovery.connections(fromProcessList: processList).first
        #expect(connection?.host == "station")
    }

    @Test
    func discoversHostInCodexDesktopNestedBootstrapCommand() {
        let processList = #"""
        45172 656 /usr/bin/ssh -T -v -o BatchMode=yes -o ServerAliveInterval=15 station sh -c 'CODEX_REMOTE_PAYLOAD="$1"; export CODEX_REMOTE_PAYLOAD; exec "$SHELL" -l -i -c '\''CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"; export CODEX_HOME; exec /bin/sh -c "$CODEX_REMOTE_PAYLOAD"'\''' sh 'printf '\''%b'\'' '\''\032\114\046\242\075\215\046\315'\''; PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"; export PATH; exec codex app-server proxy'
        """#

        let connection = CodexRemoteHostDiscovery.connections(fromProcessList: processList).first
        #expect(connection?.host == "station")
        #expect(connection?.remoteCommand.contains("CODEX_REMOTE_PAYLOAD") == true)
        #expect(connection?.remoteCommand.contains("CODEX_HOME") == true)
        #expect(connection?.remoteCommand.contains("printf") == false)
    }

    @Test
    func excludesOpenIslandsOwnSSHProxyChild() {
        let processList = #"""
        45172 656 /usr/bin/ssh -T station sh -c 'exec codex app-server proxy'
        48661 999 /usr/bin/ssh -T station exec "$SHELL" -l -i -c 'exec codex app-server proxy'
        """#

        let connections = CodexRemoteHostDiscovery.connections(
            fromProcessList: processList,
            excludingParentPID: 999
        )
        #expect(connections.map(\.host) == ["station"])
        #expect(connections.first?.sshOptions == ["-T"])
    }

    @Test
    func requiresTwoMissesBeforeDisconnectingRemoteHost() {
        var presence = CodexRemoteHostPresence()
        let current: Set<String> = ["station"]

        #expect(presence.hostsToDisconnect(currentHosts: current, discoveredHosts: []).isEmpty)
        #expect(presence.hostsToDisconnect(currentHosts: current, discoveredHosts: []) == ["station"])
    }

    @Test
    func ignoresProxyNotOwnedByCodexDesktop() {
        let processList = #"""
        50 1 /Applications/Other.app/Contents/MacOS/Other
        101 50 /usr/bin/ssh -T station sh -c 'exec codex app-server proxy'
        """#

        #expect(CodexRemoteHostDiscovery.connections(fromProcessList: processList).isEmpty)
    }
}
