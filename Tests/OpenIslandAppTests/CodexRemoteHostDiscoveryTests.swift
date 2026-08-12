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
            arguments: connection.sshOptions + [host, CodexAppServerCoordinator.remoteProxyCommand],
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

        #expect(CodexRemoteHostDiscovery.hosts(fromProcessList: processList) == ["station"])
        #expect(
            CodexRemoteHostDiscovery.connections(fromProcessList: processList).first?.sshOptions
                == ["-T", "-v", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15"]
        )
    }

    @Test
    func ignoresOrdinarySSHAndDeduplicatesHosts() {
        let processList = #"""
        100 1 /usr/bin/ssh station
        101 50 /usr/bin/ssh -T station sh -c 'exec codex app-server proxy'
        102 50 /usr/bin/ssh -T -o BatchMode=yes station sh -c 'exec codex app-server proxy'
        """#

        #expect(CodexRemoteHostDiscovery.hosts(fromProcessList: processList) == ["station"])
    }

    @Test
    func discoversHostInCodexDesktopNestedBootstrapCommand() {
        let processList = #"""
        45172 656 /usr/bin/ssh -T -v -o BatchMode=yes -o ServerAliveInterval=15 station sh -c 'if [ -z "$SHELL" ]; then exit 127; fi; CODEX_REMOTE_PAYLOAD="$1"; exec "$SHELL" -l -i -c '\''exec /bin/sh -c "$CODEX_REMOTE_PAYLOAD"'\''' sh 'PATH="$HOME/.local/bin:$PATH"; export PATH; exec codex app-server proxy'
        """#

        #expect(CodexRemoteHostDiscovery.hosts(fromProcessList: processList) == ["station"])
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
        #expect(connections == [
            CodexRemoteHostDiscovery.Connection(host: "station", sshOptions: ["-T"]),
        ])
    }

    @Test
    func requiresTwoMissesBeforeDisconnectingRemoteHost() {
        var presence = CodexRemoteHostPresence()
        let current: Set<String> = ["station"]

        #expect(presence.hostsToDisconnect(currentHosts: current, discoveredHosts: []).isEmpty)
        #expect(presence.hostsToDisconnect(currentHosts: current, discoveredHosts: []) == ["station"])
    }
}
