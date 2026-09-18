# CosmoAI Swift SDK

Native async/await Swift client for the Cosmo Realtime API.

> **Beta.** CosmoAI is pre-1.0: minor releases (`0.x` → `0.y`) may include
> breaking API changes — check the
> [changelog](https://platform.askcosmo.ai/docs/meta/changelog) when you
> update. Cosmo cuts 1.0 once the wire protocol and the public session API
> have stabilized.

> New to the SDK? Start with the [documentation](https://platform.askcosmo.ai/docs)
> — getting started, the credential model, and the expected session lifecycle.

Source of truth and issue tracker:
[socratic-ai/cosmo-ai](https://github.com/socratic-ai/cosmo-ai) (the `swift/`
directory). The
[cosmo-swift-sdk](https://github.com/socratic-ai/cosmo-swift-sdk) repository is
the Swift Package Manager distribution of the same code — re-rooted and tagged,
because SwiftPM consumes a repository whose root is the package. Install from
it; file issues on cosmo-ai.

## Requirements

- macOS 13+ or iOS 16+
- Swift 5.9+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/socratic-ai/cosmo-swift-sdk", from: "0.8.0"),
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
`https://github.com/socratic-ai/cosmo-swift-sdk`, and keep the default
**Up to Next Major Version**.

The `from:` range accepts every release below 1.0, and the
[documentation](https://platform.askcosmo.ai/docs) describes the latest
release — if a documented API is missing in your build, run
`swift package update` first.

On **0.7.0 and earlier**, the first Xcode build fails with `Validate plug-in
"OpenAPIGenerator" … must be enabled before it can be used`: those versions
generate their API client during the build, and Xcode will not run a package
build plugin until you trust it. Click **Trust & Enable**, or find it under
**File → Packages → Trust & Enable Plugins**. Where nothing can answer the
prompt — Xcode Cloud, or any headless runner — pass
`-skipPackagePluginValidation` to `xcodebuild`. Later versions ship the
generated client already built, so there is no plugin and no prompt.

## Teach your agent first

If a coding agent is writing this code, install the Agent Skill before the
quickstart:

```bash
npx skills add socratic-ai/cosmo-ai
```

One [Agent Skill](https://agentskills.io) covers the whole Cosmo SDK family
(TypeScript, Python, Swift): the current SDK API, the credential and login
rules, and the production token flow. It works with Claude Code, Cursor,
Codex CLI, Gemini CLI, and anything else that reads the skills format.

Agents can also read the docs directly:
https://platform.askcosmo.ai/docs (`/docs/llms.txt`, `/docs/llms-full.txt`, and
an MCP endpoint at `/docs/api/mcp`).

## Quickstart

Three objects, one per concern: a **client** holds your credential, an
**agent** is a reusable persona, and a **session** is one live run.
Everything the server says arrives on a single typed event stream.

```swift
import CosmoRealtime

struct WeatherArgs: Decodable, Sendable {
    let city: String
}

let client = RealtimeClient(apiKey: "cosmo_your_api_key")

let agent = try client.agent(
    instructions: "You are a terse assistant.",
    tools: [
        // Client tool: the agent runs it over the transport and the
        // returned object is reported back as the result.
        try AgentTool.clientTool(
            name: "get_weather",
            description: "Current weather for a city.",
            input: .object(
                properties: ["city": .string(description: "City name")],
                required: ["city"]
            )
        ) { (args: WeatherArgs) in
            ["temp": .double(21.5), "city": .string(args.city)]
        },
        .webSearchTool(),
    ],
    greeting: "Hi — what can I do for you?"
)

let session = try await agent.start()

for try await event in session.events {
    switch event {
    case .ready(let ready):
        print("live — session:", ready.sessionId)
        try await session.send(text: "Hello!")
    case .transcript(let delta):
        // A console is append-only: print each completed turn once, off
        // the raw delta stream. A UI renders the session-owned
        // ``session.transcript`` wholesale instead.
        if delta.isFinal && !delta.text.isEmpty { print("[\(delta.role)] \(delta.text)") }
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

The microphone is published during `agent.start(...)` unless you pass
`micMuted: true`. Nothing is captured or sent until the first
`setMuted(false)` — do that for a push-to-talk UX, and to be sure a session
your UI presents as muted never streams audio during the connect window.

Microphone permission depends on how you run the binary. A bare `swift run`
executable has no bundle, so it has no `NSMicrophoneUsageDescription` of its
own and inherits the *host terminal's* microphone grant — fine for a
prototype, and confusing when the terminal has no grant. A shipped `.app`
needs its own purpose string. See
[Packaging a macOS app](https://platform.askcosmo.ai/docs/guides/packaging-macos).

## API

### `RealtimeClient`

Client-level settings are the initializer's parameters; there are four
initializers, one per credential form, sharing these trailing parameters:

| Parameter | Type | Default |
|---|---|---|
| `baseURL` | `URL?` | resolved |
| `connectTimeout` | `TimeInterval` | `30` |
| `requestTimeout` | `TimeInterval` | `45` |
| `verifyTLS` | `VerifyTLS` | `.auto` |
| `transport` | `RealtimeClient.Transport` | `.webrtc` (`.livekit` is a deprecated alias) |

Which credential you use is a deployment decision:

```swift
// Workspace-scoped key. Server-side only — it opens sessions AND mints
// end-user tokens. Never embed it in a distributed app.
RealtimeClient(apiKey: "cosmo_…")

// A minted per-user JWT, scoped to one external user. Safe to ship in a
// device or browser: it opens sessions but cannot mint.
RealtimeClient(token: jwt)

// A TokenSource: the SDK fetches the JWT from your minting endpoint,
// caches it, and re-fetches as expiry nears — no refresh code in the app.
RealtimeClient(tokenSource: try .endpoint(
    URL(string: "https://your-backend.example.com/token")!,
    headers: ["Authorization": "Bearer \(appSession)"]
))

// Zero-argument: resolves an API key itself — COSMO_API_KEY, else the
// `cosmo login` credentials file (~/.cosmo/credentials, profile from
// COSMO_PROFILE; the CLI installs with `pipx install cosmo-cli`),
// adopting the backend the stored key was issued for.
// Throws CredentialsError when nothing usable resolves.
try RealtimeClient()
```

Left unset, `baseURL` resolves from `COSMO_BASE_URL` — the same variable the
Python and TypeScript SDKs read — falling back to
`https://platform.askcosmo.ai`. Set it explicitly if your key's workspace does not
live on `platform.askcosmo.ai`: Cosmo also serves `https://assistant.askcosmo.ai`,
a separate member-facing surface with its own workspaces, and a key minted on
one surface fails as a `401` on the other.

An app that picks its backend at launch (a GUI app has no inherited
environment) publishes the choice with `setenv` before starting a session.
One process, one backend.

`verifyTLS` defaults to `.auto`, which skips verification only for loopback
hosts so a self-signed local-dev backend works; remote hosts are always
verified.

For the one-process local OSS server on macOS, select the WebSocket carrier:

```swift
let client = RealtimeClient(
    apiKey: "local-development",
    baseURL: URL(string: "http://localhost:8080")!,
    transport: .websocket
)
```

It carries PCM audio, session events and ordinary client-tool RPC on one
socket, using the same `AVAudioPCMBuffer` and event APIs. It has no
reconnection, camera, screen share, byte streams, background client tools,
dial or usage reads. Other Apple platforms reject `.websocket` at start.

### Agents

`client.agent(...)` builds an inline persona — what the agent *is*,
independent of any one run. Every parameter is optional; unset fields stay
off the wire and the server applies neutral defaults. It throws on duplicate
skill names, when the agent is built rather than mid-call.

| Parameter | Meaning |
|---|---|
| `instructions` | System instructions |
| `model` | What runs on the other end: `.id("…")` for a model id or provider alias, or a provider case (`.gemini`, `.openai`, `.openaiMini`, `.grok`) carrying that provider's knobs and an optional `modelId:`, so a model that disagrees with its knobs is unrepresentable |
| `voice` | How the agent sounds: `VoiceConfig(name:speakingStyle:)` — prebuilt voice id plus delivery guidance |
| `audio` | The audio pipeline: `AudioConfig(output:noiseCancellation:)`. `noiseCancellation` is off by default; `.voiceFocus` removes background voices but keeps only the primary speaker, and `.denoise` strips noise while keeping every voice (the mode for a shared microphone). A phone leg gets a lighter noise suppressor whatever the mode, and does not single out competing voices |
| `tools` | Client-executed specs this app fulfills, and typed zero-config server-tool opt-ins (`.webSearchTool()`, `.examineImageTool()`, `.detectObjectsTool()`, `.pointAtObjectTool()`) |
| `interruptionSensitivity` | How readily the user's speech interrupts the agent (`.default` / `.low` / `.high`) |
| `greeting` | Opening line the assistant speaks first, voiced server-side as soon as the model session opens — before the client even receives `ready` |
| `skills` | Agent Skills folded into the persona — see [Skills](#skills) |
| `mcp` | MCP servers whose tools join the set at start — see [MCP servers](#mcp-servers-local-stdio) |
| `hooks` | Lifecycle observers and policy gates — see [Hooks](#hooks) |

There is no `language:` parameter here or anywhere else in the SDK: the
native-audio models these sessions run on pick their working language from
the audio itself, and no provider setting pins it. Write the rule into
`instructions` — managed sessions compose default language-stability
guidance that defers to instruction-level rules, so a pinned agent keeps
its pin. Steering, not a guarantee: drift shows first as wrong-language
transcript lines, confirmed when the agent's own replies follow — a
wrong-language user line alone can be the separate speech-to-text model
the OpenAI-family and Grok providers use for user transcripts, which
instructions never reach.

`client.catalogAgent(name, inputs:voice:tools:mcp:hooks:)` runs a workspace
catalog agent by handle instead. The stored config runs verbatim, so only
those per-run ride-alongs are accepted — the stored-config fields have no
parameter, which makes the illegal combination a compile error.

### Session runs

`agent.start(...)` opens one run. Its parameters are the values that differ
between two runs of the same persona, and all are optional:

| Parameter | Meaning |
|---|---|
| `resumeSessionId` | Resume a prior session (rides under the experimental knobs) |
| `maxSessionSeconds` | Requested wall-clock cap. The server takes the minimum of this and its own limit, and echoes the effective value on `ready` |
| `storeRecording` | Persist this run's recording artifacts server-side |
| `storeAudio` / `storeTranscript` / `storeVideo` | Persist one artifact class each; wins over `storeRecording` |
| `micMuted` | Join without publishing the microphone |
| `rpcHandlers` | Client-tool handlers registered by name but not advertised to the agent |

### Tools

`clientTool` is the tool API to reach for: you write a
`ToolSchema` and a `Decodable` args struct, and the SDK validates the
declaration at construction and decodes the arguments for you.

```swift
struct BookArgs: Decodable, Sendable {
    let table: String
    let partySize: Int
}

let bookTable = try AgentTool.clientTool(
    name: "book_table",
    description: "Reserve a table.",
    input: .object(
        properties: [
            "table": .string(description: "Table id"),
            "partySize": .integer(description: "Number of guests"),
        ],
        required: ["table", "partySize"]
    )
) { (args: BookArgs) in
    ["confirmation": .string(reserve(args.table, args.partySize))]
}
```

`input` and `Args` are written separately and nothing forces them to agree —
pin the pair with `ToolSchemaConsistencyCheck` in your unit tests. A schema
`default` is model guidance only: an omitted field decodes as `nil`, so fall
back in code (`args.unit ?? .c`).

`backgroundClientTool` is the same declaration and decoding for a long-running
tool: the handler drives a `ClientToolJob` (`ack` / `complete` / `fail`) so the
agent can keep talking while the work runs.

`.clientTool(name:description:parameters:handler:)` is the untyped escape hatch —
a hand-built JSON schema and a raw `[String: JSONValue]` handler. Use it only
when the schema is computed at runtime. A spec without a handler is still
declared to the agent but only surfaces its invocation as a `.toolInvocation`
observability event.

Handlers are local-only — never serialized, never on the wire.

### Event stream

`session.events` is a single-consumer `AsyncThrowingStream` of
`RealtimeSessionEvent` — one case per server event (`ready`, `transcript`,
`modelText`, `turnComplete`, speech/LLM/TTS phases, the tool lifecycle,
`reconnecting`, `error`, `pong`) plus:

- `.unknown(rawType:payload:)` — any unrecognized or undecodable frame.
  Forward compatibility is explicit: decode failure is **never** terminal.
- `.sessionEnded(_)` — always the final element; the stream finishes after
  it. The transport close is the terminal signal, so this sentinel is
  synthesized locally on `end()`, teardown, or a transport drop. The server
  publishes a best-effort `session-ended` wire frame before a deliberate
  teardown; the SDK latches its reason onto the sentinel rather than
  surfacing the frame mid-stream. Start failures throw from `agent.start(...)`
  instead, as a `SessionStartError` whose `code` names the failure (for
  example, `.versionMismatch`).

Oversized server messages arrive chunked (`server-envelope-chunk`) and are
reassembled transparently before they surface as events.

`session.states` separately reports the transport lifecycle (`idle`,
`connecting`, `connected`, `reconnecting`/`reconnected`,
`disconnected(reason:)`).

#### The transcript is session-owned

The session folds `.transcript` deltas into coalesced turns for you.
`session.transcript` is the conversation so far — one `TranscriptItem` per
turn (`id`, `role`, `text`, `isFinal`) — and a `.transcriptUpdated` event
carrying the complete updated list is yielded on `session.events` after
every change, like Python's session iterator:

```swift
for try await event in session.events {
    if case .transcriptUpdated(let update) = event {
        render(update.items)   // one bubble per item — that's the whole algorithm
    }
}
```

`TranscriptItem` is `Identifiable`, so SwiftUI renders it directly:

```swift
List(items) { item in
    Text("[\(item.role)] \(item.text)")
}
```

An item with `isFinal == false` is still in progress: its text may grow, be
replaced by the closing final (transcription can correct earlier words), or
the item may be removed (a retracted turn). Once `isFinal == true` it never
changes again — and `session.transcript` survives `end()`, so the full
conversation stays readable after the run.

The raw `.transcript` deltas stay on `session.events` for pipelines that
want the firehose: a non-final `text` is the new fragment since the previous
event for that role's turn, and the final carries the turn's cumulative
text, superseding the accumulation. `isFinal == true` means "this turn's
transcription is complete", not "the assistant turn is over" — audio can
still be playing out; `.turnComplete` signals the turn boundary.

### Sends

```swift
try await session.send(text: "Hello")
try await session.setMuted(true)
try await session.ping()
await session.end()             // graceful: wire end frame, then teardown
await session.waitUntilEnded()  // returns once the session is over
```

Sent text lands in `session.transcript` as its own closed user turn (an
in-progress speech transcription is untouched); pass
`send(text:, transcript: false)` to keep it out.

Client tools aren't sent here — declare a handler on the tool spec and the
SDK runs it over the transport when the agent invokes it.

For audio the SDK can't capture itself — a synthetic generator, file replay,
or a host with no usable microphone — publish it yourself:

```swift
try await session.startAudioStream()
audio.push(pcmBuffer)               // from your render callback
await session.stopAudioStream()
```

While the stream is live the device microphone is silenced, so the agent hears
exactly the buffers you push; removing it restores the microphone.

`waitUntilEnded()` returns once the session has ended for any reason (`end()`,
a server-side stop, or a transport drop). It's the supported way to keep a
CLI alive for the length of a call; it doesn't consume `events`, so you can
drain the stream from another task and await this one on the main path.

### Readiness vs liveness

`start` already returns at ready, so there is nothing to gate on: a session you
hold is usable. `.ready` still arrives on `events`, and it remains the only
signal carrying the session id, the rejected-tool list, and the effective
duration cap — read it for those, not to decide when to begin.

`await session.waitUntilAgentLive()` is a separate, weaker signal: it returns
once the agent participant publishes a track, which is LiveKit's transport-level
proof that somebody is on the other end. It carries no session metadata. Use it
to drive a spinner without gating that spinner on a data frame, and as a
backstop if you want to distinguish "the agent never showed up" from "the agent
is here but I have no metadata yet". It also returns if the session ends first,
so it never outlives the session.

## Hooks

Attach lifecycle observers and policy gates to any agent by putting `Hook`
values on its `hooks`. Four events fire: **SessionStart** (before the
wire frame is sent), **PreToolUse** (before a client tool runs), **PostToolUse**
(after), and **SessionEnd** (once, on any exit path). SessionStart and
PreToolUse carry honored overrides: return `SessionStartResult(additionalContext:)`
to inject additional instructions, or `PreToolUseResult(permission: .deny, reason:)`
to block a client tool before it executes. A throwing hook is logged and
skipped; sibling hooks still run. Hooks are local-only — closures are never
serialized or sent on the wire.

```swift
let agent = try client.agent(hooks: [
    sessionStart { _ in
        SessionStartResult(additionalContext: "The user is on the premium plan.")
    },
    // Block any client tool whose name matches the "delete_*" glob.
    try preToolUse(matcher: "delete_*") { _ in
        PreToolUseResult(permission: .deny, reason: "destructive tools are disabled")
    },
    try postToolUse { ctx in print(ctx.toolName, ctx.outcome) },
    sessionEnd { ctx in print("session stopped:", ctx.reason ?? "unknown") },
])

let session = try await agent.start()
```

`preToolUse` and `postToolUse` take an optional glob matcher on the tool name
and **throw** — a malformed matcher is rejected there, not at session start.
`sessionStart` and `sessionEnd` take no matcher and don't throw.

A fired server-hook silence timeout (a `Hook.server(SilenceTimeout(...))` entry
in the same list) reaches you as a `.userSpeechTimeout` event on the session's
event stream, not as a hook — the server executes it even if this process dies
mid-call.

### Live e2e (`HooksExample`)

`HelloRealtime/Sources/HooksExample` in the [examples repo](https://github.com/socratic-ai/cosmo-ai/tree/main/examples/swift) is a self-contained runnable
harness that exercises all four hooks in one headless session: SessionStart
(inject caller context), PreToolUse/deny (block `delete_account` before it
runs), PreToolUse/rewrite (force `account=primary` on `get_account_balance`),
PostToolUse (observe outcome), and SessionEnd (observe exit reason).

```bash
git clone https://github.com/socratic-ai/cosmo-ai && cd cosmo-ai/examples/swift/HelloRealtime
COSMO_API_KEY=cosmo_… swift run HooksExample
```

Each `◆ HOOK` line in the output proves the corresponding hook fired. The
`▶ handler delete_account` line must not appear — the PreToolUse/deny hook
suppresses it before the handler is invoked.

## Skills

Attach **Agent Skills** (the `SKILL.md` standard) to the model through the
agent. Parsed skills become a single resident `cosmo_sdk_load_skill`
tool plus a hot-set menu appended to the agent's instructions; the model
calls `cosmo_sdk_load_skill(name)` when the conversation reaches a skill's path
and receives the body as private, never-spoken instructions for the rest of the
call.

```swift
let client = RealtimeClient(token: jwt)
let skills = [try parseSkillMd(refundsMarkdown, defaultName: "refunds")]
let agent = try client.agent(
    instructions: "You are a terse support agent.",
    skills: skills
)
let session = try await agent.start()
// the menu is now resident; the model can call cosmo_sdk_load_skill("refunds")
await session.end()
```

`client.agent(...)` **throws**: duplicate skill names are rejected when the agent is
built, not mid-call. The agent composes skills, MCP, and caller tools together —
all land in the session's tool set. Every attached skill rides resident as
`name` + `description`; only the body is deferred to `cosmo_sdk_load_skill`. Unknown
`SKILL.md` frontmatter keys (`tier`, `allowed-tools`, `license`, …) are
accepted and ignored, so documents authored for other harnesses stay valid.

`HelloRealtime/Sources/SkillsExample` in the examples repo is a runnable version.

## MCP servers (local stdio)

Expose a local [MCP](https://modelcontextprotocol.io) server's tools to the
realtime model through the agent. Declare servers in a Claude-Code
`.mcp.json`; the SDK spawns each, lists its tools, and proxies calls — tools are
namespaced `mcp__<server>__<tool>` and ride in the session's tool set as ordinary
client tools.

```swift
let client = RealtimeClient(token: jwt)
let agent = try client.agent(mcp: .configFile(url))
let session = try await agent.start()
// drive session.events … ; then:
await session.end()
```

`.configFile(_:)` reads one `.mcp.json`; inline servers are ordinary array
elements, and the two compose:

```swift
let agent = try client.agent(mcp: [
    McpStdioServer(name: "fs", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
])
let agent = try client.agent(mcp: .configFile(url) + [inlineServer])
```

A path that is not a file, a malformed document, and duplicate server names
throw `McpError` when the agent is built, not mid-call; a connection or tool
failure throws the same type mid-call. `code` names which failure it was —
match on it rather than on the message:

```swift
do {
    let agent = try client.agent(mcp: .configFile(url))
} catch let error as McpError where error.code == .missingCommand {
    // …
}
```

The codes are `not_a_file`, `cannot_read`, `invalid_json`, `missing_servers`,
`invalid_server_entry`, `missing_command`, `invalid_args`, `invalid_env`,
`invalid_cwd`, `duplicate_server_name`, `connection_failed`,
`invalid_response`, `server_error` and `tool_error`.

A server that fails to launch, initialize, or list its tools is skipped with a
warning rather than thrown — the session starts without its tools, so one bad
entry in a shared config doesn't take the call down. Failures reach you once a
server is connected.

v1 supports **stdio** servers (macOS — subprocess); remote (`url`) entries in
`.mcp.json` are skipped with a warning. An `McpStdioServer` runs an arbitrary local
command — trust your config. No third-party dependency is added.

`HelloRealtime/Sources/MCPExample` in the examples repo is a runnable version.

## Authentication

Workspace-scoped API key with the `realtime:start` scope, passed as:

```
Authorization: Bearer cosmo_<key>
```

The key is injected automatically via `RealtimeClient(apiKey:)`. For
anything you distribute, mint a per-user token instead and construct with
`RealtimeClient(token:)`.

`client.verify()` checks the credential without starting a
session — free, no room, no agent. It returns the workspace it's bound to, its
scopes, whether it carries `realtime:start` (`canStartSessions`), and whether the
deployment has the default voice stack configured (`realtimeVoiceAvailable`).
`workspace` is nil
for a minted token — it runs on an end user's device, which isn't told whose
workspace it belongs to. Only a credential the server rejects throws
(`VerifyError`); an under-scoped one comes back as a result.

`session.usage()` fetches the session's usage summary over REST — duration,
talk time, and token counts in provider-reported units — during the session or
after it ends. `usageStatus` reports whether the detailed summary is there:
`.pending` while it may still land, `.recorded` once the numbers are final,
`.unavailable` when none was written and none will be. `tokens` is nil when
the provider doesn't report token usage. Throws `UsageError`.
`client.sessionUsage(sessionId:)` is the client-level form.

## Architecture

```
RealtimeClient (struct)                  — credential, endpoints, agent factories
 └── RealtimeAgent (struct)              — the persona; reused across runs
      └── RealtimeSession (actor)        — one run: the public stream API
           ├── events / states           — AsyncThrowingStream / AsyncStream
           ├── EnvelopeReassembler       — server-envelope-chunk reassembly
           └── SessionTransport          — protocol-agnostic transport seam
                └── LiveKitSessionTransport         — production implementation
                     ├── CosmoRealtimeAPI.Client    — POST /api/v1/external/realtime/session/start
                     └── Room (LiveKit)             — WebRTC audio + data channel
```

`CosmoRealtime` declares every wire type it publishes, under the cross-SDK
names (`ReadyEvent`, `TranscriptDeltaEvent`, …), so `import CosmoRealtime`
is the only import a consumer needs. The internal `CosmoRealtimeAPI` module
holds the client generated from the OpenAPI spec at
`Sources/CosmoRealtimeAPI/openapi.json`; it is not a product and nothing
public points into it.

## Logging

The SDK logs through `os_log` under the `socratic.cosmo-realtime` subsystem,
so one predicate captures a whole session:

```bash
log stream --predicate 'subsystem == "socratic.cosmo-realtime"' --info --debug
```

That predicate is the way to read a session in full. `os_log` levels are set
outside the process, though, so a command-line run gets a second, narrower
sink: set `COSMO_LOG_LEVEL` to `silent`, `error`, `warn`, `info`, or `debug`
and the SDK writes its traced lines to standard error at that level.

```bash
COSMO_LOG_LEVEL=debug swift run
```

Today that means one line per session with the connect-latency breakdown.
Unlike the Python and TypeScript SDKs, where the same variable turns the
whole SDK verbose, everything else here stays on `os_log`.

For LiveKit's own internals, set `COSMO_REALTIME_LIVEKIT_LOG` and capture the
`io.livekit.sdk` subsystem alongside ours.

## Example

See [`HelloRealtime/`](https://github.com/socratic-ai/cosmo-ai/tree/main/examples/swift/HelloRealtime) in the examples repo for a runnable macOS
command-line program that connects, declares a typed client tool, listens for
transcripts, sends a text message, and disconnects — no audio required.

```bash
git clone https://github.com/socratic-ai/cosmo-ai && cd cosmo-ai/examples/swift/HelloRealtime
COSMO_API_KEY=cosmo_… swift run
```

`BackgroundToolExample`, `HooksExample`, `SkillsExample`, and `MCPExample` live
alongside it as `swift run <target>` programs.

[`Cartographer/`](https://github.com/socratic-ai/cosmo-ai/tree/main/examples/swift/Cartographer) is the GUI counterpart: a
SwiftUI macOS app that draws a live mind map from what you say, with client
tools mutating on-screen state and hooks enforcing an app-side limit. Its
`bundle.sh` is also the reference for packaging a SwiftPM-built `.app` that can
actually reach the microphone.

```bash
git clone https://github.com/socratic-ai/cosmo-ai && cd cosmo-ai/examples/swift/Cartographer
COSMO_API_KEY=cosmo_… ./run.sh --demo
```

## Testing

The SDK ships two test targets:

- **`CosmoRealtimeTests`** — unit tests exercising `RealtimeSession` over an
  in-memory fake transport. No network, no LiveKit server. Runs on every
  `swift test`.
- **`CosmoRealtimeE2ETests`** — exercises the full connect / send / receive /
  disconnect cycle against a real `livekit-server` in dev mode. **Skipped
  unless `LIVEKIT_TESTING_URL` is set.**

```bash
swift test                       # only the unit suite — fast, offline
```

To include the E2E suite, start a local `livekit-server` in dev mode and point
the env vars at it:

```bash
LIVEKIT_TESTING_URL=ws://localhost:7880 \
  LIVEKIT_TESTING_API_KEY=devkey \
  LIVEKIT_TESTING_API_SECRET=devsecretdevsecretdevsecretdevse \
  swift test
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE). Copyright 2026
Socratic AI, Inc.

## Export Control

This distribution includes cryptographic software. The country in which you
currently reside may have restrictions on the import, possession, use, and/or
re-export to another country of encryption software. Before using any encryption
software, check your country's laws, regulations, and policies concerning the
import, possession, use, and re-export of encryption software.

The Cosmo SDK is published by Socratic AI, Inc. as publicly available source
code. It uses standard TLS/HTTPS and WebRTC (DTLS-SRTP) for transport security
and does not implement proprietary cryptographic algorithms. By downloading or
using this software you represent that you are not located in, or a national or
resident of, any country subject to U.S. embargo or comprehensive sanctions, and
that you are not on any U.S. government restricted-party list.
