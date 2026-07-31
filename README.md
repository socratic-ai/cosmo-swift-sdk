# CosmoAI Swift SDK

Native async/await Swift client for the Cosmo Realtime API.

> **Beta.** CosmoAI is pre-1.0: minor releases (`0.x` → `0.y`) may include
> breaking API changes, so pin with `.upToNextMinor`. We will cut 1.0 once the
> wire protocol and the public session API have stabilized.

> New to the SDK? Start with the [Developer Guide](../docs/developer-guide.md)
> — getting started, the credential model, and the expected session lifecycle.

## Requirements

- macOS 13+ or iOS 16+
- Swift 5.9+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(
        url: "https://github.com/socratic-ai/cosmo-swift-sdk",
        .upToNextMinor(from: "0.1.0")
    ),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            // The package resolves as `CosmoAI`; the module you import
            // is `CosmoRealtime`.
            .product(name: "CosmoRealtime", package: "cosmo-swift-sdk"),
        ]
    ),
]
```

Or add via Xcode: **File → Add Package Dependencies…**, paste
`https://github.com/socratic-ai/cosmo-swift-sdk`, and pick
**Up to Next Minor Version** from `0.1.0`.

### Local path (inside this repository)

```swift
dependencies: [
    // `name:` aliases the path-based package to `CosmoAI`. Without it
    // SwiftPM derives the identity from the directory name (`swift`), and
    // `package: "CosmoAI"` below fails to resolve.
    .package(name: "CosmoAI", path: "../sdks/cosmo-realtime/swift"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "CosmoRealtime", package: "CosmoAI"),
        ]
    ),
]
```

## Quickstart

One call starts a session; everything the server says arrives on a single
typed event stream.

```swift
import CosmoRealtime

let session = try await RealtimeSession.start(
    .init(
        apiKey: "your-api-key",
        baseURL: URL(string: "https://app.askcosmo.ai")!
    ),
    config: SessionConfig(
        instructions: "You are a terse assistant.",
        tools: [
            // Client tool: attach a handler to make it executable. The
            // agent runs it over the transport; the returned object is
            // reported back as the result.
            .client(
                name: "get_local_time",
                description: "Returns the local wall-clock time.",
                parameters: ["type": .string("object")],
                handler: { _ in ["time": .string("12:00")] }
            ),
            .webSearch,
        ]
    )
)

for try await event in session.events {
    switch event {
    case .ready(let ready):
        print("live — session:", ready.sessionId)
        try await session.send(text: "Hello!")
    case .transcript(let delta):
        print(delta.text)
    case .toolInvocation(let invocation):
        // Observability: the agent invoked a client tool. Execution +
        // reply happen via the tool's handler over RPC — nothing to send
        // here.
        print("tool invoked:", invocation.name)
    case .sessionEnded(let ended):
        print("session over:", ended.reason ?? "")
    case .unknown(let rawType, _):
        print("unrecognized event:", rawType ?? "<not JSON>")  // never terminal
    default:
        break
    }
}
```

## API

### `RealtimeSession.Options`

Client-level settings; pass once per `start`.

| Property | Type | Default |
|---|---|---|
| `apiKey` | `String` | required |
| `baseURL` | `URL` | required |
| `connectTimeout` | `TimeInterval` | `30` |
| `requestTimeout` | `TimeInterval` | `45` |
| `defaultConfig` | `SessionConfig` | empty |

`defaultConfig` carries client-level defaults (model, voice, instructions,
tools); per-call `SessionConfig` values win field by field.

### `SessionConfig`

Per-session configuration. Every field is optional — unset fields stay off
the wire and the server applies neutral defaults.

| Field | Meaning |
|---|---|
| `model` | Provider/model selection |
| `voice` | Provider-specific prebuilt voice id |
| `instructions` | System instructions |
| `tools` | `.client(name:description:parameters:handler:)` / `.backgroundClient(...)` specs this app fulfils, and typed zero-config server-tool opt-ins (`.webSearch`, `.examineImage`, `.detect`, `.point`) |
| `interruptionSensitivity` | How readily the user's speech interrupts the agent (`.default` / `.low` / `.high`) |
| `noiseCancellationEnabled` | Enable upstream input noise cancellation |
| `resumeSessionId` | Resume a prior session (rides under the experimental knobs) |

A `.client` tool with a `handler` is executable: the agent invokes it over
the transport (LiveKit RPC), the SDK runs `await handler(args)`, and the
returned object is reported back as the result (throw to surface a tool
error). Handlers are local-only — never serialized, never on the wire. A
spec without a handler is still declared to the agent but only surfaces its
invocation as a `.toolInvocation` observability event.

### Event stream

`session.events` is a single-consumer `AsyncThrowingStream` of
`RealtimeSession.Event` — one case per server event (`ready`, `transcript`,
`modelText`, `turnComplete`, speech/LLM/TTS phases, the tool lifecycle,
`reconnecting`, `error`, `pong`) plus:

- `.unknown(rawType:payload:)` — any unrecognized or undecodable frame.
  Forward compatibility is explicit: decode failure is **never** terminal.
- `.sessionEnded(_)` — always the final element; the stream finishes after
  it. The external protocol has no server-sent end event — the transport
  close is the signal — so this sentinel is synthesized locally (on
  `end()`, teardown, or a transport drop). Start failures throw from
  `start(...)` instead (e.g. `RealtimeSessionError.versionMismatch`).

Oversized server messages arrive chunked (`server-envelope-chunk`) and are
reassembled transparently before they surface as events.

`session.states` separately reports the transport lifecycle (`idle`,
`connecting`, `connected`, `reconnecting`/`reconnected`,
`disconnected(reason:)`).

### Sends

```swift
try await session.send(text: "Hello", audioResponse: true)
try await session.setMuted(true)
try await session.ping()
await session.end()   // graceful: wire end frame, then teardown
```

Client tools are not sent here — declare a `handler` on the `.client` tool
spec and the SDK runs it over the transport when the agent invokes it.

## Hooks

Attach lifecycle observers and policy gates to any session via `HookRegistry`.
Four events fire: **SessionStart** (before the wire frame is sent), **PreToolUse**
(before a client tool runs), **PostToolUse** (after), and **SessionEnd** (once, on
any exit path). A fired server-hook silence timeout (a `Hook.server(SilenceTimeout(...))`
entry in the session's `hooks` list) reaches you as a `.userSpeechTimeout` event on
the session's event stream, not as a hook. SessionStart and PreToolUse carry honored overrides: return
`SessionStartResult(additionalContext:)` to inject additional instructions, or
return `PreToolUseResult(permission: .deny, reason:)` to block a client tool
before it executes. A throwing hook is logged and skipped; sibling hooks still
run. Hooks are local-only — closures are never serialized or sent on the wire.

```swift
var hooks = HookRegistry()

// Block any client tool whose name matches the "delete_*" glob.
hooks.onPreToolUse(matcher: "delete_*") { _ in
    PreToolUseResult(permission: .deny, reason: "destructive tools are disabled")
}

// Observe when the session ends.
hooks.onSessionEnd { ctx in
    print("session stopped:", ctx.reason ?? "unknown")
}

let agent = Agent(
    tools: [
        .client(
            name: "read_file",
            description: "Read a file from disk.",
            parameters: ["type": .string("object")],
            handler: { _ in ["content": .string("…")] }
        ),
    ],
    hooks: hooks
)
let session = try await agent.start(options)
```

Pass `hooks` on `SessionConfig` directly when using `RealtimeSession` without
the `Agent` layer.

### Live e2e (`HooksExample`)

`Examples/HelloRealtime/Sources/HooksExample` is a self-contained runnable
harness that exercises all four hooks in one headless session: SessionStart
(inject caller context), PreToolUse/deny (block `delete_account` before it
runs), PreToolUse/rewrite (force `account=primary` on `get_account_balance`),
PostToolUse (observe outcome), and SessionEnd (observe exit reason).

```
COSMO_API_KEY=...  COSMO_BASE_URL=https://app.askcosmo.ai \
  cd Examples/HelloRealtime && swift run HooksExample
```

Each `◆ HOOK` line in the output proves the corresponding hook fired. The
`▶ handler delete_account` line must not appear — the PreToolUse/deny hook
suppresses it before the handler is invoked.

## Legacy surface (deprecated)

`CosmoRealtimeClient` — `connect(init:)` plus the per-event `on*` listener
registry — speaks the legacy first-party protocol and remains in this
package **only** for the Cosmo Mac app, which migrates to
`RealtimeSession`; the legacy surface is removed once that migration lands.
Do not build new integrations on it.

## Authentication

Workspace-scoped API key with `realtime:use` scope, passed as:

```
Authorization: Bearer <key>
```

The key is injected automatically via `RealtimeSession.Options.apiKey`.

## Architecture

```
RealtimeSession (actor)                  — public stream API
 ├── events / states                     — AsyncThrowingStream / AsyncStream
 ├── EnvelopeReassembler (actor)         — server-envelope-chunk reassembly
 └── SessionTransport                    — protocol-agnostic transport seam
      └── LiveKitSessionTransport        — production implementation
           ├── CosmoRealtimeAPI.Client   — POST /api/v1/external/realtime/session/start
           └── Room (LiveKit)            — WebRTC audio + data channel
```

Generated wire types live in the internal `CosmoRealtimeAPI` module
(regenerated on every build from `../external-openapi.json`, which the
monorepo backend's `scripts/export_realtime_openapi.py` maintains) and are re-exposed
under clean names (`RealtimeSession.Ready`, `RealtimeSession.TranscriptDelta`,
…) so consumers only ever `import CosmoRealtime`. The legacy
`CosmoRealtimeClient` generates its types from the legacy spec
(`Sources/CosmoRealtime/openapi.json`) into the `CosmoRealtime` module
itself; the two generated namespaces coexist until the legacy surface is
removed.

## Contract traces

The SDK's protocol behavior is pinned by the language-neutral contract
traces under [`../contract/`](../contract/README.md). The
`ExternalContractTraceTests` suite executes every trace in
`contract/external-traces/` against `RealtimeSession` over an in-memory
fake transport — offline, no LiveKit — on every `swift test`. The legacy
lifecycle traces have no Swift runner; they document the legacy surface
until it is removed.

## Example

See [`Examples/HelloRealtime/`](Examples/HelloRealtime/) for a runnable macOS
command-line program on the legacy surface that connects, listens for
transcripts, sends a text message, and disconnects — no audio required.

```bash
cd Examples/HelloRealtime
COSMO_API_KEY=your-key COSMO_PROJECT_ID=your-project-id swift run
```

## Testing

The SDK ships two test targets:

- **`CosmoRealtimeTests`** — pure unit tests + the external contract-trace suite. No network, no LiveKit server. Runs on every `swift test`.
- **`CosmoRealtimeE2ETests`** — exercises the full connect / send / receive / disconnect cycle against a real `livekit-server` in dev mode. **Skipped unless `LIVEKIT_TESTING_URL` is set.**

### Run the unit tests

```bash
cd sdks/cosmo-realtime/swift
swift test                       # only the unit suite — fast, offline
```

### Run the full suite (E2E included)

1. Start a local LiveKit server (re-uses the dev-mode compose file the
   monorepo backend already maintains in its `scripts/` dir):

   ```bash
   docker compose -f docker-compose.livekit.yml up -d
   ```

2. Run `swift test` with the env vars pointing at it:

   ```bash
   cd sdks/cosmo-realtime/swift
   LIVEKIT_TESTING_URL=ws://localhost:7880 \
     LIVEKIT_TESTING_API_KEY=devkey \
     LIVEKIT_TESTING_API_SECRET=devsecretdevsecretdevsecretdevse \
     swift test
   ```

3. Stop the server when done (same dir):

   ```bash
   docker compose -f docker-compose.livekit.yml down
   ```

CI runs the E2E suite automatically — see `.github/workflows/realtime-swift-ci.yml`. It downloads the `livekit-server` binary (pinned to the same version as the docker-compose) instead of using docker, because GitHub macOS runners don't pre-install Docker Desktop.

## Skills

Attach **Agent Skills** (the `SKILL.md` standard) to the model through the
same `Agent` layer. A `SkillRegistry` of parsed `SKILL.md` files becomes a single
resident `load_skill` tool plus a hot-set menu appended to `SessionConfig.instructions`;
the model calls `load_skill(name)` when the conversation reaches a skill's path and
receives the body as private, never-spoken instructions for the rest of the call.

```swift
let skills = SkillRegistry([
    try parseSkillMd(refundsMarkdown, defaultName: "refunds"),
])
let agent = Agent(skills: skills)
let session = try await agent.start(
    RealtimeSession.Options(token: jwt, baseURL: baseURL),
    config: SessionConfig(instructions: "You are a terse support agent."))
// the menu is now resident; the model can call load_skill("refunds")
await session.end()
```

Only `hot`-tier skills ride resident (`name` + `description`); the `search` tier is
deferred. `Agent` composes skills, MCP, and caller tools together — all land in
`SessionConfig.tools`.

## MCP servers (local stdio)

Expose a local [MCP](https://modelcontextprotocol.io) server's tools to the
realtime model through the `Agent` layer. Declare servers in a Claude-Code
`.mcp.json`; the SDK spawns each, lists its tools, and proxies calls — tools are
namespaced `mcp__<server>__<tool>` and ride in `SessionConfig.tools` as ordinary
client tools.

```swift
let registry = try McpRegistry.fromConfigFile(url)
let agent = Agent(mcp: registry)
let session = try await agent.start(
    RealtimeSession.Options(token: jwt, baseURL: baseURL))
// drive session.session.events … ; then:
await session.end()
```

v1 supports **stdio** servers (macOS — subprocess); remote (`url`) entries in
`.mcp.json` are skipped with a warning. A `StdioServer` runs an arbitrary local
command — trust your config. No third-party dependency is added.

## License

Copyright (c) 2025 Socratic Inc. All rights reserved. See [LICENSE](LICENSE).
