import Testing
import Foundation
@testable import Sotto

struct ChatBackendTests {

    @Test func messageAndToolCallModelsPreserveFidelity() {
        let toolCall = ToolCall(id: "call_123", name: "calculate", arguments: "{\"x\": 42}")
        #expect(toolCall.id == "call_123")
        #expect(toolCall.name == "calculate")
        #expect(toolCall.arguments.contains("42"))

        let msg = ChatMessage(
            role: .assistant,
            content: "Calculating...",
            model: "test-model",
            toolCalls: [toolCall]
        )
        #expect(msg.role == .assistant)
        #expect(msg.model == "test-model")
        #expect(msg.toolCalls?.count == 1)
        #expect(msg.toolCalls?.first?.name == "calculate")

        let toolRes = ToolResult(callId: "call_123", name: "calculate", content: "{\"result\": 84}")
        #expect(toolRes.callId == "call_123")
        #expect(toolRes.content.contains("84"))
    }

    @Test func localServerEndpointsHaveExpectedDefaults() {
        #expect(LocalServerEndpoint.ollama.defaultPort == 11434)
        #expect(LocalServerEndpoint.ollama.baseURL.absoluteString == "http://localhost:11434")

        #expect(LocalServerEndpoint.llamaServer.defaultPort == 8080)
        #expect(LocalServerEndpoint.llamaServer.baseURL.absoluteString == "http://localhost:8080")

        #expect(LocalServerEndpoint.lmStudio.defaultPort == 1234)
        #expect(LocalServerEndpoint.lmStudio.baseURL.absoluteString == "http://localhost:1234")
    }

    @Test func appleFoundationBackendReportsMetadata() {
        let backend = AppleFoundationBackend(id: "system-test")
        #expect(backend.id == "system-test")
        #expect(backend.backendType == .appleFoundation)
    }

    @Test func openAICompatibleBackendConfiguration() {
        let url = URL(string: "http://127.0.0.1:11434")!
        let backend = OpenAICompatibleBackend(id: "qwen2.5:7b", baseURL: url)
        #expect(backend.id == "qwen2.5:7b")
        #expect(backend.baseURL == url)
        #expect(backend.backendType == .openAI)
    }
}
