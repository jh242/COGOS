# Persistent Agent Refactor Plan: OpenRouter-first COGOS

This document defines the planned refactor from the current `EvenAISession` chat orchestrator into a persistent, OpenRouter-optimized wearable agent runtime.

The goal is not to introduce a generic agent framework. The goal is to make COGOS stateful, tool-capable, persistent across launches, and tuned for Even Realities G1 display constraints while preserving the app's OpenAI-compatible endpoint story.

## Current state

Today, `EvenAISession` owns too many responsibilities:

- mic lifecycle
- streaming speech recognition
- silence detection
- recording timeout
- LLM call orchestration
- response streaming
- G1 0x54 text rendering
- conversation history updates
- reset/stop session state

`ClaudeSession` currently acts as ephemeral conversation memory, but it is not durable, not compacted, and not an agent state model.

`ChatCompletionsClient` currently targets OpenAI-compatible `/v1/chat/completions` APIs and should remain the compatibility baseline.

## Target architecture

COGOS should own the agent runtime.

OpenRouter should be the primary production backend.

The runtime should normalize events, memory, tools, and rendering internally, then serialize to OpenRouter's OpenAI-compatible Chat Completions API at the model boundary.

```text
G1 gestures / voice / app events
  -> AgentRuntime
  -> AgentMemoryStore + ContextCompiler
  -> OpenRouterBackend
  -> ToolRunner when needed
  -> AgentRenderer
  -> EvenTextRenderer / app UI / history
```

## Non-goals

- Do not adopt SwiftAgent as the core runtime.
- Do not optimize around Apple Foundation Models.
- Do not make MCP the first-class tool system yet.
- Do not build autonomous background scheduling in the first pass.
- Do not migrate to SQLite unless JSON persistence becomes painful.
- Do not require native provider-specific APIs beyond OpenAI-style Chat Completions in the initial implementation.

## Design principles

### COGOS owns persistence

Provider sessions are not the source of truth. The app owns:

- recent turns
- rolling summaries
- durable transcript entries
- stable user/device facts
- active goals, eventually
- sidebar/gesture bindings

### OpenRouter is the primary backend

The production path should assume:

- `POST /chat/completions`
- OpenAI-style messages
- OpenAI-style tool definitions
- streaming when practical
- provider/model routing knobs later

Keep a custom base URL escape hatch so local OpenAI-compatible servers, OpenRouter-compatible proxies, or other hosted routers remain possible.

### Tool schema follows OpenAI function tools

Use OpenAI-style function tool schemas internally because OpenRouter and most OpenAI-compatible routers standardize around that shape.

```json
{
  "type": "function",
  "function": {
    "name": "get_weather",
    "description": "Get current weather for a location.",
    "parameters": {
      "type": "object",
      "properties": {
        "location": { "type": "string" }
      },
      "required": ["location"]
    }
  }
}
```

The runtime should still use neutral names such as `ToolSpec`, `ToolCall`, and `ToolResult`, but the JSON shape can intentionally match OpenAI function tools.

### Display rendering is not model logic

The model loop should emit semantic events. The renderer decides how to present them on the G1.

Do not stream raw tool-call JSON or partial tool arguments to the glasses.

## Proposed file layout

```text
COGOS/Agent/
  AgentRuntime.swift
  AgentState.swift
  AgentEvent.swift
  AgentTranscript.swift
  AgentMemory.swift
  AgentMemoryStore.swift
  ContextCompiler.swift
  MemoryCompactor.swift
  AgentReducer.swift

COGOS/Agent/LLM/
  LLMBackend.swift
  OpenRouterBackend.swift
  ChatMessage.swift
  LLMRequest.swift
  LLMBackendEvent.swift
  OpenRouterModelProfile.swift

COGOS/Agent/Tools/
  AgentTool.swift
  ToolSpec.swift
  ToolCall.swift
  ToolResult.swift
  ToolRegistry.swift
  ToolRunner.swift
  BuiltinTools/

COGOS/Agent/Render/
  AgentRenderer.swift
  EvenTextRenderer.swift
  DebugRenderer.swift

COGOS/Agent/Bindings/
  AgentBinding.swift
  SidebarBindingStore.swift

COGOS/Session/
  VoiceCaptureController.swift
```

## Core types

### AgentEvent

```swift
enum AgentEvent: Codable, Sendable {
    case appLaunched
    case glassesConnected
    case glassesDisconnected
    case voiceTranscriptFinal(String)
    case gesture(GestureEventRecord)
    case sidebarDoubleClick(SidebarID)
    case userCancelled
    case resetRequested
}
```

### AgentPhase

```swift
enum AgentPhase: Codable, Sendable {
    case idle
    case listening
    case transcribing
    case planning
    case callingTools([String])
    case responding
    case awaitingClarification
    case failed(String)
}
```

### AgentRuntime

```swift
actor AgentRuntime {
    private let memoryStore: AgentMemoryStore
    private let contextCompiler: ContextCompiler
    private let backend: LLMBackend
    private let tools: ToolRegistry
    private let renderer: AgentRenderer

    func handle(_ event: AgentEvent) async {
        var memory = await memoryStore.load()
        await memoryStore.append(.event(event))

        let request = contextCompiler.compile(
            event: event,
            memory: memory,
            tools: tools.specs
        )

        do {
            let result = try await runLoop(request)
            memory.apply(event: event, result: result)
            memory = try await maybeCompact(memory)
            await memoryStore.save(memory)
            await renderer.render(.finalText(result.displayText))
        } catch {
            await renderer.render(.failed(error.localizedDescription))
        }
    }
}
```

### AgentMemory

```swift
struct AgentMemory: Codable, Sendable {
    var rollingSummary: String
    var recentTurns: [ConversationTurn]
    var stableFacts: [MemoryFact]
    var activeGoals: [AgentGoal]
    var sidebarBindings: [SidebarBinding]
    var lastDeviceContext: DeviceContext?
}
```

Start with only `rollingSummary`, `recentTurns`, and `sidebarBindings` if necessary. The rest can be added without changing the runtime shape.

### AgentTranscriptEntry

```swift
enum AgentTranscriptEntry: Codable, Sendable {
    case event(AgentEventRecord)
    case userUtterance(String, at: Date)
    case assistantDelta(String, at: Date)
    case assistantFinal(String, at: Date)
    case toolCall(ToolCallRecord)
    case toolResult(ToolResultRecord)
    case memoryCompaction(MemorySummaryRecord)
    case error(AgentErrorRecord)
}
```

Use the transcript as a durable event ledger. Use `AgentMemory` as compacted derived state.

## LLM backend

### LLMBackend

```swift
protocol LLMBackend: Sendable {
    var capabilities: LLMCapabilities { get }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMBackendEvent, Error>
}
```

### LLMCapabilities

```swift
struct LLMCapabilities: Codable, Sendable {
    var supportsNativeTools: Bool
    var supportsStreaming: Bool
    var supportsStreamingToolCalls: Bool
    var supportsStructuredOutput: Bool
}
```

### LLMBackendEvent

```swift
enum LLMBackendEvent: Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    case final
}
```

### OpenRouterBackend

`OpenRouterBackend` should be the first concrete implementation.

It should support:

- configurable API key
- configurable model
- configurable base URL, defaulting to OpenRouter
- OpenAI-style chat messages
- OpenAI-style tools
- streaming text deltas
- tool-call parsing
- one-shot fallback if streaming is disabled

It should preserve compatibility with current `OpenAICompatibleClient` behavior where possible.

## Tool system

### ToolSpec

```swift
struct ToolSpec: Codable, Sendable {
    let type: String
    let function: Function

    struct Function: Codable, Sendable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }
}
```

### AgentTool

```swift
protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    func call(_ arguments: JSONValue, context: ToolContext) async throws -> JSONValue
}
```

### ToolRunner

`ToolRunner` should execute finalized tool calls only. Do not execute partial streamed tool-call deltas.

Tool failures should be returned to the model as tool-result messages when possible, so the model can recover. Repeated failures should produce a compact user-visible error.

### Initial tools

Start with small, safe, app-local tools:

- `get_current_context`
- `get_recent_history`
- `write_quick_note`
- `set_dashboard_card`, if the dashboard model is ready

Weather/news tools can follow after the runtime is stable.

## Model/tool run loop

The runtime must not assume one model call equals one user-visible answer.

```swift
while true {
    let output = try await backend.completeOrStream(request)

    if output.toolCalls.isEmpty {
        return output.finalAnswer
    }

    request.messages.append(output.assistantMessageWithToolCalls)

    let results = try await toolRunner.run(output.toolCalls)
    request.messages.append(contentsOf: results.map { $0.asToolMessage() })
}
```

For the first implementation, cap tool iterations to a small number such as 3 to prevent loops.

## Streaming policy

When tools are disabled or not expected:

- stream text deltas directly to `EvenTextRenderer`
- send final complete frame when done

When tools are enabled:

- show a compact thinking/status message
- buffer tool-planning output
- execute finalized tool calls
- stream only the final answer to the glasses

Never stream partial tool-call JSON to the G1 display.

## Renderer extraction

Extract the existing G1 0x54 display logic from `EvenAISession` into `EvenTextRenderer`.

Preserve the current behavior:

- send prepare frame before a fresh answer
- send cumulative text updates while tokens arrive
- send complete frame at the end so firmware scroll mode works
- keep the existing text formatting convention unless intentionally changed

Proposed interface:

```swift
protocol AgentRenderer: Sendable {
    func render(_ event: AgentRunEvent) async
}

enum AgentRunEvent: Sendable {
    case started
    case thinking(String?)
    case partialText(String)
    case toolStarted(name: String)
    case toolFinished(name: String)
    case finalText(String)
    case failed(String)
}
```

## Voice extraction

Extract mic/STT/silence handling from `EvenAISession` into `VoiceCaptureController`.

`VoiceCaptureController` should emit final transcript events rather than directly calling the LLM.

`EvenAISession` should become the compatibility facade that wires:

- BLE/proto
- speech recognizer
- voice capture
- agent runtime
- renderer
- published SwiftUI state

## Sidebar bindings

Double-clicking any sidebar from neutral state should eventually emit:

```swift
AgentEvent.sidebarDoubleClick(sidebarID)
```

Default behavior must be unbound.

Bindings should be persisted separately from conversation memory.

Initial binding shape:

```swift
struct SidebarBinding: Codable, Sendable {
    let sidebarID: SidebarID
    var action: AgentBindingAction?
}

enum AgentBindingAction: Codable, Sendable {
    case prompt(String)
    case tool(name: String, arguments: JSONValue)
    case mode(String)
}
```

## Settings

Add settings gradually:

- OpenRouter API key
- model ID
- base URL, default OpenRouter
- max output tokens
- native tools enabled
- JSON fallback enabled
- summarizer model, later
- tool model override, later

Keep the current custom OpenAI-compatible endpoint escape hatch.

## Implementation phases

### Phase 1: Renderer and voice extraction, no behavior change

Create:

- `EvenTextRenderer`
- `VoiceCaptureController`

Refactor `EvenAISession` to delegate display and recording responsibilities.

Acceptance criteria:

- voice ask still works
- same 0x54 prepare/text/complete behavior
- same no-speech and API-error messages
- reset still works
- history still records Q/A
- no new persistence required

### Phase 2: AgentRuntime skeleton with persistent conversation

Create:

- `AgentRuntime`
- `AgentEvent`
- `AgentMemory`
- `AgentMemoryStore`
- `ContextCompiler`

Wire voice transcript into `AgentRuntime.handle(.voiceTranscriptFinal(text))`.

Acceptance criteria:

- conversation survives app restart
- recent turns are persisted
- old `ClaudeSession` is removed or reduced to a compatibility shim
- model request construction is owned by `ContextCompiler`

### Phase 3: OpenRouterBackend cleanup

Rename or wrap the existing chat client into `OpenRouterBackend` / `ChatCompletionsBackend`.

Acceptance criteria:

- default base URL can be OpenRouter
- custom OpenAI-compatible base URL still works
- streaming and one-shot paths still work
- model ID remains user-configurable

### Phase 4: Native OpenAI-style tools

Create:

- `ToolSpec`
- `AgentTool`
- `ToolRegistry`
- `ToolRunner`

Add the first app-local tool.

Acceptance criteria:

- backend sends OpenAI-style tools when enabled
- tool calls are parsed and executed client-side
- tool results are appended as tool messages
- tool loop has max iteration protection
- final answer is display-safe

### Phase 5: Prompt JSON fallback

Add fallback for models/providers that do not reliably support native tools.

Acceptance criteria:

- tool mode can be `native`, `promptJSON`, `disabled`, or `auto`
- malformed JSON gets one repair attempt
- failures do not leak raw JSON to the glasses

### Phase 6: Memory compaction

Add rolling summary compaction.

Acceptance criteria:

- recent turns stay bounded
- older context is summarized
- compaction result is persisted
- transcript remains available for debugging/history

### Phase 7: Sidebar bindings

Add persistent sidebar double-click bindings.

Acceptance criteria:

- neutral double-click emits an agent event
- default binding is nil/unbound
- user can assign a prompt/tool/mode later
- bound action routes through `AgentRuntime`

## Testing strategy

Add unit tests for:

- context compilation
- memory load/save
- transcript append
- tool-call parsing
- tool-run loop max iteration protection
- renderer event mapping using a mock proto
- voice controller timeout/silence behavior with fake recognizer

Add mock backends:

- plain text response
- streamed text response
- single tool call then final answer
- malformed tool call
- repeated tool loop attempt

## Migration notes

During migration, prefer compatibility wrappers over large rewrites.

Keep `EvenAISession` public API stable for SwiftUI views until the agent runtime is working.

Once the runtime is stable, remove old session-memory paths and retire `ClaudeSession`.

## First Codex task

Implement Phase 1 only.

Do not add tools yet.
Do not add persistence yet.
Do not change model provider behavior yet.
Do not change the user-facing voice flow.

Refactor the current implementation so `EvenAISession` delegates:

- display streaming to `EvenTextRenderer`
- mic/STT/silence/timeout lifecycle to `VoiceCaptureController`

Behavior should remain identical.