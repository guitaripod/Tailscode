import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The Range chart of what is in the window, drawn from the agent's own count when it gave one.
@Suite struct MeasuredCompositionTests {
    private static let measured = MeasuredContext(
        model: "claude-opus-5-5", totalTokens: 50_000, maxTokens: 1_000_000, autoCompactAt: 967_000,
        categories: [
            .init(id: "system_prompt", name: "System prompt", tokens: 4_000, kind: "used"),
            .init(id: "system_tools", name: "System tools", tokens: 12_000, kind: "used"),
            .init(id: "mcp_tools", name: "MCP tools", tokens: 2_000, kind: "used"),
            .init(id: "system_tools_deferred", name: "Deferred", tokens: 20_000, kind: "deferred"),
            .init(id: "memory_files", name: "Memory files", tokens: 6_000, kind: "used"),
            .init(id: "messages", name: "Messages", tokens: 26_000, kind: "used"),
            .init(id: "autocompact_buffer", name: "Autocompact buffer", tokens: 33_000, kind: "buffer"),
            .init(id: "free_space", name: "Free space", tokens: 900_000, kind: "free"),
        ],
        messages: .init(user: 1_000, assistant: 5_000, toolCalls: 2_000, toolResults: 17_000, attachments: 0, other: 1_000),
        memoryFiles: [], measuredAt: Date())

    @Test func theSlicesAreTheAgentsOwnCount() throws {
        let composition = try #require(ContextComposition.read(measured: Self.measured, messages: []))
        #expect(composition.measured)
        #expect(composition.total == 50_000)
        let tokens = Dictionary(uniqueKeysWithValues: composition.slices.map { ($0.id, $0.tokens) })
        #expect(tokens["system"] == 4_000)
        #expect(tokens["tools-defined"] == 14_000)
        #expect(tokens["memory"] == 6_000)
        #expect(tokens["tools"] == 19_000)
        #expect(tokens["answers"] == 5_000)
        #expect(tokens["you"] == 1_000)
        #expect(tokens["other"] == 1_000)
        #expect(tokens["attachments"] == nil)
        #expect(composition.slices.reduce(0) { $0 + $1.tokens } == 50_000)
    }

    @Test func theBoardPrefersTheMeasurement() {
        let board = RangeBoard.read(
            messages: [], fill: nil, quotas: [], model: nil, measured: Self.measured)
        #expect(board.composition?.measured == true)
        #expect(RangeSheetWords.compositionTotal("50k", measured: true).contains("measured by the agent"))
    }
}
