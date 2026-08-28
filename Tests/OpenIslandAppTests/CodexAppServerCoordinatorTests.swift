import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct CodexAppServerCoordinatorTests {
    @Test
    func historicalThreadSyncPreservesCodexUpdatedAt() throws {
        let thread = try JSONDecoder().decode(CodexThread.self, from: Data(#"""
        {
          "id":"historical-thread",
          "cwd":"/home/developer/project",
          "name":"Historical task",
          "preview":"Old work",
          "modelProvider":"openai",
          "createdAt":900,
          "updatedAt":1000,
          "ephemeral":false,
          "path":"/home/developer/.codex/rollout.jsonl",
          "status":{"type":"idle"},
          "source":"vscode",
          "turns":[]
        }
        """#.utf8))

        let started = CodexAppServerCoordinator.sessionStarted(
            from: thread,
            remoteHost: "station",
            observedAt: Date(timeIntervalSince1970: 9_999)
        )

        #expect(started.timestamp == Date(timeIntervalSince1970: 1_000))
    }
}
