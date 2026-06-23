---
title: MCP Server / Claude-Code Plugin Issues
date: 2026-06-22
author: Claude Code (Opus 4.8)
workspace: FunWasHad (F:\GitHub\FunWasHad)
plugin_repo: F:\GitHub\mcpserver-claude-code-plugin
mcpserver: PAYTON-LEGION2:7147
scope: Issues encountered 2026-06-21 .. 2026-06-22 while driving the plugin for a /wrap-up
---

# MCP Server / Claude-Code Plugin Issues

## Context

These issues surfaced while using `mcpserver-claude-code-plugin` to run a `/wrap-up`
(requirements reconcile, wiki export, session-log turn) on the FunWasHad workspace.
The plugin was driven through `lib/Invoke-ClaudeMcpPlugin.ps1 -Command Invoke -Method
workflow.* -Params <yaml>`, which shells into `lib/repl-invoke.sh`, which spawns
`mcpserver-repl --agent-stdio` to talk to McpServer at PAYTON-LEGION2:7147.

## How these were confirmed

Each item started as an empirical symptom from a real session, then was checked against
plugin source (file:line). Confidence is graded:

- **confirmed-in-source**: the cause was located in code at the cited lines.
- **partially-confirmed**: code is consistent with the symptom; exact trigger line not pinned (needs a live-server sample).
- **empirical-only**: symptom is real but the cause is server-side (McpServer C#), not in the plugin repo.
- **refuted (for this repo)**: the asserted text/behavior is not in the plugin repo; it lives elsewhere.

## Summary

| ID | Severity | Component | Status | One-line |
|----|----------|-----------|--------|----------|
| RACE-409-CREATED | High | repl-invoke.sh | confirmed-in-source | Batch create double-submits with fresh request ids and no idempotency key; first commits, second returns 409, atomic-abort surfaces 409 for the whole batch even though records were created. |
| LATENCY | High | repl-invoke.sh | confirmed-in-source | Persistent daemon is orphaned dead code; every call cold-starts fresh `mcpserver-repl` .NET processes + new server auth, and one mutation spawns several. ~40-120s/call. |
| WRAP-EXIT1-ON-SUCCESS | Medium | repl-invoke.sh | partially-confirmed | Exit code reflects transport liveness, not server commit: a timeout-after-commit or a 409 returns non-zero even though the mutation landed. |
| WRAP-ERR-MASK | Medium | Invoke-ClaudeMcpPlugin.ps1 | confirmed-in-source | On non-zero exit the wrapper throws the bare exit code and discards the daemon's `type: error` envelope (code+message) on stdout. |
| STALE-TURNS | Medium | repl-invoke.sh | confirmed-in-source | `beginTurn` overwrites the single current-turn pointer without finalizing/superseding a prior `in_progress` turn; old turns stay `in_progress` on the server forever. |
| REQ-BACKFILL-TS | Low | McpServer (server-side) | empirical-only | A junk `FR-SOCIAL-*` placeholder ("backfilled for TODO link") and `createdAt` stamped at read time. Server-side; plugin only relays. |
| DOCS-PLUGIN-ID | Low | NOT a plugin-repo bug | refuted (repo) | The "use mcpserver-codex-plugin" instruction is in the user's local `~/.claude/skills/wrap-up/SKILL.md`, not the plugin repo (whose copy is correct). |

## Issues

### RACE-409-CREATED (High, confirmed-in-source) - batch create double-submits

**Symptom.** `workflow.requirements.createFrBatch` (FR-SOCIAL-003/004), `createTrBatch`,
and `createTestBatch` each returned `HTTP 409 ... 'FR-SOCIAL-003' already exists` with
`total:0, items:[]` on the FIRST attempt. An immediately-following `listFr`/`listTr`/`listTest`
showed every record present with the exact titles/descriptions I had submitted. So the create
succeeded but reported a conflict.

**Root cause.** Batch creates are classified "prefers typed" (`repl-invoke.sh:820`) and run
through `_repl_workflow_requirements` (`repl-invoke.sh:2982`), whose typed-first block sends the
SAME batch up to twice: a compat-marker send (`:3028`) and then a non-compat send (`:3045`). The
second send is effectively unconditional because the only short-circuit helper,
`_repl_requirements_created_response_after_empty_success` (`:1650`), maps only single
`createFr/createTr/createTest` (`:1641-1648`) and has NO `*Batch` entries, so it returns 1 for
batches and never blocks the retry. Each `_repl_invoke_raw_in_workspace` mints a brand-new
`requestId` (`:1327`, `req-$(_repl_now_compact)-$(printf '%04x' $RANDOM)`), so the two physical
sends carry DIFFERENT ids and the server has no idempotency key to dedupe them. If attempt #1
commits but its response is either misclassified as an empty result by the crude awk parser
`_repl_response_has_empty_result` (`:484-492`) or lost to a timeout after commit, the identical
batch is re-sent. The server then sees the already-created ids and, because batch create is
atomic-on-conflict (`skills/requirements/SKILL.md:133` "fail all records if any record ...
conflicts"), aborts ALL records with a 409. The same compat-then-noncompat double-send repeats at
`:3097` and `:3121` and across the workflow/memory/sessionlog paths, so it is structural, not a
one-off. (`lib/repl-daemon.js:107-124` sends each envelope exactly once, so the duplication is in
the shell layer, not the daemon.)

**Impact.** Callers see a hard 409 failure on a create that actually succeeded. With atomic
batches, one stale id fails the whole batch. Naive callers retry or abort incorrectly. This is the
single most misleading behavior of the set.

**Suggested fix.** (1) Thread ONE stable requestId / idempotency key through both sends instead of
regenerating `$RANDOM` at `:1327`. (2) For ambiguous first-send results (empty-result OR timeout),
read-back the ids before retrying and treat "present" as success; extend
`_repl_requirements_created_response_after_empty_success` to understand `*Batch` methods. (3)
Treat a 409/already-exists on a create retry as success-equivalent. (4) Fix
`_repl_response_has_empty_result` so a populated `{total,items:[...]}` body is not read as empty.

**Repro.** Drive a `createFrBatch` against a server where the first typed send commits but the shell
does not classify the response as a clean non-empty success (force a low REPL timeout, or a batch
body the awk parser reads as empty): observe the second send at `:3045` with a new requestId, a
409 from the server, and the records present on a follow-up `listFr`.

### LATENCY (High, confirmed-in-source) - persistent daemon is orphaned; every call cold-starts .NET

**Symptom.** Every requirements/sessionlog mutation took ~40-120s (~67s average). Measured from one
sequential batch: createMapping 14:02:15 -> 14:02:59 (~44s); updateFr 14:05:09 -> 14:06:48 (~99s);
updateTr 14:08:13 -> 14:09:29 (~76s); updateTest 14:10:57 -> 14:12:27 (~90s). Nine calls spanned ~10
minutes.

**Root cause.** The plugin ships a real warm/persistent daemon (`lib/repl-daemon.js --serve`,
fronted by `lib/repl-persistent.sh:repl_invoke_persistent`, IDLE_SECONDS=300), but NOTHING in the
production invoke path uses it. A repo-wide grep for `repl_invoke_persistent` / `repl-persistent` /
`repl-daemon` matches only those two files plus a checksum manifest: the daemon is orphaned dead
code. The actual path spawns a fresh bash process per call (`Invoke-ClaudeMcpPlugin.ps1:154-156`),
which sources `repl-invoke.sh` fresh and runs `mcpserver-repl --agent-stdio`
(`repl-invoke.sh:1378`, and `:1038`). `mcpserver-repl` is a global .NET tool
(`ensure-repl.sh:33`), so every invocation pays a fresh .NET cold-start (assembly load + JIT) plus a
fresh HTTP connection and auth handshake to PAYTON-LEGION2:7147. Worse, a single logical
requirements mutation spawns the process SEVERAL times: `_repl_workflow_requirements` tries
typed+compat (`:3028`), typed+plain (`:3045`), workflow+compat (`:3064`), workflow+plain (`:3080`),
then typed fallbacks (`:3097`, `:3121`), each its own spawn, and compat mode also builds/removes a
temp marker dir per call (`:1342-1346`, `:1383-1385`).

**Impact.** A normal wrap-up (a dozen-plus mutations) takes 10-25 minutes of wall-clock, almost all
of it process/connection cold-start, not server compute. This shares a root region with
RACE-409-CREATED (the same `:2982-3130` retry fan-out).

**Suggested fix.** Wire the existing daemon into `_repl_invoke_raw_in_workspace` / `_repl_invoke_raw`
(route through `repl_invoke_persistent` when `MCPSERVER_REPL_PERSISTENT!=0` and node is available) so
all calls reuse one long-lived `mcpserver-repl` child and its warm server connection. Separately,
collapse the typed/workflow x compat/plain spawn fan-out (probe the server's supported method once).
Any residual per-warm-call latency after that is server-side (McpServer C#/SQL).

**Repro.** Run a batch of mutations through the plugin and `Get-Process mcpserver-repl` during the
run: one or more fresh processes per call, and no `mcpserver-repl-daemon.json` state file
(`repl-daemon.js:32`) is ever created because `--serve`/`--send` are never invoked.

### WRAP-EXIT1-ON-SUCCESS (Medium, partially-confirmed) - exit status ignores server commit

**Symptom.** A `beginTurn` through the PowerShell wrapper threw "exit code 1", yet state had been
created (a later `beginTurn` via `repl-invoke.sh` succeeded; and `create*Batch` reported 409 while
the records existed - see RACE-409).

**Root cause.** Exit status is derived from local transport liveness and from whether the response
text parses as an error, never from whether the server committed. (1) Timeout-after-commit:
`_repl_run_repl_with_timeout` returns 124 on timeout (`repl-invoke.sh:587-596`), and
`_repl_invoke_raw_in_workspace` (`:1395-1404`) / `_repl_invoke_raw` (`:1040-1051`) then `return 1`
regardless of server state; the daemon transport has the same class of flaw (`repl-daemon.js:109-112`
rejects after 170s having already written the request). (2) Error-response-as-failure: any
`type: error` body maps to non-zero via `_repl_response_is_error` (`:480-482`), and there is NO
409/Conflict handling anywhere in `lib/` (grep for `409|Conflict|already exists` = zero matches), so a
post-commit 409 becomes a hard failure. The wrapper then converts ANY non-zero bash exit into a
thrown error (`Invoke-ClaudeMcpPlugin.ps1:171-173`). Graded partially-confirmed because the specific
`beginTurn` case could not be pinned to one line: `beginTurn`'s only server write is swallowed with
`|| true` (`:3538`); the most likely path is the auto-open branch where `_repl_bootstrap_state` can
`return 1` on a slow/transient verify (`:3400`, `:3506`, `:3509`) after `openSession` may have already
created state (`:3429-3430`), which exactly matches "first attempt errored, retry succeeded".

**Impact.** Mutating operations can report failure after succeeding, leading to incorrect retries,
orphaned state, and false "blocked" reports.

**Suggested fix.** Make exit status reflect commit, not liveness: on timeout/parse-failure for
mutating methods, mark pending and reconcile via the existing failsafe write-ahead log plus an
idempotent read-back; add explicit 409 handling; in the wrapper, distinguish a plugin-reported error
response from a crashed process rather than a blanket throw.

### WRAP-ERR-MASK (Medium, confirmed-in-source) - wrapper hides the daemon error envelope

**Symptom.** A failing call through the wrapper produced only `Exception ... Plugin command failed
with exit code 1.` with no error code or message. The identical method via
`printf <yaml> | bash lib/repl-invoke.sh <method>` showed the full `type: response` / `type: error`
envelope on stdout.

**Root cause.** `Invoke-BashPluginScript` captures stdout and stderr separately
(`Invoke-ClaudeMcpPlugin.ps1:163-164`), forwards only stderr to the console (`:167-169`), and on
non-zero exit throws the bare exit code (`:171-173`) WITHOUT referencing `$stdout`. The
`Write-Output $stdout` that would surface the envelope is gated behind the success path AFTER the
throw (`:175-177`), so it never runs on failure. The daemon carries its structured error on stdout,
so that payload is silently dropped.

**Impact.** Pure diagnosability loss: callers cannot see WHY a call failed and must drop down to
`repl-invoke.sh` to debug (which is how the rest of this report was produced).

**Suggested fix.** Include `$stdout` in the thrown message (or emit it before throwing), e.g.
`throw "Plugin command failed with exit code $($process.ExitCode).`n$($stdout.TrimEnd())"`.

### STALE-TURNS (Medium, confirmed-in-source) - beginTurn never finalizes a prior open turn

**Symptom.** `-Command Status` reported `currentTurn = req-20260614T011406Z-rerun-ci-862-fdroid`
(status `in_progress`, ~8 days old, an unrelated CI task) in session
`ClaudeCode-20260612T213536Z-handoff-from-codex`; `queryHistory` also showed a separate
`funwashad-ci-wrapup` session as `in_progress`. Starting a new turn worked but left the old turn
orphaned.

**Root cause.** `_repl_workflow_begin_turn` (`repl-invoke.sh:3499-3542`) unconditionally truncates and
rewrites the single `current-turn.yaml` with a fresh turn at `status: in_progress`
(`:3522-3536`). It never reads the existing turn's status, never checks for a lingering
`in_progress`, and never issues a `completeTurn`/`failTurn` to finalize or supersede it. The cache
tracks only ONE current turn (no stack), so the prior local record is discarded and its server-side
record is left `in_progress`. `_repl_workflow_open_session` (`:3430`) is the same. The state machine
docs (`skills/session/SKILL.md:267-289`) say a turn must be explicitly moved to a terminal state and
that `beginTurn` does not close a prior one, but nothing in the plugin automates that. (Consistent
with `GAPS.md:41-43`: the ps1 shim treats `beginTurn`/`openSession` as no-ops and the sh shim "owns
the turn cache".)

**Impact.** Sessions and turns accumulate as permanently `in_progress` on the server; `currentTurn`
goes stale across sessions, so audit/history is unreliable and wrap-up tooling cannot trust the
"active turn".

**Suggested fix.** Before overwriting `current-turn.yaml`, read the prior turn; if still
`in_progress`, auto-finalize it (completeTurn/failTurn with a terminal status such as `superseded`)
or at minimum emit a warning + audit note. Mirror in `open_session`. Optionally surface a
lingering-open-turn warning in `mcp.claude.status.sh` (it already reads the status at `:97`).

### REQ-BACKFILL-TS (Low, empirical-only) - server-side placeholder backfill and read-time createdAt

**Symptom.** The first `listFr area:SOCIAL` returned a junk row `id == title == FR-SOCIAL-*` with
description "Placeholder requirement backfilled for TODO link FR-SOCIAL-*.", and FR-SOCIAL-001/002
carried `createdAt` equal to the moment of the list call (they long predate today).

**Root cause (not in plugin).** The plugin relays the server body verbatim: the list path streams the
JSON unchanged (`repl-invoke.sh:2375-2438`, esp. `:2433-2434` `printf '  result: |' ; sed 's/^/    /'`),
and the only re-GET helper (`:1650-1697`) is gated on mutations, not reads. Repo-wide greps for
`backfill|Placeholder|seed|lazy|createdAt` find no requirements-side synthesis. So the lazy
backfill-on-read and read-time `createdAt` are in McpServer's C# (likely a TODO->FR link
reconciliation that seeds a placeholder FR when a linked id is missing, plus a List handler stamping
`createdAt` at materialization).

**Suggested fix (McpServer team).** Remove or make explicit/idempotent the seed-on-read; stamp
`createdAt` from the original persisted value; provide a purge for the `FR-SOCIAL-*` placeholder
(`deleteFr` should remove it, unless the server recreates it on the next read). A plugin-side filter
to hide `id == title` placeholder rows would only mask the data-quality bug and is not recommended.

### DOCS-PLUGIN-ID (Low, refuted for this repo) - codex instruction is in the user's local skill, not the plugin

**Symptom.** During wrap-up I initially reached for `mcpserver-codex-plugin` and (in a prior session)
declared the claude-code plugin "unavailable".

**Finding.** The misdirecting text is NOT in the plugin repo. `F:\GitHub\mcpserver-claude-code-plugin\skills\wrap-up\SKILL.md`
and all of README.md / ENFORCEMENT.md / skills/session/SKILL.md are internally consistent and carry
the correct caveat ("workflow.* are plugin REPL method names, not literal native MCP tool names; do
not declare the plugin unavailable solely because generic MCP discovery does not list them"). A
repo-wide grep for `mcpserver-codex-plugin` over the repo's SKILL.md files = no matches. The
"Use `mcpserver-codex-plugin` for MCP operations" instruction lives in the USER's local skill
`C:\Users\kingd\.claude\skills\wrap-up\SKILL.md` (`userSettings:wrap-up`), which is the copy injected
into the agent at session start. That local skill is what pulled the agent toward codex. The only
`codex` strings in the plugin repo are a cross-plugin testing plan and `GAPS.md` packaging notes.

**Suggested fix.** Edit the user's local `~/.claude/skills/wrap-up/SKILL.md` to use
`mcpserver-claude-code-plugin` (or make it marker-driven). No change needed in the plugin repo for
this. If the sibling `mcpserver-codex-plugin` ships the same wrap-up skill description, align it
there too.

## Related notes (from GAPS.md and the dir listing)

- **Two wrappers; docs point to the legacy one.** `GAPS.md` item 4 says the canonical wrapper was
  renamed to `lib/Invoke-McpPlugin.ps1` (adds `-TimeoutSeconds` default 90, env
  `MCP_PLUGIN_TIMEOUT_SECONDS`, bounded `WaitForExit` + taskkill, status-script discovery), and that
  hosts needing the old name "ship a copy or shim named `Invoke-<Host>McpPlugin.ps1`". Both files
  exist in `lib/`. The wrapper actually invoked here (and that the docs/marker steer agents to),
  `Invoke-ClaudeMcpPlugin.ps1`, is the legacy thin shim and is where WRAP-ERR-MASK lives; it also
  lacks the timeout+taskkill safety the canonical one has. Recommend: confirm whether
  `Invoke-McpPlugin.ps1` has the same error-masking, and align docs/marker to the canonical wrapper.
- **PS1 vs SH parity.** `GAPS.md:41-51`: the ps1 side treats `beginTurn`/`openSession` as no-ops (the
  sh shim owns the turn cache), and the upsert "compat marker" first attempt and the v4 failsafe
  layout are not ported to ps1. Relevant if/when the ps1 path is used directly instead of shelling to
  bash.

## Practical workaround in use today

When the wrapper errors opaquely, drop one layer down and call the plugin's own invoker directly to
see the real envelope (same code path, observable output):

```
cd F:\GitHub\mcpserver-claude-code-plugin
export CLAUDE_PLUGIN_ROOT="$PWD" PLUGIN_ROOT_OVERRIDE="$PWD" \
  MCP_WORKSPACE_PATH=<ws> MCPSERVER_WORKSPACE_PATH=<ws> CLAUDE_PROJECT_DIR=<ws>
printf '%s\n' '<param: yaml>' | bash lib/repl-invoke.sh <workflow.method>
```

And after any batch create that reports 409, do NOT retry blindly: `list*` first and treat
"records present" as success (RACE-409-CREATED).
