# Cymphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## 1. Problem Statement

Cymphony is a long-running automation service that continuously reads work from an issue tracker
(Linear in this specification version), creates an isolated workspace for each issue, and runs a
coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations may target trusted environments with a high-trust configuration, while others may
require stricter approvals or sandboxing.

Important boundary:

- Cymphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the workflow/runtime environment.
- A successful run may end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support restart recovery without requiring a persistent database.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (optional)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Cymphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses front matter into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (Linear adapter)
   - API calls and normalization for tracker data.

6. `Observability Layer` (logs + optional status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `tracker.kind: linear` in this specification version).
- Local filesystem for workspaces and logs.
- Optional workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports JSON-RPC-like app-server mode over stdio.
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (workspace path; current runtime typically uses absolute paths, but relative roots are
  possible if configured without path separators)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (optional)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `claude_app_server_pid` (string or null)
- `last_claude_event` (string/enum or null)
- `last_claude_timestamp` (timestamp or null)
- `last_claude_message` (summarized payload)
- `claude_input_tokens` (integer)
- `claude_output_tokens` (integer)
- `claude_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `held` (boolean; timer disarmed while dispatch is paused, §8.5)
- `error` (string or null)

Retry/backoff stays its own list (`retry_attempts`), rendered **below** In Progress. Retrying
issues are not waiting-board members and must not appear on `section.queue-board`.

`held` is part of the snapshot and of `/api/v1/state`. A held entry keeps its original — now
past — `due_at_ms`, so its `due_in_ms` clamps to `0` for the whole pause: without `held`, a retry
parked indefinitely is indistinguishable from one due this instant, and any presenter deriving an
absolute `due_at` from `now + due_in_ms` produces a value that advances one second per second,
which re-renders every project section on every payload load of an otherwise idle paused board.
Status surfaces therefore render "held" for such an entry and no due time at all. On the dashboard
that is a tag in the same grammar as its neighbours, not a loose muted sentence — the retry row
gets a "held" modifier class and the state renders as a neutral tag beside the amber "Attempt N".
Held means *suppressed*, not failing, so the tag carries no amber and the modifier mutes the row's
amber retry edge: while dispatch is paused every retry row is held, and a wall of warning-coloured
rows misreports a deliberately parked queue.

`error` is truncated by status surfaces (the dashboard retry row shows 120 characters), so it must
be front-loaded with the failure itself. A crashed agent task exits with `{exception, stacktrace}`:
record the exception message, not the inspected tuple, and keep the issue context (already present
in the log line) after the reason. Otherwise the agent CLI's own error text — which the runner
retains as the `{:agent_exit, status, tail}` tail (§10.8), newest line first for the same reason —
is pushed past the cut. That tail is redacted before it leaves the runner (§10.8), so no status
surface — this one, `/api/v1/state`, or the tracker abandonment comment — has to redact it again.

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `paused` (dispatch suspended; seeded at init from the persisted `dispatch_paused`, Section 8.1)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `waiting` (ordered list of dispatch-ready `Issue` values; **name this list `waiting`
  everywhere** except UI copy `Up next` / `Queue` / header `Q queued`)
- `queue_order` (list of issue keys — identifier if present else `id`; persisted sticky
  operator order)
- `queue_pins` (map `issue_key -> %{agent_kind?, model?, effort?}`; persisted local pins
  for the next waiting dispatch; no provider)
- `queue_priority_seen` (map `issue_key -> integer | null`; last seen Linear priority,
  used only to detect a Linear **raise**)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `claude_totals` (aggregate tokens + runtime seconds)
- `claude_rate_limits` (latest rate-limit snapshot from agent events)

`queue_order`, `queue_pins`, `queue_priority_seen`, and `dispatch_paused` persist on
the matching `projects[]` object in `~/.cymphony/config.json` (file mode `0600` via
existing `save/1`). They are **not** WORKFLOW.md front matter and must not be added to
`Config.Schema`. `Orchestrator.init` loads them via `CymphonyConfig.load` /
`find_project`. `CymphonyConfig.update_project_queue/2` merges any of the three queue
keys onto the named project (`nil` name = legacy flat/all) and `save/1`;
`CymphonyConfig.update_dispatch_paused/2` does the same for the pause boolean and
`CymphonyConfig.dispatch_paused?/2` reads it back (unknown project or non-list
`projects` falls back to the top-level key; anything other than stored `true` is
`false`). Pin maps omit empty keys.

These are read-modify-write sequences run from unrelated processes — the dashboard
LiveView, the JSON API, and each project's orchestrator (which persists queue state from
its own poll tick whenever the waiting set moves). They must therefore be **serialized**
against each other, and `save/1` must be **atomic** (stage to a sibling temp file, chmod
`0600` while empty, rename over the target). Without both, an interleaved save writes back
a config loaded before the other writer's save and silently drops a field — a just-persisted
`dispatch_paused` (the daemon stays paused in memory, so nothing looks wrong until the next
restart resumes it) or a drag-reordered `queue_order` — and a reader can observe a
half-written file. Example:

```json
{
  "dispatch_paused": true,
  "queue_order": ["LLM-51", "LLM-12"],
  "queue_pins": {
    "LLM-51": {"agent_kind": "codex", "model": "gpt-5.2-codex", "effort": "high"}
  },
  "queue_priority_seen": {"LLM-51": 2, "LLM-12": 3}
}
```

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with optional YAML front matter.

Design note:

- `WORKFLOW.md` should be self-contained enough to describe and run different workflows (prompt,
  runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter must decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `prompt_template`: trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `claude`
- `codex`
- `antigravity`

Unknown keys should be ignored for forward compatibility.

Note:

- The workflow front matter is extensible. Optional extensions may define additional top-level keys
  (for example `server`) without changing the core schema above.
- Extensions should document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.
- Common extension: `server.port` (integer) enables the optional HTTP server described in Section
  13.7.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - Required for dispatch.
  - Current supported value: `linear`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (string)
  - May be a literal token or `$VAR_NAME`.
  - Durable operator store for Linear credentials is `~/.cymphony/config.json`:
    top-level `linear_api_key`, also stamped onto every `projects[].linear_api_key`
    (a shared key on the project map; **not** a Symphony `tracker.provider` nest).
  - Generated per-project `WORKFLOW.md` files write that value as `tracker.api_key`. Because
    they carry the key in cleartext, every generated workflow file must end up mode `0600` —
    initial generation, the agent-settings rewrite, and the Linear-connect rewrite all go
    through one writer. That writer stages the content in a sibling temp file that is chmod'd
    while still empty and then renamed over the target, so the key is never on disk under a
    umask-derived mode such as `0644`, a file left `0644` by an older build is replaced rather
    than patched, the rewrite is atomic for the reload poll, and a failed write leaves the
    previous file intact.
  - Resolution when building runtime config: non-empty `config.json` `linear_api_key`,
    else the first project's non-empty `linear_api_key`, else process env
    `LINEAR_API_KEY`. The env var is a fallback only (`Schema.finalize_settings/1`);
    dashboard Connect and `POST /api/v1/linear` persist the durable file key.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `project_slug` (string)
  - Required for dispatch when `tracker.kind == "linear"`.
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer or string integer)
  - Default: `30000`
  - Changes should be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/cymphony_workspaces`
  - `~` and strings containing path separators are expanded.
  - Bare strings without path separators are preserved as-is (relative roots are allowed but
    discouraged).

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, optional)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, optional)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, optional)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, optional)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, optional)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Non-positive values should be treated as invalid and fall back to the default.
  - Changes should be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Agent-neutral settings shared by every coding-agent backend.

Fields:

- `kind` (string, `"claude"` | `"codex"` | `"antigravity"`)
  - Default: `"claude"`
  - Selects the coding-agent CLI adapter used for dispatched sessions.
  - Unknown values are a validation error.
- `model` (string or null)
  - Default: null (the agent CLI's own default model).
  - Passed through to the agent CLI verbatim (`--model` for Claude Code and
    Antigravity, `-m` for Codex).
  - Not validated against a model list; invalid values surface as run failures.
- `effort` (string or null)
  - Default: null (the agent CLI's own default effort).
  - Passed through verbatim (`--effort` for Claude Code,
    `-c model_reasoning_effort=…` for Codex). Antigravity never receives
    `--effort`: CLI Proxy slugs already encode reasoning (`-high`, `-medium`)
    and `agy` rejects the flag on those models.
- `max_concurrent_agents` (integer or string integer)
  - Default: `10`
  - Changes should be re-applied at runtime and affect subsequent dispatch decisions.
- `max_retry_backoff_ms` (integer or string integer)
  - Default: `300000` (5 minutes)
  - Changes should be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
  - Maximum wall-clock time for one agent turn, regardless of agent kind.
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - Milliseconds of agent-event silence tolerated before the stall watchdog terminates the
    session and queues a retry (Section 8.5). It exists to catch runs that hang without ever
    failing — a foreground server command (`mix phx.server`, `npm run dev`), an interactive
    prompt waiting on stdin, a wedged network read — which stop emitting events but never exit,
    so nothing else in the service would ever reclaim the slot.
  - If `<= 0`, stall detection is disabled.
  - Config-store write-through: a per-project `stall_timeout_ms` in `~/.cymphony/config.json`
    is generated into this field. Only a positive integer is honored; a missing key, `0`, a
    negative number, a float, or a stringified number generates the `300000` default instead,
    so a typo can neither silently disable the watchdog nor produce front matter that fails
    schema validation. Long-running builds should raise the value rather than disable it.

#### 5.3.6 `claude` (object)

Claude Code CLI-specific settings. Only consulted when `agent.kind` is `"claude"`.

For Claude Code-owned config values such as `permission_mode` and `allowed_tools`, supported
values are defined by the targeted Claude Code CLI version; treat them as pass-through.

- `command` (string shell command)
  - Default: `claude`
  - Launched per turn as `claude --bare -p <prompt> …` with `--resume <session_id>` on
    continuation turns.
- `permission_mode` (Claude Code permission mode value)
  - Default: `acceptEdits`.
- `allowed_tools` (comma-separated string)
  - Default: `Bash,Read,Edit`.
- `output_format` (string, `text` | `json` | `stream-json`)
  - Default: `stream-json`.
- `fallback_model` (string or null)
  - Default: null. Passed as `--fallback-model`.
- `max_turns` (integer or null)
  - Default: null. Claude CLI's internal turn cap (`--max-turns`), distinct from the
    orchestrator-level `agent.max_turns` continuation loop.
- `max_budget_usd` (decimal or null)
  - Default: null. Passed as `--max-budget-usd`.
- `bare_mode` (boolean)
  - Default: true. Passed as `--bare`.
- `extra_args` (list of strings, string, or null)
  - Default: null. See Section 5.3.9.
- `provider` / `providers` (string / list of strings)
  - Auth aliases resolved via shell functions or the config `providers` map; see Section 6.
  - Provider env capture keeps `ANTHROPIC_*`, `CLAUDE_CODE_*`, and `API_TIMEOUT` variables.

#### 5.3.7 `codex` (object)

Codex CLI-specific settings. Only consulted when `agent.kind` is `"codex"`.

- `command` (string shell command)
  - Default: `codex`
  - Launched per turn as `codex exec --json --skip-git-repo-check …`; continuation turns use
    `codex exec resume <session_id> …`.
- `sandbox` (string, `read-only` | `workspace-write` | `danger-full-access`)
  - Default: `workspace-write`.
  - Always passed as `-c sandbox_mode="<value>"` (the `-s` shorthand is not accepted by
    `codex exec resume`).
- `network_access` (boolean)
  - Default: true.
  - When true with the `workspace-write` sandbox, passes
    `-c sandbox_workspace_write.network_access=true`.
- `extra_args` (list of strings, string, or null)
  - Default: null. See Section 5.3.9. Emitted **before** the prompt, which stays the final
    positional argument of `codex exec`.
- `provider` / `providers` (string / list of strings)
  - Auth aliases, as for Claude, but env capture keeps `OPENAI_*`, `CODEX_*`, and
    `API_TIMEOUT` variables.

Completion conditions for a Codex turn: a `turn.completed` JSONL event is success; a
`turn.failed` event, missing terminal event, nonzero process exit, or turn timeout is failure.
Session identifiers come from the `thread.started` event's `thread_id`. If `thread.started` is
missing, a later event's `thread_id` is accepted. A `turn.completed` event with no
`item.completed` agent message is still success (`result` may be null). Non-JSON and blank
lines (including mixed stderr noise on the merged stream) are ignored.

#### 5.3.8 `antigravity` (object)

Antigravity CLI-specific settings (Google Antigravity / `agy`, successor to Gemini CLI).
Only consulted when `agent.kind` is `"antigravity"`.

The binary is `run_spec.command || settings.command || "agy"` (empty string falls through,
same rule as Codex). `ANTIGRAVITY_CLI_BIN` / `AGY_CLI_BIN` are not read; operators override
via `antigravity.command`.

Headless invocation: `agy -p <prompt>` (`-p` aliases `--print` / `--prompt`). stdout is the
result; stderr is diagnostics. The runner merges stderr into stdout (`:stderr_to_stdout`) so
both land in the same line stream.

Fields:

- `command` (string shell command)
  - Default: `agy`
  - Required. Override the Antigravity CLI binary.
- `output_format` (string, `text` | `json` | `stream-json`)
  - Default: `stream-json`.
  - Passed as `--output-format`.
- `extra_args` (list of strings, string, or null)
  - Default: null. See Section 5.3.9.
- `skip_permissions` (boolean)
  - Default: `true`.
  - When true, passes `--dangerously-skip-permissions` (same spirit as Claude
    `acceptEdits`).
- `sandbox` (boolean)
  - Default: `false`.
  - When true, passes `--sandbox`.
- `new_project` (boolean)
  - Default: `true`.
  - When not exactly `false`, passes `--new-project`.
  - Without the flag `agy` ignores the cwd it was launched in and runs inside
    `~/.gemini/antigravity-cli/scratch`, so nothing an agent writes ever reaches the per-issue
    workspace and no pull request can be produced. The flag is therefore appended to **every**
    invocation Cymphony builds — fresh runs and `--conversation` resumes alike; it is accepted
    on both. Setting it to `false` is the escape hatch for an operator who has another way to
    anchor the cwd; any other value keeps the flag, because a typo here silently reintroduces
    the scratch-directory failure.
- `print_timeout` (string or null)
  - Default: null.
  - When a non-empty string, passed as `--print-timeout <value>`. Do not auto-wire
    `agent.turn_timeout_ms` to `--print-timeout`.
- `provider` / `providers` (string / list of strings)
  - Auth aliases, as for Claude/Codex. Env capture keeps `ANTIGRAVITY_*`, `GOOGLE_*`,
    `GEMINI_*`, and `API_TIMEOUT` variables. Fallback keys: `GOOGLE_API_KEY`,
    `GEMINI_API_KEY`.

Argv (space-joined; prompt, session id, and model are shell-escaped):

```text
<cmd> -p <escaped prompt> --output-format <output_format>
  [--model <escaped model>]          when model is a non-empty binary
  [--conversation <escaped id>]      when session_id is a non-empty binary
  [--dangerously-skip-permissions]   when skip_permissions is true
  [--sandbox]                        when sandbox is true
  [--print-timeout <print_timeout>]  when print_timeout is a non-empty binary
  [--new-project]                    unless new_project is exactly false
  [--log-file <escaped path>]        when the run's workspace is a non-empty binary
  <extra_args>
```

Resume uses `--conversation <conversation_id>` only. Never emit `-c` / `--continue`
(those resume the last session in cwd and would cross-pollute issues). Do not emit
`--resume`. Do not invent MCP flags (`--mcp-config` is not in the official headless
table); operators may pass extras via `extra_args`.

`--log-file` points at the workspace's **sibling** `.agy-<issue>.log`
(`Path.expand(Path.join([workspace, "..", ".agy-" <> Path.basename(workspace) <> ".log"]))`).
On stdout the CLI reports only a generic "Agent execution terminated due to error."; the actual
cause (HTTP 400/429, auth failure) goes exclusively to its own log file, which otherwise lands
in `~/.gemini/antigravity-cli/log/cli-<timestamp>.log` where nothing correlates it to an issue.
The log must sit *beside* the workspace, never inside it: the workspace root is the cloned repo
root and the prompt instructs the agent to commit and push, so a log in the tree — which grows
and appends across retry attempts — lands in the pull request. The `..` is resolved lexically
(no filesystem access), so under SSH remoting the path names the remote workspace's sibling; an
absent or empty workspace omits the flag rather than logging to a root-level path. The
retention sweep removes stale `.agy-*.log` files under the workspace root along with stale
workspaces, running no `before_remove` hook for them (the hook runs shell in a workspace
directory).

Output parse contract:

- `stream-json` (NDJSON): decode each line; emit `%{event: :stream_event, payload, raw, timestamp}`
  for every decoded map. Fold:
  - `event=="init"` → `session_id = conversation_id` (top-level or `init.conversation_id`)
  - `event=="step_update"` → append `step_update.text_delta` (binaries only) onto
    `last_message`; keep the latest `step_update.usage` map
  - `event=="result"` → take `result` (or the event itself); `session_id` from
    `conversation_id`; `result_text` from `response`; `usage` from `usage`; `status`
    from `status`
  - After fold: if a completed map has `status` present and `status != "SUCCESS"` →
    `{:error, {:turn_failed, error}}`; if a completed map is present →
    `{:ok, %{session_id, result, usage, raw}}`; else
    `{:error, {:no_result_in_stream, joined}}`.
- `json`: last trimmed line that starts with `{` and ends with `}` (same find-last-json
  as Claude). Decode. `status` present and not `SUCCESS` → `{:error, {:turn_failed, error}}`;
  else `{:ok, %{session_id: conversation_id, result: response, usage, raw}}`. Errors:
  `{:no_json_output, joined}`, `{:json_decode_failed, err, line}`. The json path emits
  no `:stream_event`.
- `text` (anything else): `{:ok, %{session_id: nil, result: joined, usage: nil, raw: joined}}`.

`json` envelope fields: `conversation_id`, `status`
(`SUCCESS|ERROR|CANCELED|INTERRUPTED|INVALID|WAITING|RUNNING`), `response`, `error?`,
`duration_seconds`, `num_turns`, `usage:{input_tokens,output_tokens,thinking_tokens,cache_read_tokens,total_tokens}`.

Normalized usage keeps only `input_tokens`, `output_tokens`, and `total_tokens`
(integer-or-zero). Missing `total_tokens` is `input + output`. `thinking_tokens` and
cache fields are dropped from the normalized map. Non-JSON lines are ignored and do
not fail the turn. An unknown `--model` slug exits nonzero with `status ERROR`.
`--effort` is never emitted, even when `agent.effort` is set: agy rejects it on
CLI Proxy / custom slugs, and thinking is already in the model name.

#### 5.3.9 `extra_args` (all three agent sections)

Pass-through CLI flags for the agent binary. Present on `claude`, `codex`, and `antigravity`
with identical semantics, so an operator can reach a flag Cymphony does not model without
waiting for the flag to be modelled.

Accepted shapes in `WORKFLOW.md`:

- A **list of strings** — each item is shell-escaped individually and appended in order. This
  is what the config-store generator emits, so an argument containing spaces stays one
  argument.
- A **single string** — trusted operator input, appended unescaped as one trailing fragment.
  It may carry several flags and its own quoting. Retained so a hand-authored `WORKFLOW.md`
  written against the original string-only form keeps parsing.
- `null` (default) — nothing is appended.

A non-binary member of the list is dropped rather than failing the run; any other shape fails
schema validation. Placement is per adapter: Claude and Antigravity append after the modelled
flags, Codex appends before the prompt because `codex exec` takes the prompt as its final
positional argument.

Trust boundary: `extra_args` is operator-authored, hand-edited configuration and is treated as
trusted. The string form is interpolated into the launch script raw — it can carry its own
quoting, which also means it can carry arbitrary shell — and nothing validates that a flag
makes sense for its CLI: a codex flag that expects a value will swallow the prompt positional.
Escaping the list form is a formatting service, not a security boundary. Per-issue overrides
(an `agent:` label, a queue pin, a dashboard restart) run **without** `extra_args`, exactly as
they run without provider keys — only the project's configured kind receives them.

Config-store write-through: a per-project `extra_args` key in `~/.cymphony/config.json` is
generated into the **active kind's** section only — like `provider`/`providers`, these are
per-backend flags and a project pinned to `codex` must not inherit an `antigravity` list. Two
shapes are accepted on a `projects[]` entry:

```json
"extra_args": {"antigravity": ["--new-project"], "codex": ["--full-auto"]}
"extra_args": ["--add-dir", "/srv/shared"]
```

The map form is keyed by agent kind and only the active kind's entry is emitted. The bare-list
form is the convenience spelling for the active kind. Only a list of strings is honored; a bare
string, a number, a list with a non-string member, or a map whose active-kind entry is not a
string list is ignored **and logged as a warning**, because unlike a numeric typo a mistyped
escape hatch produces no visible symptom. A map with no entry for the active kind is the normal
case and is not a warning. Nothing invalid is written into front matter, so a typo can never
produce a `WORKFLOW.md` that fails schema validation and takes the project down.

There is no CLI flag, API route, or dashboard control for `extra_args`; like `stall_timeout_ms`
it is a hand-edited config key. The same is true of the antigravity-only `new_project` key,
whose default (`true`) is omitted from the generated front matter entirely — only an explicit
`false` is written through.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables must fail rendering.
- Unknown filters must fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime may use a minimal default prompt
  (`You are working on an issue from Linear.`).
- Workflow file read/parse failures are configuration/validation errors and should not silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Source Precedence and Resolution Semantics

Configuration precedence:

1. Workflow file path selection (runtime setting -> cwd default).
2. YAML front matter values.
3. Environment indirection via `$VAR_NAME` inside selected YAML values.
4. Built-in defaults.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.

### 6.2 Dynamic Reload Semantics

Dynamic reload is required:

- The software should watch `WORKFLOW.md` for changes.
- On change, it should re-read and re-apply workflow config and prompt template without restart.
- The software should attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, claude settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not required to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) may
  require restart unless the implementation explicitly supports live rebind.
- Implementations should also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads should not crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.api_key` is present after `$` resolution.
- `tracker.project_slug` is present when required by the selected tracker kind.
- `claude.command` is present and non-empty.

### 6.4 Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.

- `tracker.kind`: string, required, currently `linear`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR`; durable source is `~/.cymphony/config.json`
  `linear_api_key` (generated into this field). `LINEAR_API_KEY` is env fallback
  only when the file has no non-empty key (`tracker.kind=linear`)
- `tracker.project_slug`: string, required when `tracker.kind=linear`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path, default `<system-temp>/cymphony_workspaces`
- `worker.ssh_hosts` (extension): list of SSH host strings, optional; when omitted, work runs
  locally
- `worker.max_concurrent_agents_per_host` (extension): positive integer, optional; shared per-host
  cap applied across configured SSH hosts
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.kind`: string, `claude` | `codex` | `antigravity`, default `claude`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `agent.stall_timeout_ms`: integer, default `300000` (5m); generated from the project's optional
  `stall_timeout_ms` config-store key (positive integer only)
- `claude.command`: shell command string, default `claude`
- `claude.approval_policy`: Claude Code approval policy value, default implementation-defined
- `claude.permission_mode`: Claude Code permission mode value, default implementation-defined
- `claude.allowed_tools`: list of strings, default implementation-defined
- `claude.turn_timeout_ms`: integer, default `3600000`
- `claude.read_timeout_ms`: integer, default `5000`
- `claude.extra_args` / `codex.extra_args`: list of strings, string, or null (Section 5.3.9);
  generated from the project's optional `extra_args` config-store key for the active kind only
- `antigravity.command`: shell command string, default `agy`
- `antigravity.output_format`: `text` | `json` | `stream-json`, default `stream-json`
- `antigravity.extra_args`: list of strings, string, or null (Section 5.3.9)
- `antigravity.skip_permissions`: boolean, default `true`
- `antigravity.sandbox`: boolean, default `false`
- `antigravity.new_project`: boolean, default `true`; generated from the project's optional
  `new_project` config-store key, and only when that key is exactly `false`. In a hand-authored
  front matter the field casts leniently: `true`/`false` and Ecto's string spellings parse
  normally, while any other value (`0`, `"no"`, `"off"`) is logged and treated as unset —
  falling back to the default `true` — rather than failing `Schema.parse/1` and taking the
  project down over a typo'd boolean
- `antigravity.print_timeout`: string or null
- `antigravity.provider` / `antigravity.providers`: string / list of strings
- `server.port` (extension): integer, optional; enables the optional HTTP server, `0` may be used
  for ephemeral local bind, and CLI `--port` overrides it

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker may continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state and passes the native Todo dependency gate, the worker
  should start another turn on the same live coding-agent thread in the same workspace, up to
  `agent.max_turns`. A fresh Todo with any non-terminal or unknown blocker ends the worker's turn
  loop. Running-state reconciliation also retires that worker without deleting its workspace or
  counting the issue complete; dispatch can resume when its blockers become terminal. In-progress
  phases retain their existing eligibility even when blockers remain open.
- The first turn should use the full rendered task prompt.
- Continuation turns should send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Claude Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are required before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (no durable orchestrator DB required).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval should be updated when workflow config changes are re-applied.

**Durable pause.** Pause is a persisted per-project preference, not just process state. The
orchestrator seeds `paused` during initialization from the project's `dispatch_paused` boolean in
the operator config store (falling back to a top-level key for a legacy flat config, and to `false`
when unreadable or absent). Seeding must happen **before** the immediate first tick is scheduled, so
a project persisted as paused cannot dispatch once and then pause; the first poll already observes
the operator's choice. A config store that exists but cannot be read or parsed loses a persisted
pause, so that case must be logged; a config store that is simply absent (legacy WORKFLOW.md mode)
has no flag to lose and boots unpaused silently. Pause/resume from any surface
(`POST /api/v1/pause`, the dashboard's global Pause/Resume, the per-project header toggle) writes
the flag for every project in scope. An `:all` fan-out must reach **every** in-scope orchestrator
even when one project's persist fails — stopping halfway leaves the rest dispatching — and report
the first error afterwards. A per-project scope must stay keyed by the requested project on every
path, including the legacy single-orchestrator fallback: a `nil` project name means "all projects"
to the config writers, so passing it there paused the whole fleet on disk. The periodic
runtime-config refresh never touches `paused`, so a seeded value survives config reloads.

The write-side mirrors the seed on the absent-config-store case: with **no** config store at all
there is nothing durable to write and nothing was lost, so pause/resume report success (a failure
there would fail every toggle of a pause that worked, in the one mode where it can never fail). A
config store that exists and cannot be read, parsed, or written **is** a failure — that one really
does lose the flag — and must be reported as such rather than as a plain success, because the
orchestrators flipped and the next daemon restart silently undoes it.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from the tracker using active states (always fetch,
   including when paused and when `available_slots == 0`). Fetch or config
   errors keep last `waiting`.
4. After a successful fetch, filter waiting-eligible issues and run
   `Queue.reconcile` (sticky operator order). Assign `State.waiting`. Do not
   claim waiting ids. Do not re-sort via `Dispatch.sort_for_dispatch` once a
   saved or reconciled order exists. Canceled / no-longer-eligible cards drop
   off; newly Todo issues appear. Dashboard Refresh uses this same path.
5. When **not** paused, dispatch from the **leftmost** waiting card while
   global slots remain (Section 8.2). Skip a head only when per-state or
   per-host slots are full. Paused ticks refresh `waiting` and must not spawn.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

Waiting-board membership and dispatch order are **sticky operator order**, not a per-tick
re-sort. `Dispatch.sort_for_dispatch/1` is **INITIAL ORDER only** (no saved `queue_order`
yet). Subsequent ticks use `Queue.reconcile`. Do not write Cymphony ranks or queue order
back to Linear (no Linear GraphQL writes).

Cymphony rank is the left-to-right then wrap (row-major) index on the board: `0` = next
slot after a running session finishes, larger = later. This rank is **not** Linear
priority. Linear priority numbers are `1` = Urgent, `2` = High, `3` = Medium, `4` = Low,
`0` / `nil` = none.

#### Waiting membership

An issue is waiting-eligible (dispatch-ready, not currently running) only if all are true:

- It has `id`, `identifier`, `title`, and `state` (`candidate_issue?`).
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- It is not in `retry_attempts` (retry/backoff stays its own list **below** In Progress;
  Section 8.4).
- Blocker rule for `Todo` state passes:
  - If the issue state is `Todo`, do not include it when any blocker is non-terminal.

Do not put Backlog, canceled, or blocked issues on the board. Hide the board when
`waiting` is empty (no empty columns). Do not claim waiting ids.

Global / per-state / per-host slot checks are **not** membership filters; they apply when
walking `waiting` to dispatch (below).

#### INITIAL ORDER (no saved order yet)

No saved order means `queue_order` is missing or never written (`nil`). Treat `[]` after a
prior persist as **empty-saved** (every eligible arrival is NEW).

First reconcile with no saved order:

1. `order = Dispatch.sort_for_dispatch(eligible)`
   - Linear `priority` ascending (`1..4` preferred; `0` / `nil` / unknown sort last)
   - then oldest `created_at`
   - then `identifier` lexicographic tie-breaker
2. Seed `queue_priority_seen` from current priorities.
3. Persist that `queue_order`.

`choose_issues` must not re-sort via `Dispatch.sort_for_dispatch` once a saved or
reconciled order exists.

#### Sticky reconcile (`Queue.reconcile`)

`issue_key` = `identifier` if present else `id`.
`linear_rank(p)` = `p` when `p` in `1..4`, else `5` (none). Both sides of a raise
comparison use `linear_rank`, so `0`/`nil` → `2` is a raise.

On subsequent ticks:

1. Drop keys that left the eligible set. Keep saved relative order for remaining keys.
2. **LINEAR RAISE** — for each remaining key whose
   `linear_rank(current) < linear_rank(priority_seen[key])`, re-insert **that one card
   only** (do not reshuffle cards whose Linear priority did not change):
   - Urgent (`1`) at index `0` (far left)
   - High (`2`) before the first remaining card with `linear_rank > 2`
   - Medium (`3`) before the first remaining card with `linear_rank > 3`
   - Low (`4`) before the first remaining card with `linear_rank > 4`
3. **LINEAR LOWER** (rank increases or stays equal) never moves the card. A High → Low
   change after a drag does not move the card.
4. **NEW** keys (not in saved `queue_order`) append at the right, unless Linear
   `priority == 1` (Urgent), which inserts at index `0`.
5. After reconcile, persist `queue_order` + `queue_priority_seen` if either changed.

**DRAG:** the operator permutes the waiting list. Persist the full identifier/id order
per project. Drag wins until **that** issue's Linear priority changes (a raise re-inserts
that card only). Persist across daemon restart.

#### Dispatch consumes leftmost waiting

`maybe_dispatch` always fetches (including when paused and when `available_slots == 0`). After
a successful fetch, filter eligible, `Queue.reconcile`, assign `State.waiting`. When not
paused, walk leftmost:

- If global slots are `0`, stop dispatching (keep remaining `waiting`).
- If the head fails **only** `state_slots_available?` or `worker_slots_available?`, skip
  that card (leave it on `waiting`) and try the next.
- If `should_dispatch`, spawn (claim only then) and drop the card from `waiting`.

Paused ticks still fetch and rebuild `waiting`, but must not spawn. Fetch/config errors keep last
`waiting`. Next free slot starts the leftmost waiting card.

#### Per-issue run spec resolution

At dispatch time, the orchestrator resolves the session's agent kind, model, reasoning effort,
and (optionally) provider for the issue. Field-level precedence, highest first:

1. **Queue pin** — persisted `queue_pins[issue_key]` `agent_kind` / `model` / `effort`
   (no provider). Overlay in orchestrator `dispatch_run_spec/3`; do **not** change
   `RunSpecResolver`. Pins apply when the issue is dispatched **from the waiting list**.
   Empty / `"keep"` omits the field. Deleting all three fields removes that pin entry.
   Unknown `agent_kind` is ignored (same as labels). Card Edit persists the pin and must
   **not** kill anything (the issue is not running).
2. **Linear labels** — `agent:<kind>`, `model:<name>`, `effort:<level>`, `provider:<alias>`.
   Labels arrive downcased from the tracker adapter. Duplicate prefixes pick the sorted-first
   value with a warning; empty values are ignored.
3. **Description directive** — the first line in the issue description of the form
   `cymphony: key=value key=value …` with keys in `agent|model|effort|provider`. Values match
   `[A-Za-z0-9._/-]+`; `agent`/`effort` values are lowercased. Unknown keys are ignored.
4. **Project config** — `agent.kind`, `agent.model`, `agent.effort`; provider comes from the
   active kind's rotation (Section 8.3).

Precedence is **pin > labels > directive > config**.

Rules:

- `agent` must be a known kind; unknown kinds log a warning and fall through to the next
  source (never fail dispatch). `model`/`effort`/`provider` are pass-through.
- The resolved spec is **pinned for the whole run attempt**: multi-turn resume never
  re-resolves, so an agent-kind switch mid-session is impossible.
- Retries re-resolve from the freshly polled issue (plus any still-persisted queue pin),
  so label edits take effect on the next attempt.
- An explicit issue-level `provider` bypasses rotation for that issue. When a label switches
  the agent kind away from the project default, the provider falls back to that kind's
  configured `provider` (rotation lists are per-kind). Queue pins never set provider.
- The dispatch log line records `agent=… model=… effort=… source=pin|labels|directive|config`.
- Known kinds include `claude`, `codex`, and `antigravity`. Labels such as
  `agent:antigravity` and a description directive `cymphony: agent=antigravity`
  are valid once `agent.kind` accepts that union.
- Dashboard/API `set_issue_run_spec` may pin `:provider`, `:model`, `:effort`,
  and `:agent_kind` (all optional; empty / `"keep"` skips). A restart kills the
  running session and redispatches with those overrides for the next attempt. It
  does **not** write `queue_pins`. When an issue is dispatched from `waiting`, a
  queue pin wins over Keyword overrides from `set_issue_run_spec`.

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

Optional SSH host limit:

- When `worker.max_concurrent_agents_per_host` is set, each configured SSH host may run at most
  that many concurrent agents at once.
- Hosts at that cap are skipped for new dispatch until capacity frees up.

### 8.4 Retry and Backoff

Retry/backoff remains a **separate** list below In Progress. Do not put `retry_attempts`
entries on the waiting board (`section.queue-board`). Board membership excludes
`retry_attempts` (Section 8.2).

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

0. If dispatch is paused, **hold** the entry instead of handling it (below).
1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Paused retries (hold semantics):

- A retry timer that fires while `paused` neither dispatches nor reschedules. Rescheduling would
  add `+1` to `attempt` once per backoff cycle for the whole pause, inflating the delay and
  spending the `max_retry_attempts` budget on work that never ran.
- The entry stays in `retry_attempts` with its `attempt`, `failures`, `identifier` and `error`
  unchanged, no armed timer, and its original `due_at_ms` — so it stays visible in the retry list
  and reads as due now.
- Repeated firings while paused are idempotent; a stale `retry_token` is still ignored.
- Fresh failures (crash, stall, spawn failure) that occur while paused still record a retry entry
  normally — pause suppresses re-litigating an existing backoff, not the recording of a failure.
- `resume` re-arms every held entry immediately (0 ms, fresh `retry_token`) with the same
  `attempt`, so a held retry becomes eligible on the next tick without a fresh backoff wait.
- The explicit "retry now" operator action is an override and still dispatches while paused; hold
  semantics apply to the timer-driven backoff loop only.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_claude_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms > agent.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.
- The timeout is per project: `agent.stall_timeout_ms` in the project's `WORKFLOW.md`, generated
  from the optional `stall_timeout_ms` key on that project in `~/.cymphony/config.json`
  (Section 5.3.5).

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized path; the current config layer expands path-like values and preserves
  bare relative names)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 Optional Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations may populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations may remove the partially
  prepared directory.
- Reused workspaces should not be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path must stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines the language-neutral contract for integrating a coding agent app-server.

Compatibility profile:

- The normative contract is message ordering, required behaviors, and the logical fields that must
  be extracted (for example session IDs, completion state, approval handling, and usage/rate-limit
  telemetry).
- Exact JSON field names may vary slightly across compatible app-server versions.
- Implementations should tolerate equivalent payload shapes when they carry the same logical
  meaning, especially for nested IDs, approval requests, user-input-required signals, and
  token/rate-limit metadata.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `claude.command`
- Invocation: `bash -lc <claude.command>`
- Working directory: workspace path
- Stdout/stderr: separate streams
- Framing: line-delimited protocol messages on stdout (JSON-RPC-like JSON per line)

Notes:

- The default command is `claude`.
- Approval policy, cwd, and prompt are expressed in the protocol messages in Section 10.2.

Recommended additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Handshake

The client must send these protocol messages in order:

Illustrative startup transcript (equivalent payload shapes are acceptable if they preserve the same
semantics):

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cymphony","version":"1.0"},"capabilities":{}}}
{"method":"initialized","params":{}}
{"id":2,"method":"thread/start","params":{"approvalPolicy":"<implementation-defined>","sandbox":"<implementation-defined>","cwd":"/abs/workspace"}}
{"id":3,"method":"turn/start","params":{"threadId":"<thread-id>","input":[{"type":"text","text":"<rendered prompt-or-continuation-guidance>"}],"cwd":"/abs/workspace","title":"ABC-123: Example","approvalPolicy":"<implementation-defined>","sandboxPolicy":{"type":"<implementation-defined>"}}}
```

1. `initialize` request
   - Params include:
     - `clientInfo` object (for example `{name, version}`)
     - `capabilities` object (may be empty)
   - If the targeted Claude Code app-server requires capability negotiation for dynamic tools, include the
     necessary capability flag(s) here.
   - Wait for response (`read_timeout_ms`)
2. `initialized` notification
3. `thread/start` request
   - Params include:
     - `approvalPolicy` = implementation-defined session approval policy value
     - `sandbox` = implementation-defined session sandbox value
     - `cwd` = absolute workspace path
     - If optional client-side tools are implemented, include their advertised tool specs using the
       protocol mechanism supported by the targeted Claude Code app-server version.
4. `turn/start` request
   - Params include:
     - `threadId`
     - `input` = single text item containing rendered prompt for the first turn, or continuation
       guidance for later turns on the same thread
     - `cwd`
     - `title` = `<issue.identifier>: <issue.title>`
     - `approvalPolicy` = implementation-defined turn approval policy value
     - `sandboxPolicy` = implementation-defined object-form sandbox policy payload when required by
       the targeted Claude Code app-server version

Session identifiers:

- Read `thread_id` from `thread/start` result `result.thread.id`
- Read `turn_id` from each `turn/start` result `result.turn.id`
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client reads line-delimited messages until the turn terminates.

Completion conditions:

- `turn/completed` -> success
- `turn/failed` -> failure
- `turn/cancelled` -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it should issue another `turn/start`
  on the same live `threadId`.
- The app-server subprocess should remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Line handling requirements:

- Read protocol messages from stdout only.
- Buffer partial stdout lines until newline arrives.
- Attempt JSON parse on complete stdout lines.
- Stderr is not part of the protocol stream:
  - ignore it or log it as diagnostics
  - do not attempt protocol JSON parsing on stderr

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event should
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `claude_app_server_pid` (if available)
- optional `usage` map (token counts)
- payload fields as needed

Important emitted events may include:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation should document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events must not leave a run stalled indefinitely. An
  implementation should either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime should
  be handled according to their extension contract.
- If the agent requests a dynamic tool call (`item/tool/call`) that is not supported, return a tool
  failure response and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation may expose a limited set of client-side tools to the app-server session.
- Current optional standardized tool: `linear_graphql`.
- If implemented, supported tools should be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Claude Code app-server version.
- Unsupported tool names should still return a failure result and continue the session.

`linear_graphql` extension contract:

- Purpose: execute a raw GraphQL query or mutation against Linear using Cymphony's configured
  tracker auth for the current session.
- Availability: only meaningful when `tracker.kind == "linear"` and valid Linear auth is configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` must be a non-empty string.
- `query` must contain exactly one GraphQL operation.
- `variables` is optional and, when present, must be a JSON object.
- Implementations may additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Cymphony workflow/runtime config; do
  not require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.

Illustrative responses (equivalent payload shapes are acceptable if they preserve the same outcome):

```json
{"id":"<approval-id>","result":{"approved":true}}
{"id":"<tool-call-id>","result":{"success":false,"error":"unsupported_tool_call"}}
```

Hard failure on user input requirement:

- If the agent requests user input, fail the run attempt immediately.
- The client detects this via:
  - explicit method (`item/tool/requestUserInput`), or
  - turn methods/flags indicating input is required.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `claude.read_timeout_ms`: request/response timeout during startup and sync requests
- `claude.turn_timeout_ms`: total turn stream timeout
- `agent.stall_timeout_ms`: enforced by orchestrator based on event inactivity (the key lives
  under `agent`, not `claude` — see §5 and §8.5)

Error mapping (recommended normalized categories):

- `claude_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start app-server session.
4. Forward app-server events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

### 10.8 Harness stdout streaming

The agent runner emits live CLI stdout incrementally so a dashboard can tail a
session without flooding LiveView or ingesting raw lines into orchestrator
`log_events`.

Pipeline:

1. `Agent.Runner.collect_output` emits `%{event: :harness_stdout, raw, timestamp}`
   after each completed stdout line (`{:eol, chunk}`) and for a leftover buffer
   on exit 0. `raw` is truncated to 2048 bytes. `{:noeol, _}` chunks stay
   buffered and are not emitted. `parse_output` still runs only after a
   successful (exit 0) process; a nonzero exit is `{:agent_exit, status, tail}`
   with no parse. Adapter `:stream_event` emissions stay post-exit (or still go
   through `on_message` if an adapter later streams parse).
   `tail` is a **bounded tail of everything the CLI printed**, not just the
   unterminated leftover buffer: the newest complete lines plus any leftover,
   each stripped of ANSI escapes and control bytes, blank lines dropped, capped
   at 20 lines and then at 2048 bytes (truncated from the back, never mid
   codepoint). A CLI that rejects its arguments prints one newline-terminated
   error line and exits, so reporting only the leftover buffer surfaced
   `{:agent_exit, 1, ""}` in the retry queue and in the tracker abandonment
   comment. The tail is ordered **newest line first**, and the byte cap keeps
   the head: every surface that renders it truncates from the front (§4.1.7),
   so chronological order pushed the CLI's own error line — the last thing it
   printed — past every cut on any turn with more than a line or two of output,
   which for a streaming agent CLI is every turn. Sanitizing is applied to the
   retained lines only, not to the whole accumulated transcript. The harness
   contract is unchanged: a leftover buffer on a nonzero exit is still not
   emitted as `:harness_stdout`.
   The tail is also **redacted**. Bounding, sanitizing, and redacting live in
   one shared helper — `Agent.failure_excerpt/1` (newest 20 lines, 2048 bytes,
   each line capped at 8 KB *before* the regexes run: redaction cost is
   superlinear in line length and a port line can be a megabyte) — which the
   runner's failure tail delegates to, so the retry entry, `/api/v1/state`, the
   dashboard, and the tracker abandonment comment are covered by construction.
   An agent CLI that dies mid-request routinely prints its own environment,
   which published live credentials — including the Linear API key the runner
   injects — to every one of those surfaces at once. The exit-0 failure paths
   get the same treatment: adapters must never join a raw transcript into an
   error payload. `no_result_in_stream`, `no_json_output`, and
   `json_decode_failed` carry `Agent.transcript_excerpt/1` (the same excerpt
   built from a chronological transcript), and a decoded `turn_failed` payload
   passes through `Agent.redact_payload/1`, which redacts every binary in the
   structure while leaving map keys alone. The live harness ring is redacted
   too — `:harness_stdout` lines after their 2048-byte slice, because
   `GET /api/v1/:issue/harness` and the dashboard pane carry the same bytes off
   the box. The on-disk debug transcript (`~/.cymphony/log/cymphony.log.N`) is
   deliberately **not** redacted: it never leaves the host, and an operator
   debugging an auth failure needs the real bytes. Shapes replaced with
   `[REDACTED]`:
   - assignments — `NAME=value`, `NAME => value`, `NAME: value`,
     `"NAME": "value"`, `"NAME" => "value"` — whose name has a whole
     `_`/`-`/`.` separated segment matching `KEY`, `TOKEN`, `SECRET`,
     `PASSWORD`, `PASSWD`, `PAT`, `CREDENTIAL`, `AUTHORIZATION`, or `COOKIE`
     (case-insensitively, plurals included), a camelCase spelling of one
     (`apiKey`, `authToken`, `accessToken`, `refreshToken`, `clientSecret`,
     `privateKey`, …), or a compound `PWD` (`DB_PWD`; a bare `PWD` is the
     shell's working directory). The name is kept: the diagnostic still says
     which variable was involved. Quoted forms are consumed first because their
     values may contain spaces, and each pass refuses to re-consume an earlier
     pass's `[REDACTED]`. Two carve-outs keep diagnostics readable: the bare
     `NAME: value` form requires a **compound** name, so
     `token: rate limit exceeded`, `Unexpected token: '<'`, and
     `KeyError: key: :model` survive intact (`NAME=value` and the quoted forms
     still accept a single segment, so `MONKEY=banana` relies on the
     whole-segment rule as before); and a name suffixed `_PATH`, `_FILE`,
     `_DIR`, `_ID`, or `_NAME` keeps its value — `SSH_KEY_PATH=/home/…` names a
     location, not a secret.
   - `Authorization` and `Cookie` headers, consumed to end of line, with or
     without a scheme — `Bearer`, `Basic`, or none — because the scheme word is
     not the secret.
   - bare vendor-prefixed credentials anywhere in the line, case-insensitively:
     `sk-…`, `lin_api_…`, `gh[pousr]_…`, `github_pat_…`, `xox<a>-…`, `AIza…`,
     `ya29.…`, `1//…` (Google OAuth refresh), JWTs (three dot-joined base64url
     segments starting `eyJ`), `AKIA…`, `npm_…`, `hf_…`.

   This is a redactor, not a secret scanner: an opaque high-entropy string with
   no name and no known prefix still passes through, and ordinary output — URLs,
   code, hex identifiers, words that merely contain "key" — is left alone.
   Redaction runs inside the lazy pipeline, on the retained lines only.
2. `AgentRunner` does **not** forward `:harness_stdout` to the orchestrator. It
   calls `HarnessStream.append(issue_id, raw)` and may send
   `%{event: :harness_heartbeat, timestamp}` to the orchestrator at most once
   per 2000 ms per issue (stall detection only).
3. `HarnessStream` (GenServer + ETS) keeps a per-issue ring of at most 400
   newest lines (each truncated to 2048 bytes), with a monotonic `seq` starting
   at 1. `dropped` counts lines discarded by the ring. Broadcasts are coalesced:
   at most one broadcast per issue per 80 ms; each broadcast carries at most 40
   newly-appended lines since the last flush. The first append after a quiet
   period flushes immediately.
4. `ObservabilityPubSub.broadcast_harness/2` publishes a **map** (never a bare
   atom) on topic `observability:issue:<issue_id>:harness`:

   ```elixir
   %{event: :harness_stream, issue_id: String.t(), last_seq: non_neg_integer(),
     lines: [%{seq: pos_integer(), at: DateTime.t(), text: String.t()}],
     dropped: non_neg_integer()}
   ```

   Existing `subscribe` / `broadcast_update` / `subscribe_issue` /
   `broadcast_issue_update` still send the bare atom `:observability_updated`.
5. LiveView subscribes on session-row expand, snapshots the ring, and appends
   only lines with `seq` greater than the stored `last_seq` (cap 400). Collapse
   unsubscribes and drops the tail assign. A Follow/Paused toggle controls
   autoscroll. Expanding a row must not spawn a full presenter payload reload
   for harness ticks.
6. The orchestrator treats `:harness_heartbeat` as a timestamp-only stall poke:
   it updates `running_entry.last_agent_timestamp` and does **not**
   `append_log_event`, `notify_dashboard`, or `broadcast_issue_update`. The dashboard must
   not treat the resulting `last_event_at` movement as a change either (Section 13.7.1).
   `:harness_stdout` / `:harness_heartbeat` must never appear in the 50-event
   `log_events` ring. On every path that removes a running entry (success, kill,
   fail, abandon) the orchestrator calls `HarnessStream.drop(issue_id)`.

Public `HarnessStream` API: `start_link/1`, `append/2`, `snapshot/1`, `drop/1`.
`snapshot/1` returns `%{issue_id, last_seq, lines, dropped}` with `last_seq` 0
and `lines` `[]` when the issue is unknown.

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 Required Operations

An implementation must support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `tracker.kind == "linear"`:

- `tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `tracker.project_slug` maps to Linear project `slugId`
- Candidate issue query filters project using `project: { slugId: { eq: $projectSlug } }`
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination required for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types required by this specification.

A non-Linear implementation may change transport details, but the normalized outputs must match the
domain model in Section 4.

### 11.3 Normalization Rules

Candidate issue normalization should produce fields listed in Section 4.1.1.

Additional normalization details:

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

Recommended error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Tracker Writes (Important Boundary)

Cymphony does not require first-class tracker write APIs in the orchestrator.

- Ticket mutations (state transitions, comments, PR metadata) are typically handled by the coding
  agent using tools defined by the workflow prompt.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If the optional `linear_graphql` client-side tool extension is implemented, it is still part of
  the agent toolchain rather than orchestrator business logic.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- optional `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` should be passed to the template because the workflow prompt may provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

Required context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

Required context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs must go (stderr, file, remote sink, etc.).

Requirements:

- Operators must be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations may write to one or more sinks.
- If a configured log sink fails, the service should continue running when possible and emit an
  operator-visible warning through any remaining sink.

This implementation writes every sink under the config directory (`~/.cymphony` by default;
never a separately hardcoded home path), because a detached daemon has no terminal:

| Path | Written by | Contents |
|------|-----------|----------|
| `<config_dir>/log/cymphony.log.N` | `:logger_disk_log_h` (`type: :wrap`) | Full transcript, `debug` and up. Read back by `cymphony logs`. |
| `<config_dir>/daemon.log` | `:logger_std_h` (`type: :file`, `max_no_bytes`/`max_no_files`) | `warning` and up, plainly named and directly tailable. |
| `<config_dir>/daemon.out` | the `nohup` redirect of the background daemon | Raw stdout/stderr. This is a terminal capture (status TUI repaints), **not** a log; it exists so a startup crash that never reaches Logger is still recoverable. |

Rules:

- Installing a disk sink removes the default console handler, as before. Console behaviour is
  otherwise unchanged.
- Handler registration failure logs a warning through the remaining sink and startup continues.
- Both file handlers buffer, and the CLI halts the VM without unwinding it, so every exit path
  flushes Logger before `System.halt/1`. Without that, a startup failure leaves both files empty.
  This includes the release entrypoint's own unhandled-error handler, which is the **only**
  record of a crash in the shipped binary: it logs the reason and halts after the console
  handler has already been removed, so an unflushed halt there leaves the operator with a
  nonzero exit and nothing anywhere. There must be exactly one halt helper, and every
  `System.halt/1` call site must go through it.
- Both sink paths are overridable, and the test environment **must** override them. The
  application callback installs both handlers unconditionally at boot, so an unconfigured test run
  appends the whole suite's warning noise — raw agent stdout included — to the very `daemon.log`
  an operator tails, and rotates their real one out from under them. Test runs write to a
  build-local, ignored directory instead; a test that deliberately unsets an override must restore
  it, not delete it.

### 13.2.1 Background Daemon Lifecycle

`cymphony start` re-executes the running binary under `nohup` and waits for the daemon to write
`<config_dir>/cymphony.pid`.

- The executable path is resolved before anything is spawned, in order: the Burrito wrapper's
  exported path, the escript path, the launcher `progname` (never `erl`/`erlexec`), then
  `cymphony` on `PATH`. Each candidate must resolve to an executable file; a bare name must
  resolve through `PATH`. Burrito-wrapped releases boot the BEAM directly, so escript/progname
  cannot identify them and only the wrapper's exported path is correct.
- If no candidate resolves, the CLI **must** abort with an operator-readable error instead of
  emitting a `nohup` command with a blank or unqualified argv[0].
- The launch command **must** report the detached child's OS pid on a marked line, and the CLI
  **must** separate that line from the operator-facing launcher output. "No pidfile yet" is not
  evidence of failure — the daemon writes the pidfile itself, late in boot, and a Burrito binary
  decompresses its whole payload and deletes the previous version's install tree before the BEAM
  even starts — so *liveness of that pid*, not the clock, is what distinguishes a slow start from
  a dead one. A child that is already gone ends the wait immediately; otherwise the deadline is
  generous. Aborting a healthy-but-slow start with a nonzero exit invites a service wrapper to
  retry and bring up a second daemon on the same port, double-dispatching every issue.
- If the child exits, or no pidfile appears before the deadline, the CLI **must** report failure
  (nonzero exit) and include the launcher output plus a bounded, sanitized tail of
  `<config_dir>/daemon.out`, naming which of the two happened. Reporting success with an unknown
  PID hides a daemon that never started.
- That tail is read from a byte offset into a raw terminal capture, so it **must** be scrubbed of
  invalid UTF-8 before it is printed: the message goes to stderr, where invalid character data
  raises and replaces the diagnostic with a crash.
- The pidfile is the daemon's only liveness signal, so the daemon **must** write it only after it
  has actually reached the started state — configuration loaded, projects started, supervision tree
  up — and never as the first statement of the run. A pidfile written before startup makes
  "started in background (PID …)" a report that a process was *spawned*, not that it *booted*: an
  unreadable config, a missing workflow file, or a taken dashboard port all still read as success.
  Every non-started outcome must leave the pidfile absent so the launcher reports the failure with
  the daemon output tail. (A build whose application callback starts the supervision tree before
  handing off to the CLI already satisfies this ordering.)

### 13.3 Runtime Snapshot / Monitoring Interface (Optional but Recommended)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
should return:

- `running` (list of running session rows)
- each running row should include `turn_count`
- `waiting` (ordered compact rows for the sticky waiting board; name this key `waiting`,
  not `queued`)
  - `handle_call(:snapshot)` rows: `issue_id`, `identifier`, `issue`, `priority`, `state`,
    `created_at`, `agent_kind`, `model`, `effort` where `agent_kind` / `model` / `effort`
    are persisted `queue_pins` only (`null` if unpinned)
  - Presenter project rows add `waiting` (list) + `waiting_count`. Each payload row:
    `issue_identifier`, `issue_title`, `issue_url`, `issue_id`, `priority`, `state`,
    `created_at` (ISO8601), `agent_kind`, `model`, `effort`
  - Top-level `payload.counts.waiting` is the sum of project waiting lengths
    (`payload_counts(running, retrying, waiting)`). Default LiveView payload and snapshot
    fixtures include `waiting: []` and `counts.waiting`
  - `GET /api/v1/projects` stays running/retrying only. Do not add `waiting` to
    `StatusDashboard`
- `retrying` (list of retry queue rows)
- `claude_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

Recommended snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 Optional Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is optional and
implementation-defined.

If present, it should draw from orchestrator state/metrics only and must not be required for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events may include token counts in multiple payload shapes.
- `Tokens.extract_token_delta` takes the first integer token map found, in this
  order:
  1. `update[:usage]` / `update["usage"]` when that value itself is an integer
     token map (this is how `:turn_completed` from `Agent.Runner` counts)
  2. `payload["usage"]` / `payload[:usage]` when `payload` is `update[:payload]`
  3. `payload["type"]` in `["turn.completed", "turn/completed"]` → `payload["usage"]`
     (Codex JSONL)
  4. `payload["event"] == "result"` → `result["usage"]` or `payload["usage"]`
     (Antigravity result envelope)
  5. `payload["event"] == "step_update"` → `step_update["usage"]` (Antigravity
     mid-turn)
  6. Existing Claude paths (`params.msg…total_token_usage`, `tokenUsage.total`,
     `method == "turn/completed"`)
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- If `total_tokens` is missing, `total = input + output`. `thinking_tokens` is
  not added to output.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.
- Mid-turn Antigravity `step_update` usage and Codex stream-event
  `turn.completed` usage increment the running entry the same way.

Runtime accounting:

- Runtime should be reported as a live aggregate at snapshot/render time.
- Implementations may maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not required.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (Optional)

Humanized summaries of raw agent protocol events are optional.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 Optional HTTP Server Extension

This section defines an optional HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not required for conformance.
- The implementation may serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API must be observability/control surfaces only and must not become required for
  orchestrator correctness.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `WORKFLOW.md` front matter.
- `server.port` is extension configuration and is intentionally not part of the core front-matter
  schema in Section 5.3.
- Precedence: CLI `--port` overrides `server.port` when both are present.
- `server.port` must be an integer. Positive values bind that port. `0` may be used to request an
  ephemeral port for local development and tests.
- Implementations should bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document should depict the current state of the system (for example the
  per-project waiting board, active sessions, retry delays, token consumption, runtime
  totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.
- Shell: `section#dashboard-root.dashboard-shell` (`phx-hook=OverlayDismiss`, inside the single
  `div#live-clock` wrapper) is a two-column grid — `nav.side-rail` and
  `div#dashboard-top.main-col`. `aside.settings-drawer` and `div.toast-stack` are siblings of
  those two and render last. The main column holds, in order: `header.command-bar` (slim,
  sticky, `--topbar-h` tall; `.command-bar-brand` hidden at ≥900px because the rail owns the
  brand there), `div.reconnect-note[role=status]`, the instrument band,
  `article#project-<dom-id>.project-section` per project, then
  `section#completions-section.section--completions`. Project section ids fold characters an
  HTML id cannot carry (case preserved) so two projects differing only by case stay distinct.
- The metrics strip is `div.instrument-band.command-bar-row--metrics.section--metrics` and is a
  **sibling** of `header.command-bar`, not a row inside it. It keeps the
  `command-bar-row--metrics section--metrics` class tokens because the section-visibility prefs
  key off them, and it stays inside the `unless payload_error` guard. Cells are hairline-divided
  (`.metric-pill`, no pill chrome) with 26px / weight-300 tabular numerals. A nonzero Retry count
  is not colored in the band; the retry rows carry the amber. Every cell grows (`flex: 1 0 auto`)
  so a band that wraps — rate limits present at 1600px push the ops cells onto a second row —
  fills each row edge-to-edge; a stub row under a full one reads as an unfinished panel and leaves
  the 160px accent rule underlining a single cell like a tab indicator. `.metric-pill--ops` carries
  no `max-width` for the same reason, and must reset `justify-content: flex-start` because it flips
  the base cell's main axis from column to row (the inherited `center` then centers every wrapped
  detail line instead of aligning it under the label). A cell with nothing to report renders a
  static string and carries `.metric-pill-placeholder` (`--ink-faint`) on its value span — `—` for
  a breakdown map with no positive count (States / Kinds on an idle board), a flat `▁` baseline for
  the Tput sparkline while there are fewer than two token samples; an empty value string leaves a
  dead label-only compartment in the hero band and reads as broken chrome.
- Running rows open with `div.session-grid-head.advanced-only[aria-hidden=true]`, a column-header
  row whose cells reuse the body column classes (`.session-row-title`, `.session-row-chips`,
  `.session-row-runtime`, `.session-row-tokens`), so `html[data-hidden-cols~=…]` hides a header
  and its column with no extra selectors. The row layout is flex with fixed `flex-basis` cells,
  never `grid-template-columns`: a `display:none` column must not leave a hole or shift the
  remaining cells. `.session-row-title` keeps a `min-width` floor (the title is the primary
  scent; it must not collapse to an ellipsis while the tag cluster keeps hundreds of pixels) over
  a `flex-basis` of `0` (with `auto` the title's own text is the basis, so shrink lands
  proportionally on the tag cluster and a row carrying a worker host orphans one tag onto a second
  line while the row still has room), and `.chip--truncate` caps long model names so the tags wrap
  as a balanced block instead of orphaning one tag onto a second line. `.chip--truncate` must also
  override `display` to `inline-block`: `.chip` is `inline-flex` and `text-overflow` never applies
  to a flex container, so the cap alone clipped `gemini-3.7-flash-high` to a plausible-looking
  `gemini-3.7-flash-` with no ellipsis. The disclosure caret is CSS geometry on `.session-row-disclosure`; the server
  renders no `▸`/`▾` glyph in the running rows.
- Queue cards carry `data-rank-label` (1-based, zero-padded) alongside `data-rank` (0-based,
  rewritten by the drag hook). CSS renders the label as a decorative numeral; the hook does not
  maintain it, and the next payload load re-renders both.
- Flashes render inside `div.toast-stack[aria-live=polite]`, fixed to the bottom-right and last
  in `#dashboard-root`, so an arriving flash never shifts the board. The stalled-agent alert
  stays in the document flow — it is persistent state, not a notification.
- Theme: `data-theme` on `<html>` is `light` / `dark` / absent. The stylesheet ships the light
  palette twice — `:root[data-theme="light"]` and
  `@media (prefers-color-scheme: light) { :root:not([data-theme]) }` — so "system" really follows
  the OS while an explicit `dark` choice still wins on a light OS. Vanilla CSS cannot share a
  declaration block between an attribute selector and a media query; the duplicate is
  intentional and both blocks must be edited together. Terminal wells (`.harness-tail`,
  `.log-list`) stay dark in both themes by token construction (`--surface-well` / `--well-ink`
  are identical across palettes). The rail paints `--rail-surface`, a token of its own: in dark
  it equals `--surface`, in light it is `#EFEFEC` — *below* `--page`, because a rail painted the
  same white as the content panels reads as unanchored floating text with one hairline doing all
  the separation work. Both light blocks carry it.
- `nav.side-rail[aria-label]` is chrome, not a section, and is not hideable by the display
  prefs. It renders, in order: `a.side-rail-brand[href="#dashboard-top"]`; a `.rail-vitals`
  block (running/queued numerals plus the autonomy sentence, inside the `unless payload_error`
  guard); `div#rail-nav.rail-group` with a `.rail-link` per anchor — Overview, one per project
  (`href="#project-<dom-id>"`, `title` = project name, `.rail-link-meta` = `running·waiting`),
  and Completions when non-empty — each opening with a `.rail-led--run|retry|paused|idle|done`
  LED; then `.rail-foot` with the mode switch (`#mode-switch-rail`, `phx-update=ignore`), the
  theme toggle, the settings `[data-drawer-toggle]` and Refresh. The rail reads only existing
  section assigns (`counts`, `projects`, `completions`, `polling`, `version`) and never `now`,
  so a clock re-anchor cannot re-render it. LED precedence is paused > retrying > running >
  idle. `RailNav` (`phx-hook` on `#rail-nav`) only paints `aria-current`; every anchor works
  without it.
- At ≥900px the rail owns the mode switch and theme toggle; the top strip keeps duplicate
  copies marked `.topbar-only-narrow` that are painted only below 900px, plus a native
  `details#jump-menu.jump-menu` project-jump disclosure. Its `open` attribute is browser-owned
  and never server-rendered, so morphdom strips it on every patch: the `JumpMenu` hook
  snapshots it in `beforeUpdate()` and restores it in `updated()`, and closes the menu when a
  link inside it is clicked. Below 900px this is the only section-jump control, so a patch may
  not close it mid-read; without JS it still opens and closes, it just cannot survive a patch.
  The delegated layout script syncs every duplicated instance, so the copies never disagree.
- Responsive breakpoints are 1200 / 900 / 640: full rail, 64px condensed rail (names become
  `title` tooltips; the rail's mode switch hides because no label fits — the console keeps it),
  and no rail (the top strip regains the brand and the jump menu) respectively.
- When a **connected** payload has no projects and no error, the board is replaced by
  `section.section-card.fleet-empty` — "No projects", one sentence, and an accent
  `[data-drawer-toggle]` button. The disconnected first render never shows it: `projects: []`
  is also the default payload, and a dead render has not earned the claim. A daemon with no
  orchestrator anywhere must actually *produce* that payload — see the empty-fleet rule under
  `GET /api/v1/state` — or the card is unreachable and the operator gets an error card with no
  call to action instead.
- Settings drawer (`aside.settings-drawer`) is scrimmed while open: `html[data-drawer="open"]
  body::after` is a real fixed element box, so it intercepts clicks (a box-shadow scrim would
  let them through). The click target becomes `<body>`, which `OverlayDismiss` treats as
  outside, so the console closes and nothing underneath activates. `Escape` closes it too, via
  a delegated `keydown` listener in `layouts.ex` — not a hook, because the open flag is an
  attribute on `<html>`, outside the LiveView container. That listener must yield to an
  overlay that already consumed the key (`e.defaultPrevented`): a Combobox open inside the
  console handles `Escape` itself, and one keypress may not dismiss both it and the console.
  Every console control carries an explanatory `p.settings-help` line; the
  Automation/Orchestrator controls are additionally wrapped one-per-`div.settings-control-row`
  = control + exactly one `p.settings-help` line, so `.settings-control-row +
  .settings-control-row` rules a hairline between them. The Linear, Projects, Experience and
  Display groups keep their help copy as a group-level sibling. The refresh row's
  copy must distinguish it from Linear polling. Primary actions (Connect, Add project, Resume
  all, queue Pin) carry `.subtle-button--accent`; Pause all and Restart stay quiet.
- Settings drawer (`aside.settings-drawer`) includes, after Experience and before Automation,
  visible in both simple and advanced modes:
  - **Linear** (`section.settings-group.settings-group--linear`): connect status
    (`Connected` / `Disconnected`), last-4 mask of the stored key when connected, and form
    `#linear-connect-form` (`phx-submit="connect_linear"`) with password input
    `#linear-api-key` (`name=api_key`, `autocomplete=off`). Submit validates the key against
    Linear, persists `linear_api_key` to `~/.cymphony/config.json` (top-level and every
    project; file mode `0600`), and rewrites each registered project's generated
    `WORKFLOW.md` `tracker.api_key`. Never put the raw key in LiveView assigns, flashes,
    logs, or API responses — flash the last-4 mask only (for example `Linear connected · ••••xxxx`).
  - **Projects** (`section.settings-group.settings-group--projects`): when disconnected,
    help text "Connect Linear to add a project". When connected, form `#add-project-form`
    (`phx-submit="add_project"`) with a searchable Combobox on `#add-project-slug`
    (`name=linear_project_slug`; **not** a native `<select>`). Options come from the
    operator's accessible Linear projects (label `name (slug_id)`, value `slug_id`) and
    type-to-filter. Also: name input `#add-project-name`, optional GitHub URL
    `#add-project-github`, and an advanced-only `.spec-switcher` (icon + model + effort) plus
    provider field. `preview_add_project` drafts the slug, name, github and those
    advanced fields, and a successful add resets all of them. Submit appends the project to `config.json`, writes a temp `WORKFLOW.md`,
    and starts the project supervisor immediately — no daemon restart. Duplicate
    name/slug is an operator-visible error.
  - Drawer fields only (`#linear-api-key`, add-project slug/name/github/agent/model/effort/provider,
    `#drawer-global-concurrency`, `#drawer-refresh-interval`) use class `settings-field`.
    There is one field look everywhere (`.inline-input`, `select`, `.settings-field`,
    `.combobox-trigger`): inset `--surface-deep` fill, `--line-strong` border, `--radius-ctl`.
    The `.inline-form` **container** carries no chrome — it is a borderless label+field cluster
    — but its control always does. A header or session control rendered as a naked label with
    no field chrome is a bug.
  - The global concurrency field `#drawer-global-concurrency` prefills the fleet value while
    every project reports the same `max_concurrent_agents`; when they disagree it renders
    empty with `placeholder="mixed"` (prefilling one of two values would flatten the other on
    Set), and when no project reports a limit it renders empty with `placeholder="10"`, the
    schema default. A completely blank box beside Set reads as unfinished.
  - Automation / Orchestrator (after global concurrency) includes
    `#drawer-refresh-interval` (`type=number`, `name=value`, `min=1`, default `3`,
    `phx-submit="set_refresh_interval"`). Persist the value as top-level
    `~/.cymphony/config.json` `dashboard_refresh_seconds` (positive integer, minimum 1;
    default `3` when missing/unreadable). This is the dashboard payload refresh cadence
    only — it is **not** `polling.interval_ms`, must not rewrite `WORKFLOW.md` for Linear
    refresh, and must not change orchestrator poll timing. No pubsub event may shorten this
    interval. Open dashboards keep their current interval until remount or a successful
    `set_refresh_interval`.
- The per-project header agent+model+effort control is one `.spec-switcher`
  (`phx-hook="SpecSwitcher"`). Hidden inputs keep the stable ids `agent-<project>`,
  `model-<project>`, and `effort-<project>` (the trigger is `agent-<project>-trigger`);
  the ids never embed the current kind or effort. The closed trigger is
  `icon model effort` using `/icons/claude.png`, `/icons/codex.png`, `/icons/agy.png`.
  The open panel is an icon strip (no claude/codex/antigravity text as the primary
  control) plus Model and Effort flyouts — no Reset-to-default. Changing to a known
  kind persists immediately (kind only; model/effort wait for header **Set**). The
  Effort row is hidden when the selected kind is `antigravity` (CLI Proxy slugs encode
  reasoning; `agy` rejects `--effort`). Picking a model opens the Effort flyout when it
  exists; with no Effort (antigravity) the switcher closes so the model list does not stay
  open, and choosing the antigravity icon dismisses an open model flyout. Header **Set** and `POST /api/v1/agent` persist
  kind+model+effort, rewrite the project's generated `WORKFLOW.md`, and overlay
  `config.json` so `snapshot.agent_kind` survives the next refresh. Dashboard payload
  reloads are generation-tokened so an in-flight stale snapshot cannot revert the selection
  after persist.
- Header wrapping form remains `form.project-agent-form`
  (`phx-change="preview_project_agent"`, `phx-submit="set_project_agent"`) so **Set**
  still sends kind+model+effort. Queue-card edit and add-project advanced fields use the
  same switcher (`#add-project-slug` stays a Combobox). Session restart is
  `form.restart-form` (`phx-change="preview_issue_run_spec"`,
  `phx-submit="set_issue_run_spec"`) with the switcher plus a Claude-only Provider field.
  Effort is omitted for `antigravity`. Session/completion agent chips are icons, not
  kind words. Harness stdout `section#harness-tail-<id>` is unchanged.
- Provider pills/fields (`form[phx-submit=set_project_providers]`, `#add-project-provider`,
  restart `name=provider`) are visible only when the selected agent kind is `claude`.
  Hide them for `codex`, `antigravity`, empty/default, and unknown kinds. Header uses
  `agent_settings.kind` (draft or `project.agent_kind`); restart uses
  `session_spec.suggestion_kind` (draft known kind else `entry.agent_kind`); add-project
  uses assign `:add_project_kind` (default `""` hides provider). Switching agent must
  hide/show on the next render via `preview_project_agent` / `preview_issue_run_spec` /
  `preview_add_project`. Do not delete persisted providers when the field is hidden.
  Session provider chips and the read-only Provider stat are hidden.
- Per-project header counts: `N/M running · Q queued · R retrying`. Advanced metrics add
  `.metric-pill--queue.section--queue` = `counts.waiting`. Simple mode labels the first two band
  cells **Running** (`counts.running`) and **To retry** (`counts.retrying`) — the mappings are
  unchanged, but the rail already says `running · queued`, so a band that said "Working" and
  "Waiting" put two words on the running count and made "waiting" mean *retrying* here and
  *queued* one column to the left.
- Theme / settings glyphs are CSS geometry only on `.theme-toggle-button` and
  `[data-drawer-toggle]` (no ☀ / ☾ / ⌂ / ⚙ text). The `system` button draws a monitor — a
  hairline `::before` rectangle plus an absolutely positioned `::after` stand — not an arrow
  outline, which reads as upload/eject beside a sun and a moon.
- Display preferences include `{Board, board}`. Hide the board with
  `html[data-hidden-sections~=board] .section--board { display: none }`.
- Waiting board (`section.queue-board.section--board`) sits inside
  `article.project-section` **above** In Progress (`.session-row-list`) and **below** the
  empty-state. Empty-state is shown iff `running == []` and `retrying == []` **and**
  `waiting == []`. Hide the board when `waiting == []` (no empty columns). Retry remains
  its own list **below** In Progress (Section 8.4).
- Board HEEx: `section.queue-board.section--board` > `header.queue-board-header` (simple
  `Up next` / advanced `Queue` + `span.queue-board-count.numeric`) >
  `div#queue-board-<project.name>.queue-board-list` (`phx-hook=QueueBoard`, `data-project`,
  `data-order`) > `article#queue-card-<project>-<identifier>.queue-card` (`data-issue`,
  `data-issue-id`, `data-rank`, `tabindex=0`). Card face only: `.queue-card-id` (mono
  caption; `a.session-row-link.queue-card-link` if url) + `.queue-card-title` (body-sm,
  2-line clamp) + `button.queue-card-edit-toggle` (text `Edit` or CSS kebab, no emoji).
  No Linear priority / state / agent chips. Edit is not an alert:
  `div.queue-card-edit` when `{project, id}` is in assign `:queue_edit_ids`;
  `form.queue-edit-form` (`phx-change=preview_queue_run_spec`,
  `phx-submit=set_queue_run_spec`); hidden `project` + `issue`; a
  `span.menu-field-label` header line — `Pin next run · <identifier>` with the
  identifier in `.mono` — before the first `.menu-field`, so the fixed-position
  sheet names its subject when it is flipped above the card or the board
  scrolls; comboboxes for `agent_kind` / `model` / `effort` preselect the card pin when
  set, otherwise the project header agent/model/effort (no `keep` blank);
  submit `Pin`; no provider. Pin persists with the queue and does **not** kill
  anything. Empty / `"keep"` in the pin payload still skip a field (API compat).
- LiveView mount assigns `:queue_edit_ids` (`MapSet.new()`) and
  `:queue_run_spec_drafts` (`%{}`). Events:
  - `reorder_queue` — params `project` + full identifier `order` list; optimistic
    client reorder, then `Control.set_queue_order`, reload
  - `toggle_queue_edit` — `project` + `issue`; toggle `{project, identifier}` in
    `:queue_edit_ids`
  - `preview_queue_run_spec` — draft `:queue_run_spec_drafts[{project, id}]` like
    `preview_issue_run_spec`; kind change to another harness clears model/effort;
    changing back to the inherited kind restores its model/effort; no persist
  - `set_queue_run_spec` — hidden `project` + `issue`; empty / keep skip;
    `Control.set_queue_pin`; do not kill
- `QueueBoard` hook mounts on `div#queue-board-<project.name>.queue-board-list` in
  `layouts.ex` beside `HarnessTail` / `Combobox` / `SpecSwitcher` (`mounted` / `updated` / `destroyed`;
  `pushEvent reorder_queue`). `Combobox.setChrome` / `SpecSwitcher.setChrome` also toggle the closest
  `.queue-card`.
- `QueueEditPanel` hook mounts on `div#queue-edit-<project>-<identifier>.queue-card-edit`
  (`layouts.ex`, beside `QueueBoard`). The edit sheet is a popover rather than an inline
  block, so the board's scroll box cannot clip it: `place()` fixes it to the viewport off
  the card's `getBoundingClientRect()` (width clamped to 304…360px and to the viewport,
  flipped above the card when it would overflow the bottom) and runs on `mounted`,
  `updated`, `resize` and capture-phase `scroll` — `updated` is required because a patch
  drops the inline styles morphdom does not own. A capture-phase `mousedown` outside the
  sheet clears `data-drawer` and pushes `dismiss_overlays`, exempting
  `.queue-card-edit-toggle` (otherwise the click that closes one sheet also swallows the
  open of the next) and `.combobox-list` / `.combobox-panel`, which render outside the
  sheet's subtree. `phx-click-away="dismiss_overlays"` on the same element is the
  server-side half; `OverlayDismiss.keepOpen` likewise exempts `.queue-card-edit`.
  `mounted` clears `data-drawer`, so opening a card's sheet closes the settings console
  rather than stacking a popover on top of a scrimmed panel.
- Refresh behavior: server-side re-render is change-only, the second-by-second clock runs
  in the browser, and `dashboard_refresh_seconds` is the **single** cadence for data-driven
  reloads (see the `dashboard_refresh_seconds` bullet above and Section 8.1).
  - A pubsub `:observability_updated` event sets a `:payload_dirty` flag only. It must not
    reload and must not re-stamp `:last_payload_refresh`. The orchestrator broadcasts twice
    per Linear poll (`polling.interval_ms`, default 5000) plus once per agent event, so
    reloading on the message made the *poll* interval the refresh interval, and re-stamping
    the window on every broadcast disabled the configured gate outright. `:payload_dirty`
    must not be read by the render, or it becomes the next always-dirty assign.
  - The 1s runtime tick performs one coalesced reload when the window elapsed **and**
    (`:payload_dirty` **or** at least 30s since the last load). The 30s idle resync is a
    safety net for a dropped broadcast and for fields nothing broadcasts about
    (`last_agent_timestamp`, the poll countdown). Leading edge: an event that lands after
    the window already elapsed reloads on the next tick (≤1s). The reload clears the flag.
  - User-initiated events reload immediately through the synchronous reload path, which
    also clears the flag. The async orchestrator commands (`kill_issue`, `retry_issue`,
    `set_issue_run_spec`, `refresh_now`) ask for that reload from their own task **after**
    the `GenServer.call`, so the repaint is immediate and correctly ordered; they used to
    depend on the orchestrator's broadcast for it.
  - Time-derived text is server-rendered once per payload load, wrapped in a span carrying a
    clock anchor. An anchor is always a remaining/elapsed **amount**, never an absolute wall
    time, so client clock skew cannot accumulate: `data-clock="countdown"` +
    `data-remaining-ms` (poll countdown), `data-clock="due"` + `data-remaining-ms` (retry
    due-in), `data-clock="elapsed"` + `data-base-seconds` (session runtime, stall duration).
    The global runtime tile is `elapsed` and adds `data-rate` = number of running sessions,
    because that total advances one second per running session per wall second. There is no
    turns suffix on any clock; `data-rate` is the only multiplier the format takes.
  - Elapsed renders `Mm Ss` under the hour and rolls into `Hh Mm Ss` from 60 minutes up
    (`4h 20m 44s`); a minutes-only counter past the hour (`260m 44s`) is a raw-counter tell in
    the band's largest numeral. `due` shares the elapsed formatter on both sides; countdown
    stays `Ns`. The server formatter and the hook's `formatElapsed` are one contract — they
    move in the same commit or the hook rewrites the server text the first time it paints.
  - One `LiveClock` hook (registered in `layouts.ex` beside `HarnessTail` / `Combobox` / `SpecSwitcher` /
    `QueueBoard`) mounts on a single wrapper `div#live-clock` around the dashboard and runs
    one 1s interval that rewrites only those spans' `textContent`; it clears the interval on
    `destroyed`. It re-anchors per element per tick by comparing the live data attributes
    against a snapshot cached on the node, so every payload load re-anchors the clocks. It
    must also repaint on `updated`: every LiveView patch morphs this container and writes the
    spans' text back to what the server rendered at the last payload load, so without the
    `updated` repaint the clocks rewind on each patch (a streaming harness pane patches many
    times a second) and stay wrong until the next interval. Its
    formatting must stay byte-identical to the server formatters. A span with a missing or
    unparseable anchor is skipped, leaving the server-rendered text (`n/a`, `unknown`, `now`)
    as the no-JS and bad-data fallback. Poll `checking?` ("Checking…") stays server-rendered:
    it is data, not time.
  - The 1s runtime tick still schedules the periodic payload refresh but must **not** assign
    `:now`. `:now` is a clock *anchor*, not a clock: it is assigned at mount and re-anchored
    by a payload load — the async `{:payload_loaded, seq, payload}` reply and the synchronous
    reload used by event handlers both go through the same split — but **only when a section
    a clock reads actually moved** (`:token_totals`, `:running`, `:projects`). `:now` reaches
    the board only through the `now` attr of the stalled-alert and session-row components and
    the retry row's due-in anchor, so re-anchoring on a load that moved nothing would
    re-serialize those clock spans for no reason — the re-render the section split exists to
    skip. Server-rendered
    values are therefore correct as of the last load that moved a clock-bearing section, and
    the hook takes over between loads. A clock hung off a section outside that set renders a
    stale amount, so the set must stay in step with the `:now` reads in the template. The
    poll countdown reads no wall clock at all — `next_poll_in_ms` is already a remaining
    amount — so it must not be formatted against `:now`.
  - A loaded payload is fanned into one assign per section (`:counts`, `:token_totals`,
    `:rate_limits`, `:polling`, `:projects`, `:running`, `:retrying`, `:completions`,
    `:payload_error`). There is no monolithic `:payload` assign, because nested `@payload.x`
    reads mark the whole template dirty on every load. A section whose value did not change
    is not reassigned, so LiveView change tracking skips it. `generated_at` gets no assign
    (it moves on every load and is rendered nowhere). The comparison drops a set of
    volatile keys from every entry and recurses into a project's `:running` **and** its
    `:retrying`:
    - `tokens_per_second`, which the presenter re-derives from the wall clock on every load
      (tokens over seconds-since-start) and which would otherwise make `:running` and
      `:projects` differ on every refresh while an agent runs.
    - `last_event_at`, which the 2s harness heartbeat pokes. The heartbeat is defined as a
      timestamp-only stall poke (Section 10) and carries no operator-visible news;
      `last_event`, `last_message`, `log_events` and `tokens` stay in the comparison, so
      anything real still lands the fresh section wholesale.
    - `due_at`, an absolute time re-derived from `now + due_in_ms`. Holding the previous
      value is lossless because every real reschedule also moves `attempt`, `held`, or
      `error`.

    One volatile value lives on a **section** rather than on an entry and needs its own rule:
    `polling.next_poll_in_ms`, the countdown the orchestrator re-derives as
    `max(0, next_poll_due_at_ms - now_ms)` on every snapshot. Comparing it verbatim reassigns
    `:polling` on every payload load, so *no* load can ever ship an empty diff and every
    refresh interval costs a full-container morph. Collapse an integer countdown in the
    `:polling` comparison so only `checking?`, `paused`, `poll_interval_ms` — and `nil`, which
    means no poll is scheduled and renders `n/a` without an anchor — can move the section. It
    is lossless: the countdown is a `data-clock="countdown"` anchor the browser advances
    itself, and `checking?` flips true on every tick and false again when the cycle ends,
    landing the refreshed countdown twice per poll.

    Any other movement still assigns the whole fresh section, drifted values included. The
    accepted trade-off is that the rendered per-session `t/s` chip and the expanded row's
    `@ <timestamp>` hold the value from the last load that moved a real field: while an agent
    sits in a long tool call they do not decay, and they catch up the moment anything else
    about the session moves. A retry's `due_at` is still computed so it does not drift —
    `now + due_in_ms` truncated **after** the offset is applied, not a truncated clock plus
    whole seconds — because it is rendered; the change comparison no longer depends on it. A
    section missing from the payload falls back to the default payload (error snapshots,
    older snapshot shapes). Both the async and the synchronous load path go through the same
    split; `payload_seq` guarding is unchanged.
  - Every user-editable control must render from a draft assign once the operator touches it.
    A DOM patch rewrites `input.value` from the server value for every input it walks and
    spares only the *focused*, non-hidden one, so an undrafted control is reset by the next
    patch — and a patch landing between blur and click submits the stale value. Drafts cover
    the per-project concurrency and providers inputs, the drawer's global concurrency and
    refresh interval, the add-project slug/name/github/agent/model/effort/provider fields,
    and the existing agent / session / queue run-spec drafts. A draft is written by a
    `phx-change` preview and cleared on successful submit, so an external API write becomes
    visible in the control again. Text/number inputs debounce (400ms) so a keystroke does not
    cost a round trip and a whole-container patch. Two things get `phx-update="ignore"`
    instead of a draft, because the server has no correct value to render for them: the
    Linear API key form (the key must never reach assigns) and the client-owned preference
    controls (density radios, section/column checkboxes, completions-limit select, both mode
    switches), which are pure localStorage state.
  - The Combobox hook owns its open state across patches. A patch re-applies the panel's
    server-rendered `hidden`, strips the open-chrome classes, rewrites the search value and
    every option's `hidden` / `aria-selected`, and blurs the search input by hiding an
    ancestor of it. The hook must snapshot query, active option **value**, focus and caret
    before the patch and restore them after it — open the panel first, then set the search
    value, re-filter, re-highlight by value (the option list itself may have changed), and
    refocus only if the search was focused before. It must never fall back to closing, which
    clears the typed filter.
  - The template carries **no** local `<% x = … %>` bindings. Such a binding makes the HEEx
    compiler abandon change tracking for every dynamic that follows it in the same template,
    which put a whole project section — its Comboboxes included — on the wire for a single
    harness stdout line, at up to ~12 patches per second on an expanded row. Rows are function
    components (stalled alert, project agent controls, queue card, session row) whose attrs are
    change-tracked individually. Project / queue / session / retry comprehensions are keyed for
    per-row diffs. A keyed LiveView 1.1.33 reorder previously raised in `template_static`
    because a rank-dependent Next badge changed the row's structural template; the badge now
    remains in the template and hides outside rank 0. Stable card DOM IDs and the client
    QueueBoard hook preserve immediate drag behavior, while the server waits for authoritative
    state rather than optimistically reassigning `:projects`. A narrow per-project rendering
    projection keeps header/editor controls out of single-card diffs. A harness line must ship
    the harness pane and nothing else.
  - Acceptance: an idle dashboard ships no per-second diff; with sessions running and no real
    state change a payload load ships an **empty** diff (an empty diff is skipped entirely by
    the client, which is what leaves every input and every open dropdown alone) and reassigns
    no section, does not re-anchor `:now`, and moves only the throughput sample window, which
    no dynamic reads. A poll whose only movement is `generated_at` does the same, and so does
    one whose only movement is the poll countdown. "No real state change" has to be tested
    with the countdown **advanced**: a live orchestrator moves it on every snapshot, so an
    acceptance payload echoed back from a frozen fixture proves nothing. A
    `dashboard_refresh_seconds` of 20 means at most one data re-render per 20s.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, waiting board,
    retry queue/delays, aggregate token/runtime totals, latest rate limits, and any
    additional tracked summary fields).
  - `counts.waiting` is the sum of per-project `waiting` lengths (`waiting_count`).
    Each project object includes `waiting` (list) + `waiting_count`. Default payload /
    fixtures include `waiting: []` and `counts.waiting`.
  - **Empty fleet is not an error.** When the project registry holds no orchestrators *and*
    the legacy orchestrator name is not registered, there is nothing to snapshot and nothing
    is wrong: return a normal payload with `projects: []`, zeroed `counts`/`token_totals`,
    empty `running`/`retrying`/`recent_completed`, and `polling`/`rate_limits` `null` — no
    `error` key. `snapshot_unavailable` stays reserved for an orchestrator that exists and
    cannot answer (including a registry with projects whose snapshots all failed), and
    `snapshot_timeout` for one that did not answer in time. Reporting a zero-project daemon
    as `snapshot_unavailable` also made the dashboard's fleet-empty card unreachable.
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1,
        "waiting": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "waiting": [
        {
          "issue_identifier": "MT-651",
          "issue_title": "Add queue board",
          "issue_url": "https://linear.app/team/issue/MT-651",
          "issue_id": "ghi789",
          "priority": 2,
          "state": "Todo",
          "created_at": "2026-02-24T19:00:00Z",
          "agent_kind": "codex",
          "model": "gpt-5.2-codex",
          "effort": "high"
        }
      ],
      "claude_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/linear`
  - Must be declared **before** the `GET /api/v1/<issue_identifier>` catch-all.
  - Returns Linear connect status. `200` JSON keys: `connected` (boolean), `masked_key`
    (last-4 mask or `null`), `source` (`"config"` | `"env"` | `null`). Never returns the
    raw key.
- `POST /api/v1/linear`
  - Must be declared **before** the issue catch-all. Unsupported methods on this path
    return `405`.
  - Body `{"api_key":"..."}`. Validates against Linear (`viewer { id }`), then persists
    `linear_api_key` to `~/.cymphony/config.json` (top-level and every project) and
    rewrites each registered project's `WORKFLOW.md` `tracker.api_key`.
  - `202` with the same `connected` / `masked_key` / `source` JSON as GET.
  - `422` `{"error":{"code":"empty_api_key"|"invalid_api_key"|"linear_unauthorized"|"linear_error","message":"..."}}`.
  - Never echo `api_key` in the response, logs, or error message.
- `GET /api/v1/linear/projects`
  - Must be declared **before** the issue catch-all.
  - Lists Linear projects accessible with the stored key:
    `200` `{"projects":[{"id":"...","name":"...","slug_id":"..."}]}`.
  - `422` `{"error":{"code":"linear_not_connected","message":"..."}}` if no key is
    resolved (file or env).
- `POST /api/v1/projects`
  - Must be declared **before** the issue catch-all. `GET /api/v1/projects` (running
    counts) is unchanged in shape. It returns a normal `200 {"projects":[]}` for a truly
    empty fleet, but `503 snapshot_unavailable` when projects are registered and every
    bounded snapshot read fails; never render that failure as an empty fleet.
  - Body `{"name":"...","linear_project_slug":"..."}` plus optional `github_repo_url`,
    `workspace_root`, `agent`, `model`, `effort`, `provider`.
  - Appends to `~/.cymphony/config.json`, writes a temp `WORKFLOW.md`, and starts the
    project supervisor (no daemon restart). Inherits the shared `linear_api_key`.
  - `202` `{"name":"...","linear_project_slug":"...","started":true}` (never include the
    raw key).
  - `422` codes: `not_connected`, `invalid_project`, `duplicate_project_name`,
    `duplicate_project_slug`, `project_workflow_failed`, `project_start_failed`.

- `POST /api/v1/queue`
  - Must be declared (and `match :*` `405`) **before** `/api/v1/:issue_identifier`.
  - Query `?project=` is **required**. `Control.set_queue_order({:project, name}, order)`
    applies the orchestrator call first, then persists. `:all` is
    `{:error, :invalid_scope}`.
  - Body `{"order":["LLM-51","LLM-12"]}` — full identifier/id order for that project.
    `parse_queue_order/1` rejects non-lists / blank keys.
  - `202` `{"order":[...],"project":"Name"}`.
  - `422` `{"error":{"code":"invalid_queue_order","message":"..."}}`.
  - Other methods `405`. No Linear writes.
- `POST /api/v1/queue-pin`
  - Must be declared (and `match :*` `405`) **before** `/api/v1/:issue_identifier`.
  - Query `?project=` is **required**. `Control.set_queue_pin({:project, name}, issue_key,
    pin_map)` applies the orchestrator call first, then persists. `:all` is
    `{:error, :invalid_scope}`.
  - Body `{"issue":"LLM-51","kind":"codex","model":"...","effort":"..."}` — each of
    `kind` / `model` / `effort` optional; empty / `keep` skipped; at least one real
    field required. `parse_queue_pin/1` rejects blank keys / unknown agent kinds.
  - `202` `{"issue","agent_kind","model","effort","project"}`.
  - `422` `{"error":{"code":"invalid_queue_pin","message":"..."}}`.
  - Other methods `405`. Does not kill a session (the issue is not running). No
    Linear writes. No provider on queue pins.

- `GET /api/v1/<issue_identifier>/harness`
  - Must be declared **before** the `GET /api/v1/<issue_identifier>` catch-all.
  - Optional query `?project=<name>`.
  - `200`: `HarnessStream.snapshot(issue_id)` plus `issue_identifier`.
  - `404`: the issue is not running and there is no leftover snapshot.
- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/cymphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "claude_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/cymphony/claude/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    may coalesce repeated requests).
  - This is **not** `POST /api/v1/refresh-interval` (dashboard payload cadence).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

- `POST /api/v1/refresh-interval`
  - Must be declared **before** the `GET /api/v1/<issue_identifier>` catch-all (and
    `match :*` on this path). Unsupported methods return `405`.
  - This is **not** `POST /api/v1/refresh` (Linear poll + reconcile). It does not
    write `polling.interval_ms`, rewrite `WORKFLOW.md` for tracker refresh, or change
    orchestrator poll timing. It does not take `?project=`.
  - Body `{"value": N}` where `N` is a positive integer ≥ 1.
  - Persists only the top-level `~/.cymphony/config.json` key
    `dashboard_refresh_seconds` (beside `projects`, never inside a project map).
  - `202` `{"dashboard_refresh_seconds": N}`.
  - `422` `{"error":{"code":"invalid_refresh_interval","message":"..."}}`.
  - `422` `{"error":{"code":"refresh_interval_not_persisted","message":"..."}}` when the
    value could not be written to the config store. Answering `202` there claimed success for
    a setting that reverts on the next restart.

Optional operational-control endpoints (extension; all return `202 Accepted` and accept an
optional `?project=<name>` scope):

- `POST /api/v1/pause` / `POST /api/v1/resume` — stop/start dispatching new issues; running
  sessions complete normally. The flag is **durable**: each in-scope project's
  `dispatch_paused` boolean is persisted to the operator config store, so a paused project is
  still paused after a daemon restart (Section 8.1). Success shape is unchanged
  (`202 {"paused": <bool>, "project": <name|null>}`). Because the flag is durable, a failed
  persist is **not** a success: the orchestrators are already stopped but the next restart
  undoes it, so the response is `422 {"error":{"code":"dispatch_pause_not_persisted", …}}`
  (and `422 project_not_found` when `?project=` names no registered orchestrator). The
  dashboard's global Pause/Resume and per-project header toggle flash the same distinction
  instead of reporting plain success.
- `POST /api/v1/concurrency` — body `{"value": <int>}`; updates `max_concurrent_agents` at
  runtime and persists to the operator config store.
- `POST /api/v1/providers` — body `{"value": "a1,a2"}`; updates the active agent kind's
  provider rotation; applies to subsequent dispatches only.
- `POST /api/v1/agent` — body with any of `kind` (`"claude"`/`"codex"`/`"antigravity"`),
  `model`, `effort` (empty string clears model/effort to the agent default); updates
  runtime agent settings and persists to `~/.cymphony/config.json`; **rewrites the
  project's generated `WORKFLOW.md` and overlays `config.json` agent/model/effort so
  `snapshot.agent_kind` survives the next dashboard/API refresh**. Dashboard header
  **Set** and change-to-save (kind-only persist on the project agent SpecSwitcher, whose hidden
  input carries `#agent-<project>`) follow the same rewrite + overlay path. Applies to
  subsequent dispatches. Error when
  none of those keys are present or `kind` is not a known kind:
  `"body must include at least one of kind/model/effort; kind must be one of: claude, codex, antigravity"`.
- `POST /api/v1/refresh-interval` is documented with the minimum endpoints above
  (not `?project=`-scoped; not `POST /refresh`).
- Dashboard `set_issue_run_spec` (LiveView / orchestrator) accepts optional
  `:provider`, `:model`, `:effort`, and `:agent_kind` overrides and kills +
  redispatches the session. Empty / `"keep"` skips a field.
- Linear connect / add-project writes (`POST /api/v1/linear`,
  `POST /api/v1/projects`) are documented with the Linear routes above (`202` on
  success, `422` on validation). They do not take `?project=`.

Dashboard display preferences (density, hidden sections including `{Board, board}`,
visible columns, list lengths) are client-side only (browser localStorage); they are not
server state and have no API surface.

Every affordance that reflects a client-side preference must be styled from the `<html>`
attributes that preference already sets, never from an attribute the server renders inside the
LiveView container. A DOM patch rewrites server-rendered attributes back to the template's value
while `<html>` — outside the patched container — keeps what localStorage set, so a control keyed
off the server attribute silently disagrees with the state it describes after any refresh. The
section-collapse chevron is the concrete case: it rotates off the same
`data-collapsed-sections` / `data-expanded-sections` / `data-ui-mode` selectors that hide the
section body, and not off the button's own `aria-expanded`. That attribute is still written for
assistive technology, guarded so the mutation observer that repairs it after a patch cannot
re-trigger itself.

API design notes:

- The JSON shapes above are the recommended baseline for interoperability and debugging ergonomics.
- Implementations may add fields, but should avoid breaking existing fields within a version.
- Endpoints should be read-only except for operational triggers like `/refresh`,
  `/refresh-interval`, `/linear`, `POST /projects`, `POST /queue`, `POST /queue-pin`,
  and the operational-control endpoints above.
- Unsupported methods on defined routes should return `405 Method Not Allowed`.
- API errors should use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it should consume this API rather than duplicating state
  logic.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; may come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested (hard fail)
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (prompt and most runtime settings).
- `WORKFLOW.md` changes should be detected and re-applied automatically without restart.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations should state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations should state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path must remain under configured workspace root.
- Coding-agent cwd must be the per-issue workspace path for the current run.
- Workspace directory names must use sanitized identifiers.

Recommended additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output should be truncated in logs.
- Hook timeouts are required to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Claude Code agents against repositories, issue trackers, and other inputs that may contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations should explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
ports should not assume that tracker data, repository contents, prompt inputs, or tool arguments are
fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Claude Code approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Claude Code policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing the optional `linear_graphql` tool so it can only read or mutate data inside the
  intended project scope, rather than exposing general workspace-wide tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations should document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    # Seeded before schedule_tick(0) below, so a persisted pause is already in
    # effect for the very first dispatch.
    paused: load_project_dispatch_paused(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    waiting: [],
    queue_order: load_project_queue_order(),
    queue_pins: load_project_queue_pins(),
    queue_priority_seen: load_project_queue_priority_seen(),
    completed: set(),
    claude_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    claude_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state  # keep last waiting

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state  # keep last waiting

  # always fetch, including when paused and available_slots == 0
  eligible = filter_waiting_eligible(issues)
    # candidate_issue? and not todo_blocked and not claimed
    # and not running and not retry_attempts
  state = Queue.reconcile(state, eligible)
    # sets state.waiting; may persist queue_order + queue_priority_seen
    # do not claim waiting ids
    # do not re-sort via sort_for_dispatch once a saved/reconciled order exists

  if paused:
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state  # waiting refreshed; do not spawn

  for issue in state.waiting:  # leftmost first
    if no_global_slots(state):
      break  # keep remaining waiting
    if not state_slots_available(issue) or not worker_slots_available(issue):
      continue  # leave on waiting; try next
    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)  # claim only then
      state.waiting.remove(issue)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    claude_app_server_pid: null,
    last_claude_message: null,
    last_claude_event: null,
    last_claude_timestamp: null,
    claude_input_tokens: 0,
    claude_output_tokens: 0,
    claude_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {claude_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

The following retry pseudocode is conceptual: network validation is a bounded
runtime-owned intent, not a synchronous call inside the orchestrator. Its
result is fenced against the current run/config generation and retry token.

```text
on_retry_timer(issue_id, retry_token, state):
  retry_entry = state.retry_attempts[issue_id]
  if retry_entry is missing or retry_entry.retry_token != retry_token:
    return state

  if state.paused:
    # Hold: same attempt, same failures, no timer, original due_at_ms.
    retry_entry.timer_ref = null
    retry_entry.held = true
    return state

  # The claim and retry record remain owned until a real outcome.
  return start_bounded_retry_validation_intent(issue_id, retry_entry)

on_retry_intent_result(issue_id, retry_token, result, state):
  if token_or_generation_is_stale(result, state):
    return state
  if result is refresh_error or current_worker_capacity_denies_dispatch:
    return rearm_existing_retry_without_new_failure(state, issue_id)
  if result is missing, terminal, or no_longer_active:
    state.retry_attempts.remove(issue_id)
    state.claimed.remove(issue_id)
    return state
  if current_state_allows_dispatch(result.issue, state):
    return dispatch_and_then_remove_retry_record(result.issue, state)
  return rearm_or_hold_existing_retry(state, issue_id)
```

```text
on_resume(state):
  state.paused = false

  for issue_id, retry_entry in state.retry_attempts:
    if retry_entry.held:
      # Same attempt: pick the backoff schedule back up, do not restart or skip it.
      retry_entry.retry_token = new_token()
      retry_entry.timer_ref = send_after({retry_issue, issue_id, retry_entry.retry_token}, 0)
      retry_entry.due_at_ms = now_ms()
      retry_entry.held = removed

  notify_observers()
  return state
```

## 17. Test and Validation Matrix

A conforming implementation should include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests required for all conforming implementations.
- `Extension Conformance`: required only for optional features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks recommended before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Workflow file changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when optional values are missing
- `tracker.kind` validation enforces currently supported kind (`linear`)
- `tracker.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for tracker API key and path values
- `~` path expansion works
- `claude.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)
- A generated workflow file lands at mode `0600` on a fresh write, and a pre-existing looser mode
  is tightened rather than inherited — the file carries the tracker API key in cleartext
- A generated-workflow write that cannot be completed surfaces the posix error and leaves no
  staged temp file beside the target
- A per-project `stall_timeout_ms` in the config store reaches `agent.stall_timeout_ms` in the
  generated workflow; only a positive integer overrides the default
- A per-project `extra_args` in the config store reaches the **active kind's** section in the
  generated workflow and no other kind's; both the map-keyed-by-kind and the bare-list shapes
  are accepted; only a list of strings is honored and any other shape is ignored with a warning
- A per-project `new_project: false` in the config store reaches `antigravity.new_project`;
  every other value (including absence) leaves the key out and keeps `--new-project` on

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- Optional workspace population/synchronization errors are surfaced
- Temporary artifacts (`tmp`, `.elixir_ls`) are removed during prep
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch uses active states and project slug
- Linear query uses the specified project filter field (`slugId`)
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch consumes `waiting` order after `Queue.reconcile` (leftmost first).
  `Dispatch.sort_for_dispatch` is INITIAL ORDER only (no saved `queue_order`).
  Drag persists full identifier order; Linear raise re-inserts that one card;
  Linear lower never moves; new issues append unless Urgent (`priority == 1`)
  which inserts at index `0`. Skip a waiting head only when per-state or
  per-host slots are full; global slot exhaustion stops the walk and keeps
  remaining `waiting`. Do not claim waiting ids. No Linear writes.
- Queue pins overlay `dispatch_run_spec/3` as pin > labels > directive > config
  when dispatching from `waiting`.
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- A project persisted as `dispatch_paused` is already paused on the first tick: `paused` is seeded
  during initialization, before the immediate first dispatch is scheduled, so it never dispatches
  once and pauses afterwards. A config store that exists but cannot be read logs the discarded
  seed; an absent one boots unpaused silently
- A retry timer that fires while paused holds the entry: it neither dispatches nor reschedules,
  and the entry's `attempt` does not move. Repeated firings are idempotent and a stale
  `retry_token` is still ignored
- `resume` re-arms every held entry immediately with the same `attempt` (no fresh backoff wait);
  a `resume` with nothing held leaves the retry queue untouched
- Pause/resume persist `dispatch_paused` for every project in scope and report a persist failure
  rather than a plain success; with no config store at all (legacy mode) there is nothing durable
  to lose and they still report success
- A worker task that crashes records the agent CLI's own error text, not the raw exception tuple
- If a snapshot API is implemented, it returns running rows, waiting rows
  (`waiting` / `waiting_count` / `counts.waiting`), retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <claude.command>`
- Startup handshake sends `initialize`, `initialized`, `thread/start`, `turn/start`
- `initialize` includes client identity/capabilities payload required by the targeted Claude Code
  app-server protocol
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- `thread/start` and `turn/start` parse nested IDs and emit `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Partial JSON lines are buffered until newline
- An unterminated CLI line over 256 KiB is rejected before it can grow a port
  buffer indefinitely; retained completed events use a bounded window that
  preserves result/session/usage milestones (Antigravity fallback text capped
  at 64 KiB with a truncation marker)
- Stdout and stderr are handled separately; protocol JSON is parsed from stdout only
- Non-JSON stderr lines are logged but do not crash parsing
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- A non-zero agent exit reports the error line the CLI actually printed, not just whatever was
  left unterminated in the read buffer — a CLI that rejects its arguments prints a complete,
  newline-terminated line and exits, so the buffer alone is empty
- That tail is bounded (by lines and by bytes), stripped of ANSI/control sequences, and ordered
  newest line first, because every surface that renders it truncates from the front
- That tail is redacted before it leaves the runner: secret-named assignments (quoted, `=>`,
  and camelCase forms included), `Authorization`/`Cookie` headers regardless of scheme, and
  bare vendor-prefixed credentials are replaced with `[REDACTED]` while ordinary output —
  including bare-word `token:`/`key:` diagnostics and `*_PATH`/`*_FILE` values — is untouched,
  so no downstream surface can publish a credential the CLI printed
- The exit-0 failure paths are equally bounded and redacted: an adapter error payload built
  from transcript lines (`no_result_in_stream`, `no_json_output`, `json_decode_failed`) is an
  excerpt, never the raw joined transcript, and a decoded `turn_failed` payload is recursively
  redacted; `:harness_stdout` lines are redacted after their 2048-byte slice before entering
  the harness ring
- Every agy invocation the Antigravity adapter builds carries `--new-project` (fresh runs and
  `--conversation` resumes alike) unless `antigravity.new_project` is exactly `false`, and
  `--log-file <workspace>/../.agy-<issue>.log` — a sibling of the workspace, outside the cloned
  tree — whenever the run has a workspace
- Usage and rate-limit payloads are extracted from nested payload shapes
- Compatible payload variants for approvals, user-input-required signals, and usage/rate-limit
  telemetry are accepted when they preserve the same logical meaning
- If optional client-side tools are implemented, the startup handshake advertises the supported tool
  specs required for discovery by the targeted app-server version
- If the optional `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Both disk sinks are installed from the config directory: the full transcript at `debug` and up,
  and a plainly-named, size-capped sink at `warning` and up that excludes lower levels. Installing
  them removes the default console handler
- Both sink paths are overridable and the test environment overrides them, so a test run never
  appends to (or rotates) the operator's real logs; a test that unsets an override restores it
- Every exit path flushes the buffering sinks before halting the VM
- If the LiveView dashboard is implemented, pause/resume from the global buttons and from a
  project header both go through the durable-pause control and flash an error — while still
  reloading the board — when the orchestrators flipped but the flag could not be persisted
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior
- If the LiveView dashboard is implemented (Section 13.7.1 refresh behavior):
  - a runtime tick that is not yet due to refresh moves no assign and renders identical HTML;
    the tick that *is* due, with the payload marked dirty, still schedules the payload load
    (and so moves `:payload_seq` and `:last_payload_refresh`)
  - a pubsub update inside the refresh window marks the payload dirty and reloads nothing:
    `:payload_seq` and `:last_payload_refresh` do not move, and a burst of updates costs one
    load per configured interval
  - an idle board still resyncs once the idle-resync deadline passes with nothing dirty
  - re-delivering a payload **with sessions running** that differs only in values the server
    re-derives from the wall clock — `generated_at`, and a poll countdown that has ticked
    down — reassigns no section, does not re-anchor `:now`, and ships an empty diff to the
    client
  - a payload whose only movement is a volatile entry field the server re-derives or pokes on
    every load (`tokens_per_second`, `last_event_at`, `due_at`, including inside a project's
    nested `retrying` list) reassigns no section either
  - an operator-initiated command (`kill_issue`, `retry_issue`, `refresh_now`,
    `set_issue_run_spec`) reloads the payload without waiting for the refresh window
  - a draft written by a `phx-change` preview survives a payload load that lands mid-edit,
    and a successful submit clears it
  - a payload that moves one section leaves the other section assigns alone
  - a payload that only moves the poll countdown between two integers reassigns nothing at
    all — not `:polling`, not `:now`, not the per-project section — while one that drops the
    countdown to `nil`, or flips `checking?`, still reassigns `:polling`; a payload that moves
    a clock-bearing section re-anchors `:now`
  - time-derived spans carry their `data-clock` anchor as a remaining/elapsed amount, and
    drop the anchor attribute entirely when the amount is unknown so the server-rendered
    text survives
  - the client clock formatter and the server formatters produce identical strings
  - a connected dashboard with no orchestrator registered anywhere renders the fleet-empty
    card, not the snapshot-error card, straight out of `Presenter.state_payload/2`; an
    orchestrator that exists and cannot answer still renders the error card
  - the narrow-viewport jump menu keeps its `open` attribute across a LiveView patch
  - `Escape` inside an open Combobox in the settings console closes only the dropdown

### 17.7 CLI and Host Lifecycle

- CLI accepts an optional positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally
- Background start resolves the running executable (Burrito wrapper path, escript path,
  launcher progname, `PATH`) and aborts with an error when none resolves to an executable file
- Background start reports failure with the daemon output tail when the detached process exits
  before writing a pidfile, or when none appears before the deadline, instead of claiming success
  with an unknown PID — and does not fail a start that is merely slow while the child is alive
- Background start refuses to launch a second daemon while a live pidfile exists
- The daemon writes its pidfile only after it has reached the started state; a run that fails to
  load its configuration or to start its projects leaves no pidfile behind, so the launcher's wait
  cannot mistake a spawned-but-dead process for a booted one

### 17.8 Real Integration Profile (Recommended)

These checks are recommended for production readiness and may be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- Real integration tests should use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test should be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures should
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 Required for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Claude Code launch command config (`claude.command`, default `claude`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; optional snapshot/status surface)

### 18.2 Recommended Extensions (Not Required for Conformance)

- Optional HTTP server honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- Optional `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the
  app-server session using configured Cymphony auth.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI
  implementation details.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead
  of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (Recommended)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the optional HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (Optional)

This appendix describes a common extension profile in which Cymphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime should stay on the same host and workspace.
- A remote host should satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts may be treated as a pool for dispatch.
- Implementations may prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an optional shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch should wait rather than silently falling back to a
  different execution mode.
- Implementations may fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host should be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations should distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host should reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
