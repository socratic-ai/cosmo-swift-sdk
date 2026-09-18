# Changelog — `CosmoAI`

All notable changes to this package. Dates are release dates. Versions are
per-SDK: the other Cosmo Realtime SDKs release on their own numbers.

Entries are assembled from the monorepo's pending changeset fragments when a
release is cut. A published section is immutable — a correction goes in the
next release's section, never by editing an old one.

> The v0.1.0 entries describe the API as it shipped in that release.
> Several names changed after — read the reference docs for the current
> shape, and v0.1.0 only as history.

## v0.8.0 — 2026-09-18

### Breaking

[Upgrade guide](https://platform.askcosmo.ai/docs/meta/migration/swift/0-8)

- `audio.noiseCancellation` takes a mode instead of a boolean — `'off'`, `'denoise'` or `'voice_focus'`. The new one is `'denoise'`: it removes non-speech noise and keeps every voice, which is what a microphone several people share needs. `'voice_focus'` is the previous behaviour, and keeps only the speaker it judges primary — on a shared microphone that treats the second person as background and filters them out.

  `true` and `false` remain valid on the wire, so a session started by an already-published SDK version is unaffected.
- Tools are built by calling a constructor on `AgentTool`, and every constructor returns `AgentTool`, so a `tools:` literal reads `[.webSearchTool(), .drawBoxTool(onDraw:)]`. The enum cases are internal: `.webSearch`, `.examineImage`, `.detectObjects`, `.pointAtObject`, `.client(...)`, `.backgroundClient(...)` and `.screenLocate(...)` are replaced by `webSearchTool()`, `examineImageTool()`, `detectObjectsTool()`, `pointAtObjectTool()`, `clientTool(...)`, `backgroundClientTool(...)` and `screenLocateTool(capture:)`. `AgentTool.define` / `defineBackground` are renamed `clientTool` / `backgroundClientTool`, each overloading on a `ToolSchema` or raw `parameters`. `AgentTool` is now a struct; `name` and `clientToolHandler` stay readable on the built value.
- The session-event types move to the top level under the cross-SDK names — the same symbols Python and TypeScript publish, with the `Event` postfix the event union's members carry everywhere else. `RealtimeSession.Event` → `RealtimeSessionEvent`, and the payload typealiases follow: `RealtimeSession.Ready` → `ReadyEvent`, `.TranscriptDelta` → `TranscriptDeltaEvent`, `.ModelText` → `ModelTextEvent`, `.TurnComplete` → `TurnCompleteEvent`, `.ToolCall` → `ToolCallEvent`, `.ToolDispatchStarted` → `ToolDispatchStartedEvent`, `.ToolResult` → `ToolResultEvent`, `.ToolInvocation` → `ToolInvocationEvent`, `.Reconnecting` → `ReconnectingEvent`, `.UserSpeechTimeout` → `UserSpeechTimeoutEvent`, `.SessionEnded` → `SessionEndedEvent`, `.ErrorEvent` → `ErrorEvent`, `.ErrorCode` → `ErrorCode`, `.RejectedTool` → `RejectedTool`, `.ResolvedAgent` → `ResolvedAgent`. Case names and field shapes are unchanged — only the type spellings move.
- Passing a workspace API key (`cosmo_…`) as `token` is refused at construction in every SDK. That parameter takes a minted end-user token; a key there authenticates anyway, so the mistake used to work — and shipped the key with whatever app carried it. Pass the key as the API-key parameter, or mint a token for the user with `mintToken` and pass that. Acts-as-user tokens (`cosmo_pat_…`) are unaffected.
- The `.cosmo(CosmoEvent)` wrapper case is gone: wire `cosmo.usage` now surfaces directly as `.usage(UsageEvent)` (`RealtimeSession.CosmoUsage` → `UsageEvent`), matching the event's place in the Python and TypeScript unions. `if case .cosmo(.usage(let u))` becomes `if case .usage(let u)`.
- `ToolInvocationEvent.args` is now a plain `[String: JSONValue]` (empty when the wire omits it), replacing the generator's opaque `ArgsPayload` container — read arguments directly instead of digging through `additionalProperties`. `origin` is a `ToolInvocationOrigin` enum (`.realtime` / `.server`), keeping the wire's closed set exhaustively switchable.
- `ToolOutcome`'s payloads are labeled: `case ok(result:)`, `case error(message:)`, `case denied(reason:)`. The declaration now names what each case carries, matching the field names Python and TypeScript already publish. Reading one is unaffected — `case .ok(let result)` reads the same — but constructing one positionally is not: `ToolOutcome.error(text)` becomes `ToolOutcome.error(message: text)`. `PostToolUseContext.init` is public and takes an outcome, so a hook's own unit tests construct these and need the labels.
- `RealtimeClient.Transport.webrtc` is the canonical/default room transport case, replacing the vendor-named `.livekit`. The deprecated `.livekit` alias still connects through WebRTC, but exhaustive switches must add `.webrtc`.
- A client tool carries the handler that runs it: `AgentTool.clientTool(name:description:parameters:handler:)` no longer defaults `handler` to `nil`, and neither does the `.client` case. Declaring a tool this client cannot execute advertised one that failed on every invocation, which the transport layer already said it would. A tool the server invokes over RPC without ever listing it to the agent is unchanged and unaffected — that is `RealtimeAgent.start(…rpcHandlers:)`, the register-only complement, and it is now the only way to express it.
- `model_options` is gone; its provider block moves onto `model`,
  which now takes either the model string it always took or one provider block
  naming the provider once — a model that disagrees with its knobs is
  unrepresentable. The provider types drop the `Options` suffix
  (`GeminiModelOptions` → `GeminiModel`, and likewise for OpenAI, OpenAI-mini
  and Grok), each block's `turn_detection` accepts only the detectors its
  provider offers (Cosmo-VAD tuning moves to `CosmoVadConfig` on the block's
  `cosmoVad` field), and the `ModelOptions` enum becomes `RealtimeModel`, whose `.id("…")` case is the string form
  and whose block cases carry the provider's knobs. A block with no model id runs the provider's default,
  and `.id("gemini")` still selects a provider by name. The server keeps
  accepting `model_options` from existing releases — the old pair folds into
  `model` server-side — so upgrading the SDK is not coupled to a backend
  deploy.
- Client settings are the initializer's parameters, so `RealtimeClient.Options` is gone. `RealtimeClient(.init(apiKey: key))` becomes `RealtimeClient(apiKey: key)`, and the same for `token:` and `tokenSource:`; `try RealtimeClient()` is unchanged. Every parameter — `baseURL`, `connectTimeout`, `requestTimeout`, `verifyTLS` — keeps its name and default, one level up. `Options.Credential` goes with it: the four initializers cover the same three credential forms, so nothing is lost.
- `RealtimeClient.canMint` is removed. It reported whether a credential was an API key but gated nothing — `mintToken` always let the server rule on the credential, and it still does. A client that cannot mint raises `MintTokenError` with `code == .missingApiKey`, before the request goes out.
- The `CosmoRealtimeMint` product is removed and
  `mintToken(externalUserId:ttlSeconds:)` now ships in `CosmoRealtime`. Drop
  the product from your `Package.swift` dependencies and delete
  `import CosmoRealtimeMint`; the method is on the same `RealtimeClient` and
  its signature is unchanged. Minting still requires an api-key credential —
  a client holding a minted token or a `TokenSource` raises `MintTokenError`
  with `code == .missingApiKey` before any request goes out — and it matches
  how the Python and TypeScript SDKs expose the same call.
- `RealtimeError` is now a protocol every error in the SDK conforms to, so `catch let error as RealtimeError` catches them as one family — matching `except RealtimeError` in Python and `instanceof RealtimeError` in TypeScript. It replaces the enum of the same name, whose cases were unreachable: `.connectTimeout` was converted internally before any caller saw it, and `.sessionStartFailed`, `.notConnected`, `.alreadyConnected`, `.screenShareUnavailable` and `.invalidWirePayload` were never thrown at all. Catch the equivalent SDK error instead — `SessionStartError` for a failed start, `SessionStateError` for a call the session cannot serve.

  Changed: Failures that used to surface as raw LiveKit or Foundation errors now arrive as SDK errors, so the catch above covers them. A failed data publish, byte stream, or microphone toggle raises `SessionStartError` coded `transport`; unreadable or non-JSON `.mcp.json` raises `McpError`; and a `SKILL.md` that cannot be read or decoded, or a skills directory that cannot be listed, raises `SkillError` — matching what the Python SDK already did. Code matching on the underlying framework error types needs to read the SDK error instead.
- `SkillParseError` is now `SkillError` and carries a `code` naming which failure it was, so a caller can tell them apart without reading the message. The codes are `not_a_directory`, `cannot_read`, `missing_frontmatter`, `unterminated_frontmatter`, `malformed_frontmatter_line`, `duplicate_frontmatter_key`, `missing_description` and `duplicate_skill_name` — a `SkillErrorCode` enum in Python and Swift, a union of the same values in TypeScript. The old name described only the five parsing failures, while the type has always also covered a bad path and a duplicate skill name. Match on `err.code`; `err.message` is the sentence alone, and an unreadable skills directory now raises `SkillError(cannot_read)` where it used to escape as a bare `PermissionError`.

  Breaking: Attaching skills reads the same in every SDK. Swift takes a directory through the `skills:` argument itself — `client.agent(skills: .directory(skillsURL))` — instead of `loadSkills(fromDirectory:)`, which is no longer public; `.directory(_:)` is a factory on `[Skill]`, so inline skills are unchanged and the two compose with `+`. Swift's `skills` is optional rather than defaulting to an empty array. `parseSkillMd` takes `defaultName` directly in TypeScript rather than wrapped in an options object, and `parse_skill_md` is now public in Python for SKILL.md text you already hold. The skill-assembly internals — `resolveSkills`, `skillsMenuText`, `buildLoadSkillTool`, `LoadSkillWiring`, `loadSkillToolName`, `UnknownSkillError` — are no longer public in Swift; the wire name the tool registers under is unchanged, so a hook matching `cosmo_sdk_load_skill` keeps working.
- Every MCP failure now raises `McpError`, carrying a `code` naming which one it was, so a caller can tell them apart without reading the message. The codes are `not_a_file`, `cannot_read`, `invalid_json`, `missing_servers`, `invalid_server_entry`, `missing_command`, `invalid_args`, `invalid_env`, `invalid_cwd`, `duplicate_server_name`, `connection_failed`, `invalid_response`, `server_error` and `tool_error`, — an `McpErrorCode` enum. It replaces `MCPConfigError` and `MCPError`, and covers connection and tool-call failures as
  well as config, so one `catch let error as McpError` spans the whole concept. Match on `error.code`; the message is the sentence alone. `McpError` is no longer a `ValueError` — a dead subprocess is no ValueError. Two classes fold into codes: `McpToolError`, a bare `RuntimeError` outside the error family, becomes `tool_error`, and `McpExtraNotInstalledError` becomes `extra_not_installed`. The second is breaking for anyone catching `ImportError` or `ExtraNotInstalledError` around a missing `[mcp]` install — catch `McpError` and match the code instead. `ExtraNotInstalledError` is removed with it: MCP was the only extra that raised it, so it was a base class for a family of none.

  Breaking: Attaching MCP servers reads the same in both SDKs. Swift takes servers through the `mcp:` argument itself — `client.agent(mcp: .configFile(configURL))` — instead of `McpRegistry`, which is no longer public; `.configFile(_:)` is a factory on `[McpStdioServer]`, so inline servers are unchanged and the two compose with `+`. `catalogAgent` now throws, since duplicate server names are rejected when the agent is built rather than mid-call. The MCP internals — `McpRegistry`, `ConnectedMcp`, `SkippedTool`, `MCPToolInfo`, `MCPCallResult`, `MCPTransport`, `MCPTransportFactory`, `defaultMCPTransportFactory` and `parseMcpConfig` — are no longer public in Swift.

  Fixed: Swift now rejects malformed `.mcp.json` fields it previously accepted in silence. `args` that is not an array, or holds a boolean or an object, raises `invalid_args` instead of being coerced through string conversion — a `true` became the argument `"1"`. An `env` that is not an object of strings raises `invalid_env` rather than being dropped, which had launched the server without the variables it was configured with; a non-string `cwd` raises `invalid_cwd` on the same footing. Duplicate server names are now rejected in Swift as they already were in Python. In Python, an unreadable config file raises `McpError(cannot_read)` where it used to escape as a bare `PermissionError`, an invalid document is `invalid_json` rather than sharing one message with an unreadable one, and `"args": null` means absent, as it already did for `env` and `cwd`. Both SDKs run the same `mcp-config-vectors.json` conformance file.

  Fixed: The runtime codes now say what actually failed. A dead subprocess reports `connection_failed` in Python where it used to report `server_error`, and a reply the SDK cannot decode reports `invalid_response`, which nothing raised before — the three are read from the exception the `mcp` package raises rather than collapsed into one. In Swift, a well-formed `.mcp.json` whose root is not an object reports `missing_servers` instead of claiming the text is not valid JSON, and a config inside a directory the process cannot traverse reports `cannot_read` instead of `not_a_file` — `fileExists` answers false for a permission wall exactly as it does for an absent file, so the read classifies it now.

  Breaking: A number in `args` is accepted only when it is whole and fits in a signed 64-bit integer, and is written in decimal. `1.0` and `1` are indistinguishable once decoded and a larger integer reached the process in scientific notation, so neither had a spelling both SDKs agreed on; quote the value instead. Both SDKs also walk a document's entries in name order now, which fixes the order servers are attached in and which malformed entry is reported when more than one is bad — Python previously followed document order.

  Fixed: A `.mcp.json` whose bytes are not UTF-8 now raises `McpError` coded `cannot_read` in both SDKs. Python raised a bare `UnicodeDecodeError`, which is a `ValueError` rather than an `OSError` and so escaped the error family entirely; Swift reported `not_a_file` about a file that is there.
- `MintTokenError.code` is now a closed `MintTokenErrorCode` naming what the SDK saw — `request_failed`, `invalid_response`, `request_rejected` or `missing_api_key` — and the server's own rejection slug moves to `serverCode`, set only when the code is `request_rejected`. The two were previously the same field, so `code` could hold either the SDK's category or anything the server sent, down to a synthetic `http_<status>`, with no way to tell which. Match on `err.code` for what happened to the request and read `err.serverCode` for why the server refused. Handlers comparing `code` against `"transport_error"` or against a server slug such as `"auth_failed"` need updating; `str(err)` is now the message alone, without the `code: ` prefix.

  Breaking: A `TokenSource` that cannot produce a token now raises `TokenSourceError` rather than `MintTokenError`, with its own `TokenSourceErrorCode` — `request_failed`, `request_rejected`, `invalid_response` or `fetcher_failed`. Resolving a token source is not part of `mintToken`: it happens beneath every authenticated call — `verify`, `mintToken`, session start, dial and usage reads all resolve it first, and it re-resolves on expiry and after a 401 — so the failure surfaced under the name of one operation it mostly had nothing to do with. `token_source_failed` is gone from `MintTokenErrorCode` accordingly, and the four new codes say which part failed where one bucket said only that something did. A refused redirect is `request_failed` in every SDK — it never reached a token endpoint, so there is no rejection to report; Python previously reported it as an `http_<status>` rejection.

  Breaking: TypeScript gets the same two errors. `MintTokenErrorCode` and `TokenSourceErrorCode` are literal unions rather than aliases of `string`, both errors take `{ code, message, serverCode }`, and a malformed `TokenSource.endpoint` URL now throws a `TypeError` rather than an SDK error — argument validation is not part of the error family, which is what the Python SDK already did.

  Breaking: Swift gets the same two errors, as structs replacing the `MintTokenError` enum. `MintTokenError.rejected(code:detail:)`, `.transport(message:)` and `.invalidResponse(message:)` are gone; construct or match `MintTokenError(code:message:serverCode:)` with a `MintTokenErrorCode` instead, and expect `TokenSourceError` where a `TokenSource` fetch used to raise a mint error. `mintToken` now refuses a client built with a minted token or a token source before the request goes out, with code `missingApiKey`, rather than letting the server answer 401 — and `TokenSource.custom` rejects a fetcher returning an empty `jwt` instead of sending it as a bearer.
- `pushAudioBuffer(_:)` must be called from a capture queue rather than an audio render callback because transports may synchronously convert and copy the buffer. Caller-owned audio stream start and stop operations are now serialized, so a rapid stop cannot be overtaken by an older start.
- `mintToken` takes its subject unlabeled — `mintToken("user-123",
  ttlSeconds: 3600)` — matching Python and TypeScript, which pass the external
  user id positionally. The labeled `mintToken(externalUserId:)` spelling is
  removed; delete the label at each call site.
- `AmbienceConfig` and the agent's `audio.ambience` field are removed
  from every SDK,  The field never produced
  audible ambience on any session started through this API — it was accepted and
  validated, then dropped — so removing it changes no behavior. Delete `ambience`
  from your agent's `audio` block; the rest of the block is unchanged.
- The five backend calls share an `ApiError` base — `MintTokenError`,
  `TokenSourceError`, `VerifyError`, `UsageError` and `DialError` all descend
  from it, so one catch covers any of them while catching a specific one still
  says which call it was. `serverCode` moves to the base, because a rejection
  slug belongs to whichever backend answered rather than to the call that asked.

  `VerifyError`, `UsageError` and `DialError` gain closed code enums in place of
  a bare string: `request_failed`, `request_rejected`, `invalid_response`, plus
  `invalid_request` on dial and usage for a call the SDK refuses to make. Where a
  server slug was the `code`, it is now `serverCode` and `code` is
  `request_rejected`. Swift gains `DialError`, which it did not have, and its
  `UsageError` and `VerifyError` become structs carrying `code` rather than
  case-carrying enums.
- `AudioUnavailableError.code` is the closed `AudioUnavailableErrorCode`
  rather than a `String` — `micDenied`, `micNotFound`, `micInUse` and
  `audioUnavailable`, the same four values every SDK already reported. A `switch`
  over it is exhaustive. Comparisons against the slug no longer compile: match
  the case (`error.code == .micDenied`), and read `error.code.rawValue` where the
  string itself is wanted.
- Hooks no longer fire for the screen-capture RPC or for caller-registered RPC methods — hooks fire for tool calls, and wire plumbing is not one. A `PreToolUse` hook that matched `screen_capture` previously observed, denied, or rewrote captures on Swift only; Python and TypeScript already behaved this way, and all three SDKs now pin the contract.
- One `CredentialsError` with the closed `CredentialsErrorCode`
  replaces six spellings of the same failure — TypeScript's `CredentialError`
  (singular), Python's `CredentialsError` plus its `NotFound`, `File`, `Expired`
  and `Mismatch` subclasses, and Swift's case-carrying enum. The five resolution
  codes are the slugs the cross-SDK vectors already pinned; `conflicting_credentials`,
  `api_key_in_token_slot` and `insecure_base_url` cover the construction-time
  guards, which previously threw an untyped error. 
- Every error carries `message`, so `except RealtimeError as e` /
  `catch let e as RealtimeError` can read it without narrowing to a concrete
  type first. In Swift `message` is now a `RealtimeError` requirement, which a
  type conforming to the protocol outside the SDK must add. In Python
  `RealtimeError` and its argument-less subclasses — `NotConnectedError`,
  `VideoPublishAlreadyActiveError` — now take the message as their one
  positional argument. `str(error)` is unchanged, including the `"code: message"`
  form the session, dial, usage, verify and tool-schema errors render.
- Registering a hook that cannot work now throws `HookError` in every
  SDK, with the closed `HookErrorCode` — `malformed_matcher`, `invalid_hook`,
  `server_hook_not_allowed`. Python raised `ValueError` and `TypeError` and
  TypeScript a bare `Error` for these, so neither was catchable as
  `RealtimeError`; in Python it is exported from `cosmo_ai.hooks`, beside the
  hooks it describes; Swift's `MalformedHookMatcherError` is replaced. In Python
  `HookError` is a `ValueError`, so an `except ValueError` around hook
  declaration keeps firing; the two cases that raised `TypeError` no longer do.
- The screen-capture handler has one shape — it always receives the `ScreenCaptureRequest`. The zero-argument form is gone: in Python `screen_locate_tool`'s handler must accept the request (`lambda request: ...`; ignore it if unneeded), and in Swift the handler type is the top-level `ScreenCaptureHandler` — the request-taking signature (`{ request in ... }` or `{ _ in ... }`), matching the Python and TypeScript name — with the nested `ScreenLocateTool.Handler` and `RequestHandler` names removed. TypeScript already had this shape and is unchanged. Migrate deliberately: a zero-argument handler now fails at call time, and in Python the arity error's text would reach the model as the locator's spoken reason.
- `ScreenCaptureRequest` no longer carries `wantsElements`
  (`wants_elements` in Python); the request is an empty envelope, and in Swift
  its initializer is `init()`. Capture handlers should always collect elements —
  the server has always requested them, so nothing changes at runtime. A handler
  that read the flag can simply drop the check.
- Declaring `screen_locate` on the websocket transport now refuses at session start with `SessionStartError` (`code: "config"`, `server_code: "screen_locate_unsupported"`) — the locator's capture payload travels as a byte stream, a channel the single-socket carrier does not have. Previously TypeScript silently skipped registration and Python and Swift captured the screen and then failed to deliver it; now the capture handler never runs. The Python background-tools refusal gains the matching `server_code: "background_tools_unsupported"`.
- `ErrorCode`, `SessionStatus`, `UsageStatus` and `CredentialKind` now
  accept a value the server added after your package shipped, instead of failing
  the payload that carried it — previously an unrecognized error code cost the
  whole error event, and an unrecognized status failed the usage request along
  with the counters you asked for. Swift switches over these enums need a
  `default` or `@unknown default` now that they carry an `unknown(String)` case
  and are no longer `@frozen`; in Python both kinds are members of the enum, so
  use `value in list(TheEnum)` rather than `isinstance` to tell them apart.
  `TranscriptRole` is unchanged.
- `RealtimeSessionEvent` gains a case. The session now owns the
  coalesced transcript — read `session.transcript` (one `TranscriptItem` per
  turn, `Identifiable` by its stable `id`, with an `isFinal` flag) instead of
  folding the raw delta stream yourself, and the new
  `.transcriptUpdated(TranscriptUpdatedEvent)` is yielded on `session.events`
  with the complete updated list after every change, session-synthesized like
  `.sessionEnded`. A `switch` over the event union without a `default:` arm
  needs a new case (the forward-compatibility posture already calls for
  `default:` alongside `.unknown`). `send(text:)` now surfaces the sent text
  on the stream as its own closed user `.transcript` final (plus the update
  event) unless `transcript: false` is passed; an in-progress speech turn is
  unaffected. The raw `.transcript` delta events are otherwise unchanged.
- Every way a start can fail now raises one `SessionStartError`, whose
  closed `SessionStartErrorCode` names how far the attempt got — `transport`,
  `invalid_response`, `join_failed`, `config`, `busy`, `entitlement`,
  `version_mismatch`, `voice_disabled`, `rejected`, `handshake_failed`,
  `ready_timeout`. Switch on
  `code` where you used to branch on a type or read an HTTP status, and read the
  server's own rejection slug from `serverCode` beside it. It replaces the `RealtimeSessionError` enum. In Python
  the base error's `code` — previously open, carrying the server's own slug or
  a synthetic `http_<status>` — closes to the enum, with the slug moving to
  `serverCode`.
- `SessionStartError.detail` is a `SessionStartRejection` in every SDK —
  the server's structured reason for refusing a start, which no SDK carried in full before. Each group of fields belongs
  to one server code: `limit` / `active` for `concurrent_session_limit`,
  `granted_minutes` / `used_minutes` for `free_minutes_exhausted`,
  `balance_cents` / `top_up_path` for `insufficient_credits`, `meter` /
  `included` / `used` / `reset_at` for `quota_exceeded`, and `provider` /
  `allowed_providers` / `plan` / `upgrade_path` for `provider_not_entitled`. A
  field the server adds that the SDK does not name is kept rather than dropped.
  
- Calling a session method the session cannot serve now throws
  `SessionStateError` with the closed `SessionStateErrorCode` — `not_connected`,
  `already_started`, `audio_publish_already_active`,
  `video_publish_already_active`, `screen_share_unavailable`, `invalid_payload`.
  It replaces six cases of the session error enum. A send issued before `ready` and one issued after the
  session ended both report `not_connected`.
- `AgentTool.name`, `AgentTool.clientToolHandler`, and
  `AgentTool.sdkToolNamePrefix` are removed — an `AgentTool` is
  construction-only. Keep the name and handler you pass at construction; the
  SDK registers the handler from the declaration. The reserved `cosmo_sdk_`
  prefix is still enforced at session start, with no caller decision attached.
- Audio that will not open throws `AudioUnavailableError`, whose `code`
  names the failure, where the session's own error type was thrown before. A
  refused microphone takes this path — the default `start()` publishes the mic as
  it joins — and so does an audio engine that will not start: no usable input
  format, or a converter that will not build. It reaches you the same way on both
  carriers, from `start()` and from `setMuted`. It is its own type, so a catch
  written for a start failure no longer matches it — catch `RealtimeError` for
  both, or add a second catch. Swift names `mic_denied` where the platform
  reports a refused permission and `mic_not_found` where it reports no usable
  input; an audio fault it cannot attribute is `audio_unavailable` rather than a
  transport failure.
- The six turn-taking and reasoning enums — `InterruptionSensitivity`, `GrokReasoningEffort`, `ThinkingLevel`, `EndOfSpeechSensitivity`, `SemanticEagerness` and `TurnDetectionMode` — are declared by the SDK rather than aliased to its generated internals. Reading a case or a `rawValue` off one previously needed a second `import CosmoRealtimeAPI`, a module the package does not publish; importing `CosmoRealtime` alone is now enough. Case names and wire values are unchanged, so code that spells them by name compiles as before. Code that reached into the generated module — importing `CosmoRealtimeAPI`, or naming `Components.Schemas.InterruptionSensitivity` and its siblings explicitly — drops that import and uses the SDK's own type of the same name.
- The deprecated `String`-returning `dial(phoneNumber:callerNumber:)`
  overload is removed; `dial` returns `DialResult` only. Read the id from
  `result.dialId` — code that used the returned string gets the identical
  value from `result.dialId.uuidString.lowercased()`.
- `ErrorEvent.fatal` is a plain `Bool` instead of `Bool?`. A frame
  that omits the field decodes as `false`, matching the wire default and the
  other SDKs. Read it directly — remove any unwrapping, `?? false`, or
  `== true` around it.
- `ReadyEvent.rejectedTools` is a plain `[RejectedTool]` instead of
  `[RejectedTool]?`. The server always reports the list — empty means nothing
  was rejected — and a frame that omits the field decodes as `[]`, matching
  the other SDKs. Read it directly and drop any nil-handling or `?? []`.
- The screen tools' machinery leaves the public surface. The `cache:` overloads of `screenLocateTool`, `screenClickElementTool` and `screenHighlightElementTool` are removed, and `ScreenCaptureCache`, the `ScreenLocateTool` class and its `rpcMethod` / `byteStreamTopic` constants are internal — migrate by dropping the `cache:` argument; every screen tool shares the SDK's store automatically. `ScreenCapture.context` is now opaque and optional (`(any Sendable)?`, with `elements` and `context` defaulted in the initializer) and `ScreenCaptureContext` is removed — stash your own context type at capture time and cast it back in your click/highlight handler.
- Server-sent types — the session events, `CredentialInfo`,
  `SessionUsage`, `SessionTokenUsage` and `RealtimeSessionStartTimings` — no
  longer expose member-wise initializers. They are decoded, never
  constructed: build a test fixture by decoding the wire JSON the server
  would send (`JSONDecoder().decode(ReadyEvent.self, from: json)`), which
  also validates the fixture against the wire shape. Types you construct
  yourself — `SilenceTimeout`, `Say`, `EndCall` and all agent and session
  configuration — are unchanged.
- `RealtimeSessionEvent` gains a case —
  `.sessionEndingSoon(SessionEndingSoonEvent)`, the server's session-limit
  warning with `secondsRemaining` and a stable `reason` slug, previously
  surfaced through the unknown-event fallthrough. A `switch` over the event
  union without a `default:` arm needs the new case (the
  forward-compatibility posture already calls for `default:` alongside
  `.unknown`). The session keeps running until `.sessionEnded`.
- `agent.start(...)` now returns when the session is ready — the
  server's handshake has landed — instead of at transport join, so every
  session method works the moment it returns. A session whose ready
  handshake never arrives within 40 seconds is torn down and the start
  throws `SessionStartError` coded `readyTimeout`; a room that
  closes before ready throws it coded `handshakeFailed` with a synthetic
  status of `0`, carrying the server's boot-failure `error` frame code and
  message when one preceded the close, else `handshake_disconnect`. Cancelling the
  task that awaits a start tears the session down and throws
  `CancellationError`, so `Task.cancel()` and SwiftUI's `.task` teardown
  abort a start cleanly. Readiness is also read from the agent's
  `cosmo.ready` participant attribute — at join and after a reconnect — so a
  session that joins after the agent came up still observes it.
- Session state observation now matches the other Cosmo SDKs. Read
  the current value as `await session.state`, and pass an `onStateChange:`
  handler to `agent.start` to observe every transition from `.idle` on — the
  `session.states` stream is removed. The state vocabulary is the shared
  five-state machine: the distinct `.reconnected` case is gone (a completed
  recovery re-enters `.connected`), the type is named `SessionState`, and its
  terminal case is `.disconnected(reason:detail:)` carrying the same
  five-slug `DisconnectReason` the SessionEnd hook context uses, with the
  server's end slug or transport message in `detail`.
- The token counters on `UsageEvent` and `SessionTokenUsage` are
  plain `Int` instead of `Int?`. A payload that omits a counter decodes as
  `0`, matching the wire default and the other SDKs. Read them directly —
  remove any unwrapping, `?? 0`, or `== nil` around them. `SessionUsage.tokens`
  itself stays optional: a provider that reports no token usage still yields
  no breakdown.
- `ToolSchemaError` is now `ToolDefinitionError`, and it covers the
  whole declaration — a bad tool name and a missing or overlong description
  throw it too, where Python raised a bare `ValueError` and TypeScript a bare
  `Error`. Both are now catchable as `RealtimeError` like every other SDK error;
  in Python `ToolDefinitionError` is still a `ValueError`, so existing handling
  keeps working. `code` is the closed `ToolDefinitionErrorCode` rather than a
  string. Swift's `ToolDefinitionError` and `ToolSchemaConsistencyCheck.Failure`
  are folded into it, the latter as code `schema_type_mismatch`.
- A tool-call validation failure reports its issues as
  `ToolInputIssue` in every SDK — `path`, `code`, `constraint` — where Python
  had raw dictionaries keyed `loc`/`type`/`ctx`, Swift nested the type inside
  the error, and TypeScript carried `path` as an array of segments. `path` is
  now the dotted form (`address.city`, `items[2].sku`) everywhere, the same
  string the `INVALID_INPUT` message renders.

  TypeScript exports `ToolInputIssue` from `cosmo-ai/tool`: it is the type
  `ToolInputValidationError.issues` carries, so a caller reading them has to be
  able to name it.

### Added

- Three new knobs on the Grok model block — `reasoningEffort` (`"high"` | `"none"`; Grok's own default is `high`, which reasons for seconds before every reply — set `"none"` for conversational latency), `speed` (0.7–1.5 playback-rate multiplier for the agent's speech), and `idleTimeoutMs` (server re-engages the user after this much post-response silence, re-arming after every response). All three are optional; unset keeps Grok's defaults.
- `presentMultiplier` on a silence hook, deciding how much its `timeoutSeconds` widens once the caller has spoken at least once. It is optional and unset keeps the server's default, so existing hooks are unchanged; set `1` for a hook that should wait the same whether or not anyone has spoken yet.
- `transport: .websocket` on `RealtimeClient` runs macOS sessions against a local OSS `cosmo-server` without a media room. The carrier uses the existing `AVAudioPCMBuffer`, event and ordinary client-tool APIs; camera, screen share, reconnection, byte streams, background tools, dial and usage reads remain unavailable on this local lane.
- `COSMO_LOG_LEVEL` turns the SDK verbose without an app change. Set it to `silent`, `error`, `warn`, `info`, or `debug` and the SDK writes to standard error at that level, including a `debug` line with the connect-latency breakdown for each session. An explicit `setLogLevel()` call, or a handler the app attached itself, still wins. In Swift the variable gates only that connect line, since `os_log` levels are set outside the process.
- `OpenAILiveModel`, a new provider block for OpenAI's GPT Live full-duplex voice model (`provider: "openai_live"`). The model listens and speaks at once and decides itself when each turn starts and ends, so it carries no turn-detection knobs. It cannot call tools itself; it delegates tool calls and reasoning to a backend Responses model, and the block configures that model: `responsesModel`, `responsesInstructions` (defaults to the agent's own instructions), `reasoningEffort` (`OpenAILiveReasoningEffort`: `minimal` / `low` / `medium` / `high`), `verbosity` (`OpenAILiveVerbosity`), `toolChoice` (`OpenAILiveToolChoice`: `auto` / `required` / `none`), `parallelToolCalls`, `maxOutputTokens`, and `serviceTier` (`OpenAILiveServiceTier`: `auto` / `default` / `flex` / `priority`). Audio only: video and screen frames are ignored on it. The plain-string alias `"openai_live"` runs the provider default.
- `SessionConnectTimings` gains `readyMs` (`ready_ms` in Python), measured from the same instant as the session-start phase and unset until the agent reports ready. Once the agent is live the session reports its client-measured phases and the server's own start breakdown back to the session, so the whole connect waterfall is recorded against it; the report goes out once per session and never surfaces a failure to the caller. In TypeScript the new field is optional and `onConnectTimings` takes the connect origin as an optional second argument, so a custom `RealtimeTransport` written against the previous shape still type-checks.
- Websocket sessions now report connect timings. The TypeScript transport carries the server's session-start phase breakdown and the connect-start origin into the connect-timings report, and the Swift transport records the handshake start so `readyMs` is populated — making socket and WebRTC connect latency directly comparable.
- Echo cancellation on the websocket transport's microphone. Python runs the same software canceller as the WebRTC lane, with noise suppression and gain control off; Swift uses Apple's platform voice processing with gain control disabled. On speakers the agent no longer hears itself and self-interrupts.

  Fixed: the Swift websocket transport stops playback when the agent's turn ends, so speech you talked over no longer keeps playing after an interruption.
- GPT Live sessions can hand work off instead of calling tools. `OpenAILiveModel.delegation` picks who does it: `responses` (the default, the backend Responses model), `client` (your application), or `cosmo` (Cosmo's workspace agent on the server). Under `client` and `cosmo` the session emits a `delegationCreated` event with the user's request, and three new session methods answer it: `appendThinking` (background the model keeps to itself), `appendCommentary` (something to say now, in its own words) and `appendInstructions` (how to behave from here on), each taking an optional delegation id.
- A tool the server rejects at session start is now logged as a warning — one line per rejected entry, with the tool's name and the server's reason. The ready event's rejected-tools list is unchanged; the warning just makes the drop visible without subscribing to it.
- The package identity is readable at module scope. Python exports
  `SDK_NAME` and `SDK_VERSION` from `cosmo_ai`; Swift exposes `sdkName` and
  `sdkVersion` after `import CosmoRealtime`. These are the values the SDK sends
  on `session-config` and the `X-Cosmo-SDK` header, under the names TypeScript
  already exports.
- `AgentTool.endCallTool()` — grant the agent hang-up, matching
  `end_call_tool()` in Python and `endCallTool()` in TypeScript; every leg
  drops, and the spoken goodbye is allowed to finish first. `dial` now also
  returns `DialResult` — bind the result as one
  (`let result: DialResult = try await session.dial(...)`) and read
  `result.dialId`; the `String`-returning overload is deprecated and will be
  removed in a later release.

### Changed

- The wire contract tightens: `session-config` now requires the `sdk` identity block, and `send-image` requires `mime_type` and `stream_id`. Every SDK release already sends all three unconditionally, so SDK users are unaffected — the change closes the gap for direct REST callers, whose sessions were previously anonymous.
- The OpenAI providers (`openai`, `openai_mini`, `openai_live`) no longer need a per-workspace opt-in. Like every other provider, they are available whenever the server has an OpenAI API key configured. `openai_provider_available` on the provider-capabilities endpoint now reports that server-side configuration rather than a workspace flag.
- `setMuted(_:)` is serialized with the caller-audio stream operations, so a mute issued while `startAudioStream()` or `stopAudioStream()` is in flight can no longer be silently undone by that operation's own microphone restore.
- The mute re-assert after a reconnect now rides the same serialized audio-operation queue as `setMuted(_:)` and the stream operations, and re-reads the latest mute state before sending — a stale reconnect-time capture can no longer land after a newer mute frame and desync the server gate from the local microphone.
- `TokenSource.endpoint` gains a closure form of `headers`, resolved before
  every token fetch — for a rotating credential such as a fresh session cookie
  or bearer per request. The static-dictionary form is unchanged. This matches
  the callback form the Python and TypeScript SDKs already accept.
- On the websocket transport, video and screen-share calls now fail with the error code `video_unsupported` instead of silently doing nothing. Stopping or removing a publish that could never start remains a harmless no-op, and video stays available on the WebRTC transport.
- The screen-capture payload's descriptor clamps (role, title/label, value) now count Unicode scalars in every SDK — the same unit the reply shrinker uses — so a descriptor containing emoji or combining marks clamps to identical text regardless of which SDK the host ships. TypeScript previously counted UTF-16 units and Swift grapheme clusters; Python already counted scalars and is unchanged.
- The realtime protocol's per-field documentation now reaches the
  generated wire types, so hovering a field on `SessionStartTimings`, `ReadyEvent`
  and the other wire types shows what it means instead of just its type. The
  descriptions come from the published OpenAPI spec, which now carries 85 of them
  where it previously carried 20.
- Every field on the realtime wire types now carries documentation, so
  hovering any field on an event or message shows what it means and what its
  values imply — transcript delta semantics, tool-call correlation ids, the
  storage-consent fields, the envelope chunking fields, and the rest.
- The session, usage, timeline, transcript and auth response types now
  describe every field they return. `SessionUsage` and `SessionTokenUsage`
  explain each counter, the timeline explains what each latency span measures
  and which ones a given source populates, and the artifact listing says that a
  download URL expires. Previously these types arrived with their shapes and no
  prose.
- The screen locator's capture payload names its element list `elements` instead of `ax_elements`, matching the `ScreenCapture.elements` field it carries. Nothing changes in your code — capture handlers and `ScreenCapture` are untouched — and the Cosmo server accepts either spelling, so earlier SDK releases keep working.
- The seven realtime schemas that arrived with no prose now describe
  themselves. The four "stopped" session events — `bot-llm-stopped`,
  `bot-stopped-speaking`, `bot-tts-stopped` and `user-stopped-speaking` — say what
  they mean, where they fall relative to their "started" counterparts, and the
  distinctions that are easy to get wrong: `bot-stopped-speaking` is the last
  frame leaving the server rather than the moment the user stops hearing audio,
  and `bot-llm-stopped` means generation finished rather than the turn closing,
  which `turn-complete` marks. `InterruptionSensitivity`, the session status enum, and the
  mint-token request type also carry descriptions now.

  Fixed: `bot-tts-started` no longer says the gap to `bot-started-speaking`
  widens on a separate STT/LLM/TTS pipeline. The runtime publishes the pair
  together off one state change, so there was never a gap to observe.
- The SDK now declares the wire protocol it speaks instead of
  re-exporting types generated from the backend schema. Published type and
  member names are unchanged, and the only generated types still on the
  surface are the closed string unions `InterruptionSensitivity`,
  `EndOfSpeechSensitivity`, `SemanticEagerness`, `GrokReasoningEffort`,
  `ThinkingLevel` and `TurnDetectionMode`, whose members are the wire's
  values in every language. Regenerating the backend schema can no longer
  change a published type on its own, so a change to the protocol reaches
  you as a release rather than as a surprise on upgrade.
- Documentation: every public symbol in the Swift SDK now carries a doc
  comment — types, properties, methods, initializers, enum cases and type
  aliases — so hover, quick help and the generated documentation answer
  what a value means without reading the implementation. No behavior
  changes.

### Deprecated

- `RealtimeSession.sdkName` and `RealtimeSession.sdkVersion`. Both
  still resolve to the same values; read `sdkName` and `sdkVersion` at module
  scope instead.

### Fixed

- Minting a token now behaves the same in all three SDKs. A success
  response is accepted only when `jwt` is a non-empty string and `expires_at`
  an RFC 3339 timestamp — anything else raises `invalid_response` rather than
  returning a token that cannot be used — and a Swift expiry carrying
  fractional seconds now parses instead of failing to decode. Mint requests
  carry a 45-second deadline and refuse redirects, so the workspace API key
  cannot be re-sent to another origin.
- The first build in Xcode no longer fails with `Validate plug-in
  "OpenAPIGenerator" … must be enabled before it can be used`. The package's
  API client is now shipped already generated instead of being produced by a
  build plugin, so Xcode has no plugin to ask you to trust — and neither does
  Xcode Cloud, where there was no prompt to accept. Adding the package also
  resolves six fewer dependencies, since the code generator and its tree no
  longer come with it. The generated types are unchanged.
- The Gemini block's `turn_detection` documentation stated that leaving
  it unset runs `server_vad`. It doesn't — unset runs `cosmo_vad`, Cosmo's
  semantic turn detection, and the `server_vad` window knobs
  (`end_of_speech_sensitivity`, `silence_duration_ms`, `prefix_padding_ms`)
  are unread until `server_vad` is named explicitly. The doc-comments now
  state the real per-provider defaults: `cosmo_vad` on Gemini, `server_vad`
  on OpenAI and Grok (whose documentation was already correct). Behavior is
  unchanged — this corrects the description, not the detector.
- On the websocket transport, `waitUntilAgentLive()` now resolves on the server's `ready` frame instead of suspending until the session ends.

  Added: the websocket transport runs on iOS, where the SDK configures and activates the `AVAudioSession` for the call unless the app owns it through `setAutomaticAudioSessionManagement(enabled: false)`. It also accepts remote endpoints over `wss`; plain `ws` stays loopback-only.
- On the websocket transport, a clean server close (code 1000/1001, or an empty close frame) now ends the session as `server_ended` in TypeScript and Swift instead of reporting a transport error, and an abnormal close such as 1008 carries its numeric close code and reason in the error detail in all three SDKs.

  Fixed: the Python SDK caps a client-tool error at the wire's 512-character limit, so a long handler traceback no longer voids the reply and strands the tool call until its timeout.

  Changed: the Python `websocket` extra now requires `websockets>=14.1`, the release that exposes the close code and reason this reporting reads.

## v0.7.0 — 2026-08-19

### Added

- `ModelOptions.grok` carries the silence window xAI Grok Voice endpoints on: `.grok(silenceDurationMs:prefixPaddingMs:)`. It is the one detector Grok offers, so there is nothing to select between. `nil` keeps the provider default. See [Turn-taking](https://platform.askcosmo.ai/docs/concepts/turn-taking#provider-endpointing).

### Breaking

- `ModelOptions.grok` now carries `silenceDurationMs` and `prefixPaddingMs`, both defaulted to `nil`. Spell the untuned case `.grok()` — a bare `.grok` no longer typechecks as a value.

- Sessions now start through an agent, matching the Python and TypeScript SDKs: `RealtimeClient(options)` → `client.agent(instructions:model:modelOptions:voice:audio:tools:interruptionSensitivity:greeting:skills:mcp:hooks:)` or `client.catalogAgent(_:inputs:voice:tools:mcp:hooks:)` → `agent.start(...)`. `RealtimeSession.start(_:config:micMuted:rpcHandlers:)` and `client.start(config:)` are removed, as is direct `RealtimeAgent(tools:skills:mcp:hooks:)` construction — every field they took has a home on the factory or on `start`.
- `SessionConfig` is removed. Its agent-scoped fields (instructions, model, `modelOptions`, voice, audio, tools, `interruptionSensitivity`, greeting, hooks) are `client.agent(...)` parameters; a catalog run's `agentName`/`agentInputs` are `client.catalogAgent(name, inputs:)`; the per-run params (`resumeSessionId`, `maxSessionSeconds`, `storeRecording`, `storeAudio`, `storeTranscript`, `storeVideo`, plus `micMuted` and `rpcHandlers`) are `agent.start(...)` parameters.
- `SessionConfig`'s nested types are now top level, one name per concept across the SDKs: `SessionConfig.Tool` → `AgentTool`, `SessionConfig.Voice` → `VoiceConfig`, `SessionConfig.Audio` → `AudioConfig`, `SessionConfig.Ambience` → `AmbienceConfig`, `SessionConfig.ModelOptions` → `ModelOptions` (turn-detection enums nest there: `ModelOptions.GeminiTurnDetection`, `ModelOptions.OpenAITurnDetection`), and the enum aliases `InterruptionSensitivity`, `ThinkingLevel`, `EndOfSpeechSensitivity`, `SemanticEagerness`, `TurnDetectionMode`. `SessionConfig.sdkToolNamePrefix` → `AgentTool.sdkToolNamePrefix`. Cases and fields are unchanged — only the spelling of the type names moves.
- `RealtimeSession.Options` → `RealtimeClient.Options`, unchanged in shape: the credential is client-level configuration, not per-session.
- `RealtimeSession.installConnectTracing()` → `RealtimeClient.installConnectTracing()` — the client owns how connections are made, tracing included. `RealtimeSession.setRecordingAlwaysPrepared(_:)` is no longer public — `MicPrewarmCoordinator.set(_:)` / `.settle()` remain the supported mic-prewarm entry points.
- `RealtimeAgent`'s fields and `RealtimeClient.Options`' fields are now `let`: an agent and a client's options are configured entirely at creation — the factories and initializers are the only writers. Code that mutated a field after construction passes the value to `client.agent(...)` / `catalogAgent(...)` or the `Options` initializer instead.
- The pre-cutover event and error types are removed: `Ready`, `Transcript`, `ToolCall`, `ToolResult`, `ToolInvocation`, `Role`, `ServerError`, `VoiceClientError`, and `ConnectionCloseReason`. They predate the current session API and nothing in the SDK produced or consumed them. Sessions surface events on `RealtimeSession.Event` via `session.events`, and failures throw `RealtimeSessionError`; code still holding the old payload shapes should declare its own copies.

## v0.6.0 — 2026-08-17

### Added

- `turnDetection: GeminiTurnDetection?` on `SessionConfig.ModelOptions.gemini`. `.cosmoVad` opts the session into Cosmo's semantic turn detection, which classifies whether the utterance reads as finished instead of timing a silence window; `.serverVad` pins Gemini's silence-window detection, which is what `endOfSpeechSensitivity`, `silenceDurationMs`, and `prefixPaddingMs` tune (they are read only with `.serverVad`). `nil` keeps the server default, currently `.serverVad`.
- `.cosmoVad(pauseMs:prefixMs:maxHoldMs:)` carries the semantic detector's per-session tuning: `pauseMs` (silence that triggers the end-of-turn inference), `prefixMs` (audio kept from before speech was detected), `maxHoldMs` (total silence after which the turn ends regardless of the classifier's verdict). Pairing a `serverVad` knob with `.cosmoVad` is rejected at session start.

## v0.5.0 — 2026-08-14

### Changed (repository)

- SDK source, examples, and the issue tracker now live in the consolidated [cosmo-ai](https://github.com/socratic-ai/cosmo-ai) repository. Installs are unchanged: [cosmo-swift-sdk](https://github.com/socratic-ai/cosmo-swift-sdk) remains the Swift Package Manager distribution of the same code.

### Added

- `session.usage()` — fetch the session's usage summary (duration, talk time, token counts) over REST, during the session or after it ends. `RealtimeClient.sessionUsage(sessionId:)` is the client-level form. Throws `UsageError`. Resolves to a `SessionUsage`.
- `storeAudio`, `storeTranscript`, and `storeVideo` on `SessionConfig` — per-artifact storage opt-outs, alongside the existing `storeRecording` (still the whole-run macro, so `false` persists nothing; a per-artifact property wins over it). Narrowing only: a session can request less storage than the account's consents allow, never more.
- `RealtimeSession.sdkName` / `RealtimeSession.sdkVersion` — the package identity, sent as `sdk: {name: "cosmo-swift-sdk", version}` on `session-config` and as an `X-Cosmo-SDK` header on every Cosmo REST call. The server records it per session — see [Protocol compatibility](https://platform.askcosmo.ai/docs/concepts/protocol-version).
- `SessionConfig.ModelOptions.grok` — the xAI Grok Voice provider (`grok-voice-think-fast-2.0`), with no knobs today.

### Breaking

- The recorded-session REST endpoints moved from `/api/v1/external/voice-sessions` to `/api/v1/external/sessions`, and every schema on the surface lost the `Voice` qualifier: `VoiceSession` → `SessionRecord`, `VoiceSessionUsage` → `SessionUsage`, `VoiceSessionTokenUsage` → `SessionTokenUsage`, `VoiceSessionTranscriptTurn` → `SessionTranscriptTurn`, and `VoiceSessionImportRequest` → `SessionImportRequest`. The surface is not voice-specific, and the SDKs, the `cosmo` CLI, and the docs all move with it. Anything calling the old path directly must update; the old path is not served.
- `RealtimeSession.protocolVersion` is removed — the wire protocol is unversioned and [evolves additively](https://platform.askcosmo.ai/docs/concepts/protocol-version). `RealtimeSession.sdkVersion` replaces it as the runtime-readable version, and `session-config` / `ready` / `reconnecting` no longer carry a `version` field.

Corrections:

- Zero-argument `try RealtimeSession.Options()` first shipped in v0.4.0, not v0.2.0 as the entry below states. On 0.2.x and 0.3.x, construct with an explicit credential.

## v0.4.0 — 2026-08-08

### Added

- `session.connectTimings` returns the connect-latency breakdown: the client-measured phases (`wsMs`, `roomMs`, `micMs`, `totalConnectMs`) plus `serverTimings`, the server's own phase breakdown. Previously the server half was reachable only through `qoeSnapshot.serverTimings` and the client half not at all. Matches Python's `session.connect_timings` and TypeScript's `session.connectTimings`.
- `send(image:maxLongEdge:quality:streamId:)` takes a `CGImage` and bounds it to a 1280px long edge before encoding — the preferred way to send a frame, since nothing oversized is ever encoded or base64-inflated. `ImageDownscale` is public alongside it (`encodeJPEG`, `targetSize`, `downscaleBase64`, `recommendedMaxLongEdge`, `recommendedQuality`) for callers that want the bounded bytes without sending them. The base64 `send(image:)` overload now re-encodes an over-resolution payload at the recommended bound instead of forwarding it unchanged, and rejects one past the server's ingress limit that it cannot downscale. See [Image input](https://platform.askcosmo.ai/docs/multimodal/image-input#keep-frames-small).
- `MintedToken` now carries `tokenId` (via `CosmoRealtimeMint`) — the handle for revoking that one token early (`DELETE /api/v1/external/auth/token/{token_id}`) — and `mintToken(externalUserId:ttlSeconds:)` (60–86400) shortens the 24-hour default lifetime.
- `SessionConfig.ModelOptions.openaiMini` — the OpenAI Realtime mini tier: the same API on a faster, cheaper model, with no knobs today.
- `TokenSource` — a credential that fetches (and keeps fresh) a minted end-user token from your backend: `TokenSource.endpoint(url)` for any endpoint returning `{ jwt, expires_at }`, `TokenSource.custom(fn)` for full control. Pass it as `.tokenSource(...)` in `Options.Credential`; the SDK caches the JWT, re-fetches inside a 60-second expiry margin, and drops the cache on a `401` session start. See [End-user credentials](https://platform.askcosmo.ai/docs/production/end-user-credentials).
- `RealtimeSession.Options` accepts a `baseURL` on every credential initializer, naming the backend a stored or minted credential was issued for — previously reachable only from inside the package. It still defaults to `COSMO_BASE_URL`, else production, and is fixed once the options are built.
- `ConnectGreeting.nameDirective(userDisplayName:dictation:)` is public, alongside the existing `openingLine(userDisplayName:)`. It returns the address-by-name directive that rides `speakingStyle`, and `nil` for a dictation session — where interpolating the user's name into typed or dictated text is wrong.
- `startAudioStream()` / `pushAudioBuffer(_:)` / `stopAudioStream()` publish caller-owned audio — a synthetic generator, file replay, a load test, or a host with no usable microphone. Push `AVAudioPCMBuffer`s from your render callback. Starting clears the server-side mute gate and silences the device microphone for the stream's lifetime, so the agent hears exactly what you push; stopping (or ending the session) restores it. A session carries one voice: starting a second stream throws `.audioPublishAlreadyActive`.
- `ScreenCaptureRequest` and `SessionConfig.Tool.screenLocate(capture:)` taking a request — `wantsElements` is false when the caller reads only the pixels, so a handler can skip building its element list (an accessibility walk) for the vision locators, which never read it. Building that list is usually the expensive part of a capture. The existing no-argument `screenLocate(capture:)` is unchanged and keeps working; its elements are simply dropped.

### Breaking

- `prepareSession(_:)` and `discardPreparedSession()` are gone. They pre-created a room and pre-minted its join token so that a later `start(_:config:)` could begin joining while session start was still in flight, and they ran against a Cosmo-internal endpoint that is not part of the published API. Nothing replaces them: delete the calls. Sessions connect exactly as before — `start(_:config:)` creates the room as part of the start — except that a caller who was preparing rooms no longer overlaps the start request with the join, so that connect pays the two legs in sequence.
- `VoiceSession` is gone from the package, and with it `VoiceAudioEngine`, `Credentials`, `ClientOptions`, `ServerEvent`, `VoiceConnectionState`, `Diagnostics`, and `GeminiVoice`. It was a convenience wrapper over `RealtimeSession` written for Cosmo's own app, and carried a second copy of the session surface — `sendText`, `setMuted`, `startScreenShare`, `addVideoStream`, `startAudioStream` — that `RealtimeSession` already provides. Build sessions on `RealtimeSession` directly: `start(_:config:)` for the run, `events` for the stream, and the same sends under their own names. Two things have no replacement: `diagnostics` (route-change and underrun counters, which lived on the wrapper's audio shell) and the `Credentials`/`ClientOptions` shapes — pass `RealtimeSession.Options` instead, which now takes `baseURL` so a credential can name the backend that issued it.
- `Agent` is now `RealtimeAgent` — the three objects you compose a call from read `RealtimeClient` → `RealtimeAgent` → `RealtimeSession`, the same in every SDK. The old name is removed rather than aliased; rename the type at your call sites. Nothing else about it changed.
- `agent.start(...)` returns `RealtimeSession` directly, and `AgentSession` is gone. Drop the `.session` hop — `session.events`, not `session.session.events` — and drive the call exactly as a session started any other way. The session now owns the agent's MCP connections: `end()`, or an end from any other cause, tears them down with it, which the wrapper only did for its own `end()`. This matches what `agent.start()` already returned in Python and TypeScript.
- The public typealiases over the generated wire types now name what the generator emits, so `RealtimeSession.Ready` resolves to the renamed schema. The nested spellings a consumer writes are unchanged. `VerifyWorkspace` is now `WorkspaceInfo`, matching the schema and the other SDKs.
- `CosmoRealtimeError` is now `RealtimeError`, leaving no `Cosmo`-prefixed symbol on the surface. `RealtimeSessionError` keeps its prefix — it is the error type of `RealtimeSession`, derived from a tier-1 name the way `RealtimeSessionEvent` is.
- `prewarmConnection(origin:)` and `PrewarmOrigin` are gone. The warm issued a `HEAD` request so the next connect could reuse a pooled TLS connection, which needed the last session's LiveKit URL persisted between launches — the SDK wrote that to the host app's `UserDefaults.standard`. Nothing replaces it: delete the call. Sessions connect exactly as before, and the SDK no longer writes to app storage.
- `SessionConfig.ModelOptions` drops the `.ultravox` and `.personaplex` cases. Select a voice model with the plain `model` string instead; per-provider tuning for those models is no longer exposed.
- `SessionStartServerTimings` is now `RealtimeSessionStartTimings`, the generated wire type, rather than a hand-written mirror of it. Field names and value types are unchanged (`totalMs`, `versionCheckMs`, …), so reads keep working; construction takes the generated memberwise initializer, whose parameters are alphabetical.
- WebRTC statistics collection is removed. `session.qoeSnapshot` and `SessionQoESnapshot` are replaced by `session.connectTimings` and `SessionConnectTimings`, which carry the connect phases and server start timings only. The sampled jitter / round-trip / jitter-buffer summaries, screen-share encoder health, packet-loss and concealment counters, and the connection-quality summary are gone, along with `SessionQoEMetricSummary`, `SessionConnectionQualitySummary`, and `RealtimeConnectionQuality`. The SDK no longer enables LiveKit's per-track statistics timer, so it also no longer drives LiveKit's server-side analytics. Read WebRTC statistics from LiveKit directly if you need them.
- `mintToken(externalUserId:)` moved to the opt-in `CosmoRealtimeMint` product — add `import CosmoRealtimeMint` where a backend or tool genuinely mints. A plain `import CosmoRealtime` (what a shipped app uses) no longer exposes minting; `verify()` and `MintedToken` stay in `CosmoRealtime`.
- The deprecated `ConnectGreeting.base` alias is removed; use `ConnectGreeting.instruction`.
- The skills loader is `cosmo_sdk_load_skill`, not `load_skill`. It joins the reserved `cosmo_sdk_` namespace the other SDK-shipped client tools use, so hooks and tool-call handlers matching the old name no longer fire, and the plain `load_skill` name is free for your own tools. A tool of your own claiming the reserved name is now rejected when you declare it, rather than silently dropping every skill on the agent.
- The app-side session conveniences are gone from `CosmoRealtime`: `VoiceSessionModel`, `VoiceSessionState`, `LevelMeterModel`, `TranscriptLine` / `TranscriptReducer` / `TranscriptRevealer`, `TurnCompleteCoalescer`, `VoiceActivityEvent` / `VoiceActivityMonitoring`, `PhraseMatcher`, `WakeWordDetector`, `VoiceSettingsStore`, and `AppErrorPresentation` / `ErrorPresentationMapper`. These were Cosmo's own app view-model internals riding in the package, not session API — build app state on `RealtimeSession` events (see [Transcripts](https://platform.askcosmo.ai/docs/concepts/transcripts) for the reducer rules). The session surface itself (`RealtimeSession`, `VoiceSession`, sends, events, tools, hooks) is unchanged.
- The `CosmoRealtimeiOSTools` and `CosmoNotesKit` products are removed — they were Cosmo-app feature kits (on-device Vision tools, an on-device notes store), not SDK surface. Declare equivalent on-device capabilities as your own client tools via `SessionConfig.Tool.client`.
- The `CosmoRealtimeARKit` product is removed.
- The `draw_path` tool helper (`DrawPathTool`, `DrawPathRequest`, `DrawPathStyle`) is removed. `DrawBoxTool` and `DrawPointTool` remain, and `NormalizedPoint` stays in `CosmoRealtime`.
- The session-history REST wrappers are gone from `RealtimeClient` — `listVoiceSessions`, `voiceSession(sessionId:)`, `voiceSessionTranscript`, `deleteVoiceSession`, `realtimeCapabilities` — along with the `VoiceSessionSummary`, `VoiceSessionTranscriptTurn`, and `RealtimeProviderCapabilities` typealiases. The endpoints are unchanged and still published; call the REST API directly with your HTTP client and workspace credential.
- `sendVisualContext` and the `VisualContextPayload` type family (`VisualContextReason`, `VisualDisplayInfo`, `FocusedWindowInfo`, `VisualImageRef`) are removed, and the server no longer accepts the frame. Screen state travels as plain text via `sendContext` (with `sendImage` for pixels) — the same primitives every SDK has.
- `send(bytes:topic:)` / `sendBytes` is internal now. It existed for the screen tools' capture publish, which the SDK drives itself — the sibling SDKs keep byte-stream sending inside their tool plumbing too, and nothing else ever called it.
- `sendTurnContext`, the `cosmo` send namespace, and `CursorPoint` are removed, and the server no longer accepts the `turn-context` frame (it also leaves the published wire spec). Per-turn desktop context travels as plain text via `sendContext`, like every other ambient state.
- `ClientIdentity` and the `clientIdentity` option on `RealtimeSession.Options` and `ClientOptions` are removed, so the SDK no longer sends the `X-Cosmo-Client`, `X-Cosmo-Client-Version`, and `X-Cosmo-Client-Build` headers. These carried Cosmo's own app-build telemetry rather than anything the session needed. The endpoints accept requests without them and are otherwise unchanged; set your own headers on calls you make to your own backend.
- `audio.noiseCancellation` defaults to off. The isolator sits ahead of the model, so the filtered signal is also what turn-taking reads, and a session that never asked for it should not pay that cost. Pass `SessionConfig.Audio(noiseCancellation: true)` to keep the previous behavior.
- A `PostToolUse` hook sees `.ok` — carrying the handler's own untruncated result — where an over-cap client-tool result previously gave it `.error`. The cap is a transport property, not a tool failure. A hook that detected oversized results by matching the `client tool result exceeded the reply size limit` message no longer fires; read `cosmo_sdk_truncated` off the reply instead.

### Added

- `MintedToken` now carries `tokenId` (via `CosmoRealtimeMint`) — the handle for revoking that one token early (`DELETE /api/v1/external/auth/token/{token_id}`) — and `mintToken(externalUserId:ttlSeconds:)` (60–86400) shortens the 24-hour default lifetime.
- `SessionConfig.ModelOptions.openaiMini` — the OpenAI Realtime mini tier: the same API on a faster, cheaper model, with no knobs today.
- `TokenSource` — a credential that fetches (and keeps fresh) a minted end-user token from your backend: `TokenSource.endpoint(url)` for any endpoint returning `{ jwt, expires_at }`, `TokenSource.custom(fn)` for full control. Pass it as `.tokenSource(...)` in `Options.Credential`; the SDK caches the JWT, re-fetches inside a 60-second expiry margin, and drops the cache on a `401` session start. See [End-user credentials](https://platform.askcosmo.ai/docs/production/end-user-credentials).
- `ConnectGreeting.nameDirective(userDisplayName:dictation:)` is public, alongside the existing `openingLine(userDisplayName:)`. It returns the address-by-name directive that rides `speakingStyle`, and `nil` for a dictation session — where interpolating the user's name into typed or dictated text is wrong.
- `SessionConfig.ModelOptions` gains `.openaiMini`, selecting the mini tier of the `openai` provider (no knobs).
- `ClientToolReply.truncationSuffix`, `.truncationMarkerKey`, and `.truncationMarkerNote` join `.maxBytes` as public constants, so a tool pack that shapes its own replies reads the truncation contract off the transport instead of copying its literals.

### Fixed

- A `401` from the REST surface carries the server's message directly: `verify()` and `mintToken` throw `.rejected(code: nil, detail:)` with the auth layer's `detail` string, and a rejected session start surfaces `handshakeFailed(status: 401, ...)` with the same — previously the detail was the raw `HTTP 401: <body>` dump.

### Changed

- The screen locator's accessibility list carries names, not documents. `role`, `title`, and `label` are truncated to a descriptor length, and an element's `value` is sent only where nothing else names it — the locator grounds against the screenshot, so a named element's content is a second copy of pixels it can already read. A focused text area holding a long document previously shipped whole, and the capture could be rejected outright for its length.
- The package is licensed Apache-2.0, and ships a `NOTICE` and a third-party license manifest.
- A client-tool result over the 15 KiB reply cap is shortened and delivered instead of discarded. Long strings are trimmed with `… [truncated]`; when the overflow is structural rather than textual, top-level entries are dropped largest-first. Either way the result carries a `cosmo_sdk_truncated` key — a note telling the model the answer is partial, plus the kept and original byte counts so it can tell losing a little from losing almost everything. Previously the whole result was replaced with a `client tool result exceeded the reply size limit` error, and a `PostToolUse` hook saw `.error` — it now sees `.ok` with the handler's own untruncated result. See [Keep the reply small](https://platform.askcosmo.ai/docs/capabilities/tools#keep-the-reply-small).
- A background tool's `job.ack(note:)` note is shortened to fit the reply cap rather than overflowing it.

- Endpointing knobs on `SessionConfig.ModelOptions`. `.gemini` gains `includeThoughts`, `endOfSpeechSensitivity`, `silenceDurationMs`, and `prefixPaddingMs`; `.openai` now takes a `turnDetection`, either `.serverVad(silenceDurationMs:prefixPaddingMs:)` or `.semanticVad(eagerness:)`, so each detector carries only its own knobs. Unset knobs keep today's behavior. See [Turn-taking](https://platform.askcosmo.ai/docs/concepts/turn-taking#provider-endpointing).

## v0.3.0 — 2026-08-04

### Breaking

- Screen tools are SDK client tools now, and the screen-interaction vocabulary is retired.
- The client resolves its backend from `COSMO_BASE_URL`; the documented default origin is `https://platform.askcosmo.ai`.

## v0.2.0 — 2026-08-03

### Breaking

- The per-turn `audioResponse` flag is gone. Configure `audio` on `SessionConfig` for a text-only session.
- Voice and audio settings moved into nested `Voice` and `Audio` blocks on `SessionConfig`.
- `detect` and `point` tool kinds are now `detect_objects` and `point_at_object`.
- Renderer tool text and the `draw_after` names changed.

### Added

- Zero-argument construction: `try RealtimeSession.Options()` resolves `COSMO_API_KEY`, then the `cosmo login` credentials file, adopting the stored key's backend; a conflicting `COSMO_BASE_URL` is refused up front (`base_url_mismatch`). Throws `CredentialsError` when nothing usable resolves.
- `verify()` against `GET /realtime/verify`.
- `waitUntilEnded()` / `waitUntilAgentLive()` — awaiting session end and agent liveness without racing events.
- The Cartographer SwiftUI example.

### Changed

- `noiseCancellation` defaults to on.

## v0.1.0 — 2026-05-01

Initial release.

- `CosmoRealtimeClient` actor with `connect(init:)`, `disconnect`, `send(text:audioResponse:)`, `setMicrophoneMuted`, `sendPing`, `end`.
- Event subscriptions returning `Cancellable`: `onTranscript`, `onToolCall`, `onReady`, `onConversationLink`, `onError`.
- `CosmoRealtimeClient.Configuration` with `apiKey` and `baseURL`.
- `RealtimeClientConfig` typealias.
- `CosmoRealtimeError` enum: `sessionStartFailed`, `notConnected`.
- Generated `Client` and `Components.Schemas.*` types from the external API's OpenAPI schema with the Swift OpenAPI Generator plugin.
- `EnvelopeReassembler` actor for transparent reassembly of `server-envelope-chunk` messages.
- `BearerAuthMiddleware` for automatic `Authorization: Bearer` injection.
- `@_exported` re-exports of `OpenAPIRuntime` and `OpenAPIURLSession`.
