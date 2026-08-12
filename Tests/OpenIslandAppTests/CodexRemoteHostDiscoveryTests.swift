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
        #expect(CodexRemoteHostDiscovery().discover().contains(host))
        let command = #"exec "$SHELL" -l -i -c 'exec codex app-server proxy'"#
        let client = CodexAppServerClient(
            executablePath: "/usr/bin/ssh",
            arguments: ["-T", host, command],
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
        33113 /usr/bin/ssh -T -v -o BatchMode=yes -o ServerAliveInterval=15 station sh -c 'exec codex app-server proxy'
        44527 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
        """#

        #expect(CodexRemoteHostDiscovery.hosts(fromProcessList: processList) == ["station"])
    }

    @Test
    func ignoresOrdinarySSHAndDeduplicatesHosts() {
        let processList = #"""
        100 /usr/bin/ssh station
        101 /usr/bin/ssh -T station sh -c 'exec codex app-server proxy'
        102 /usr/bin/ssh -T -o BatchMode=yes station sh -c 'exec codex app-server proxy'
        """#

        #expect(CodexRemoteHostDiscovery.hosts(fromProcessList: processList) == ["station"])
    }

    @Test
    func discoversHostInCodexDesktopNestedBootstrapCommand() {
        let processList = #"""
        45172 /usr/bin/ssh -T -v -o BatchMode=yes -o ServerAliveInterval=15 station sh -c 'if [ -z "$SHELL" ]; then exit 127; fi; CODEX_REMOTE_PAYLOAD="$1"; exec "$SHELL" -l -i -c '\''exec /bin/sh -c "$CODEX_REMOTE_PAYLOAD"'\''' sh 'PATH="$HOME/.local/bin:$PATH"; export PATH; exec codex app-server proxy'
        """#

        #expect(CodexRemoteHostDiscovery.hosts(fromProcessList: processList) == ["station"])
    }
}
