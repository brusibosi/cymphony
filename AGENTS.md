# AGENTS.md

This file provides guidance to agents and tools when working with code in this repository.

## What This Project Is

Cymphony is an Elixir-based orchestrator that polls Linear for issues and dispatches them as autonomous Claude Code agent runs. It supports multi-project orchestration, configurable concurrency limits (`cr N`), and provider rotation (`c cv1,cz2,ck1`) to distribute sessions across multiple Claude backends. A Phoenix LiveView dashboard provides real-time observability.

It's a rewrite of OpenAI's Cymphony, using Claude Code instead of Codex.

## Build & Development Commands

All commands run from the project root:

```bash
mix setup              # Install deps
make build             # Build the escript binary (bin/cymphony)
make test              # Run tests
mix test test/path/to_test.exs  # Run a single test file
make coverage          # Run tests with coverage (100% threshold on tracked modules)
make fmt               # Auto-format code
make fmt-check         # Check formatting without changes
make lint              # Run specs.check + credo --strict
make dialyzer          # Run type analysis
make all               # Full CI gate (setup, build, fmt-check, lint, coverage, dialyzer)
```

- Elixir 1.19.x (OTP 28), managed via `mise`
- Quality gate: `make all` must pass before handoff

## CLI Commands

Defined in `lib/cymphony_elixir/cli.ex`.

### Shorthand expansions

| Command | Expands to | Description |
|---------|-----------|-------------|
| `project <name>` / `projects <name>` | `--project <name>` | Run a specific project |
| `agent <kind>` | `--agent <kind>` | Coding agent: `claude`, `codex`, or `antigravity` |
| `model <name>` | `--model <name>` | Model override passed to the agent CLI |
| `effort <level>` | `--effort <level>` | Reasoning effort passed to the agent CLI |
| `c <value>` | `--provider <value>` | Provider rotation (comma-separated auth aliases) |
| `cr <n>` | `--concurrency <n>` | Set max concurrent agents |
| `port <n>` | `--port <n>` | Set HTTP server / dashboard port |
| `setup` | `--setup` | Run onboarding wizard |
| `add` | `add-project` | Add a project to config |
| `list` | — | List configured projects |
| `v` | `--version` | Show version |
| `h` | `--help` | Show help |
| `start` | `--background` | Run in background |
| `stop` | `--background-stop` | Stop background process |
| `restart` | `--restart` | Restart background process |
| `logs [n]` | — | Show last n lines of log (default: all) |

The short forms `b`, `bs`, `r`, `s`, `p`, `a`, `l` / `ls`, `log`, and the long flag `--port` still work as aliases for backward compatibility but are no longer documented in `--help`.

### Background daemon and log files

`cymphony start` re-executes the running binary under `nohup` and waits up to 5s for the daemon to
write `~/.cymphony/cymphony.pid`.

`CymphonyElixir.Daemon.executable_path/1` resolves argv[0] before anything is spawned, in order:
Burrito wrapper path (`Burrito.Util.Args.get_bin_path/0`, i.e. `__BURRITO_BIN_PATH`) → escript path
(`:escript.script_name/0`) → launcher `progname` (never `erl`/`erlexec`) → `cymphony` on `PATH`.
Each candidate must be an executable file (bare names must resolve through `PATH`). Burrito
releases boot the BEAM directly, so escript/progname cannot name the wrapper — only the exported
wrapper path can. If nothing resolves, `start` aborts with an error instead of emitting a `nohup`
command with a blank/unqualified argv[0].

`Daemon.background_command/3` also prints the detached child's OS pid on a `cymphony-daemon-pid=`
line, which `Daemon.split_launcher_pid/1` strips back out of the operator-facing launcher output.
The wait for `cymphony.pid` is driven by that pid, not by a stopwatch: a child that is already
gone fails immediately (`the daemon exited before writing its pidfile`), while a live child gets
the full 60s deadline. The daemon writes its own pidfile late in boot, and a Burrito binary
decompresses its payload and deletes the previous version's install tree before the BEAM starts,
so the old 5s abort failed healthy first-run-after-upgrade starts — and a wrapper retrying on the
nonzero exit could bring up a second daemon on the same port. Either failure exits nonzero with
the launcher output plus a sanitized tail of `daemon.out` (scrubbed of invalid UTF-8: the tail is
read from a byte offset into a terminal capture, and `IO.puts(:stderr, …)` raises on a split
codepoint). It never claims success with an unknown PID.

"Late in boot" is load-bearing and holds for both builds. In the escript path
`maybe_write_daemon_pidfile/2` runs on the **result** of `start_from_config/3` (and of
`legacy_run/3`): only `:ok` claims the pidfile, so a bad `config.json`, a missing workflow file or
a taken dashboard port leaves it absent and the launcher reports the failure with the `daemon.out`
tail. Writing it first made `Cymphony started in background (PID …)` a report that the process was
*spawned*, not that it *booted*. The Burrito build gets the ordering for free — `BurritoCLI.start/2`
brings up the supervision tree before `Task.start(__MODULE__, :run_cli, …)`.

All paths derive from `CymphonyConfig.config_dir/0` (`~/.cymphony` by default), never a separate
hardcoded `~`:

| Path | Written by | Contents |
|------|-----------|----------|
| `~/.cymphony/log/cymphony.log.N` | `:logger_disk_log_h` (wrap) | Full `debug`+ transcript; what `cymphony logs` reads |
| `~/.cymphony/daemon.log` | `:logger_std_h` (file, 2 MB × 2) | `warning`+ only, plainly named and tailable |
| `~/.cymphony/daemon.out` | `nohup` redirect | Raw daemon stdout/stderr — status TUI repaints plus any pre-Logger crash |
| `~/.cymphony/cymphony.pid` | `--daemon-internal` | Daemon OS pid |

Both file handlers buffer and `System.halt/1` does not unwind the VM, so every exit path goes
through `CLI.halt/1`, which calls `Logger.flush()` first; without it a startup failure leaves both
log files empty. That includes `BurritoCLI.run_cli/1`'s unhandled-error handler — the only record
of a crash in the shipped binary, running after `LogFile.configure/0` removed the console handler.
There must stay exactly one `System.halt/1` call site in `lib/`, inside `CLI.halt/1`.

`Application.start/2` installs both handlers unconditionally, so `config/config.exs` pins
`:log_file` and `:daemon_log_file` to `tmp/test-logs` under `config_env() == :test`. Without that,
`mix test` appends the whole suite's warning noise — raw agent stdout included — to the real
`~/.cymphony/daemon.log` and rotates it. `LogFileTest` unsets both to exercise the config-dir
defaults and must **restore** them in `on_exit`, not delete them.

### Concurrency control

```bash
cymphony cr 3                    # Limit to 3 concurrent sessions
cymphony cr 1                    # Run one session at a time
cymphony project AgentFarm cr 5  # 5 sessions for "AgentFarm" project
```

Limits how many Claude sessions run simultaneously. Default is 10. As sessions complete, waiting issues auto-dispatch on the next poll tick.

### Provider rotation

```bash
cymphony c cv1,cz2,ck1                # Rotate across 3 providers
cymphony project Farm cr 6 c cv1,cz2  # 6 sessions split across 2 providers (~3 each)
```

Comma-separated provider names are randomly assigned per session. Each provider must be defined in `~/.cymphony/config.json` under `providers` or as a shell function in `~/.cld`.

### Agent selection

```bash
cymphony agent codex                       # Run every project with the Codex CLI
cymphony agent antigravity                 # Run every project with the Antigravity CLI (`agy`)
cymphony agent codex model gpt-5.2-codex   # Codex with an explicit model
cymphony effort high                       # Reasoning effort for the configured agent
```

`agent <kind>` picks the coding-agent backend (`claude`, `codex`, or `antigravity`) for this run; `model` and
`effort` are passed through to the agent CLI (Claude: `--model`/`--effort`;
Codex: `-m`/`-c model_reasoning_effort=…`; Antigravity: `--model` only — reasoning
is in the slug, e.g. `gemini-3.7-flash-high`, and `agy` rejects `--effort`).
Per-project defaults live in `~/.cymphony/config.json` as `agent`, `model`,
`effort` keys.

### Per-issue agent/model/effort

Choose the agent, model, effort, or provider for a single issue from Linear itself — add labels:

```
agent:codex   agent:antigravity   model:gpt-5.2-codex   effort:high   provider:cz1
```

or a directive line anywhere in the issue description:

```
cymphony: agent=codex model=gpt-5.2-codex effort=high
cymphony: agent=antigravity model=gemini-3.7-flash-high
```

Queue pins (card Edit / `POST /api/v1/queue-pin`) win over labels; labels win over the
directive; all win over project config. Resolution happens at dispatch and
is pinned for the run attempt; changes apply on the next dispatch/retry (running sessions keep
their spec). Unknown `agent:` values fall back with a warning; model/effort are pass-through
(bad values fail the run visibly and land in the retry queue).

### Combined usage

```bash
cymphony project AgentFarm agent codex cr 3 c oa1,oa2 port 4089
```

Runs project "AgentFarm" on Codex with 3 concurrent sessions rotating across oa1 and oa2 providers, with dashboard on port 4089.

## Architecture

The application is an escript CLI (`main_module: CymphonyElixir.CLI`) that starts an OTP supervision tree.

### Core Data Flow

```
CLI → CymphonyConfig → WorkflowStore → Orchestrator (GenServer, per-project) → AgentRunner (Task) → Agent.Runner (Port) → Agent.Claude | Agent.Codex | Agent.Antigravity adapter
```

1. **CLI** (`cli.ex`) — Escript entrypoint. Handles onboarding, multi-project mode, background process management, concurrency control, provider rotation, and legacy WORKFLOW.md mode.
2. **CymphonyConfig** (`cymphony/config.ex`) — Reads/writes `~/.cymphony/config.json`, generates temporary `WORKFLOW.md` with YAML front matter from project config. Converts `--concurrency` and `c` flags into workflow YAML.
3. **WorkflowStore** (`workflow_store.ex`) — GenServer that loads and hot-reloads `WORKFLOW.md`. Holds current workflow state per project.
4. **Config** (`config.ex` + `config/schema.ex`) — Validates workflow config via Ecto embedded schemas. Resolves `$ENV_VAR` references and provides typed access to all settings (tracker, polling, workspace, agent, claude, codex, antigravity, hooks, etc.).
5. **Orchestrator** (`orchestrator.ex`) — Central GenServer per project. Poll tick loop reconciles `waiting` via `Queue.reconcile`, dispatches the leftmost waiting card, enforces concurrency via `available_slots/1`, selects providers via `select_provider/1` (random rotation from `providers` list), handles retries with exponential backoff, tracks token usage, and detects stalled agents.
6. **AgentRunner** (`agent_runner.ex`) — Spawns a Task per issue. Creates workspace, runs lifecycle hooks, then calls `Agent.Runner` for multi-turn execution. Accepts `agent_kind`/`model`/`effort`/`provider_override` opts for this session.
7. **ShellProvider** (`cymphony/shell_provider.ex`) — Reads provider env vars (API keys, model config) from shell functions in `~/.cld`, `~/.zshrc`, or `~/.bashrc`. Sources the rc files in a zsh subprocess with `claude`/`codex`/`agy`/`antigravity` noop'd, calls the provider function, and captures env vars matching the active agent's prefixes (Claude: `ANTHROPIC_*`/`CLAUDE_CODE_*`; Codex: `OPENAI_*`/`CODEX_*`; Antigravity: `ANTIGRAVITY_*`/`GOOGLE_*`/`GEMINI_*` plus `API_TIMEOUT`; fallback keys `GOOGLE_API_KEY`/`GEMINI_API_KEY`). Results are cached via `persistent_term`.
8. **Agent behaviour** (`agent.ex`, `agent/runner.ex`, `agent/claude.ex`, `agent/codex.ex`, `agent/antigravity.ex`) — `Agent.Runner` owns the shared machinery (port spawn, SSH remoting, env injection, timeouts, workspace validation) and delegates argv construction + output parsing to the `CymphonyElixir.Agent` adapter for `agent.kind`. The Claude adapter drives `claude --bare -p … --resume`; the Codex adapter drives `codex exec --json` / `codex exec resume <id>` and parses its JSONL events; the Antigravity adapter drives `agy -p … --output-format stream-json` and resumes with `--conversation <id>` (never `-c`/`--continue`). The Antigravity adapter also appends two flags to **every** invocation it builds, fresh runs and `--conversation` resumes alike: `--new-project`, without which `agy` ignores its launch cwd and sandboxes itself into `~/.gemini/antigravity-cli/scratch` so no run ever writes into the Cymphony workspace and no PR is possible (escape hatch: `antigravity.new_project: false`; only an explicit `false` drops it); and `--log-file <workspace>/../.agy-<issue>.log`, because stdout only ever carries a generic "Agent execution terminated due to error." while the real cause (HTTP 400/429, auth) goes to the CLI's own log under `~/.gemini/antigravity-cli/log/<ts>.log`, which nothing can correlate to an issue. The log is a **sibling** of the workspace, never a file inside it: the workspace root is the cloned repo root and the prompt tells the agent to commit and push, so a log in the tree — which appends across retry attempts — lands in the pull request. The workspace comes from `run_spec.workspace` (the runner already snapshots it there for MCP descriptor writing) and the `..` is resolved lexically, so under SSH remoting the path names the remote workspace's sibling; the retention sweep removes stale `.agy-*.log` files along with stale workspaces. All three adapters append the active section's `extra_args` through the shared `Agent.append_extra_args/2` (non-empty string = raw trailing fragment, list = escaped item by item, anything else dropped); Codex puts them before the prompt, which stays its final positional. A nonzero CLI exit returns `{:agent_exit, status, tail}` where `tail` is a bounded tail of everything the CLI printed (newest 20 lines, then 2048 bytes, ANSI/control bytes stripped) — not just the unterminated leftover buffer, which is empty whenever the CLI printed a newline-terminated error line. That text is what the dashboard retry queue and the Linear abandonment comment show, so `AgentRunner` raises with the reason first (issue context follows in parentheses; the `Logger.error` above it is unchanged) and the Orchestrator uses `PublicEvent.format_diagnostic/1` to retain a bounded/redacted binary `message` for a `{exception, stacktrace}` task exit rather than the inspected tuple — the retry row truncates to 120 characters. Non-message exceptions render bounded sanitized fields, never arbitrary `Exception.message/1` callbacks. The same formatter sanitizes raw structured hook/task/cleanup reasons **before** inspection can encode invalid UTF-8 as reversible decimal bytes; safe tuple tags remain readable, named map/two-tuple credentials are redacted, and final retry/abandonment sanitation remains defense in depth. AgentRunner applies this boundary after its raw host-local failure log. The tail is ordered **newest line first** and the byte cap keeps the head, because every display truncates from the front after a ~50-character `agent exited: Agent run failed: {:agent_exit, 1, "` prefix; chronological order put the CLI's own error line past the cut on any streaming turn. Bounding, sanitizing, and redacting live in one shared helper, `Agent.failure_excerpt/1` (newest 20 lines, 2048 bytes, each line capped at 8 KB *before* the regexes — redaction cost is superlinear and a port line can be 1 MB): the runner's failure tail delegates to it, so the retry queue, `/api/v1/state`, the dashboard, and the Linear abandonment comment are covered by construction. A CLI that dies mid-request dumps its own environment, which published the live Linear API key to every one of those surfaces. The exit-0 failure paths are covered too: adapters never join a raw transcript into an error payload — `no_result_in_stream` / `no_json_output` / `json_decode_failed` carry `Agent.transcript_excerpt/1` and a decoded `turn_failed` payload goes through `Agent.redact_payload/1` (every binary in the structure, map keys kept). The live harness ring is redacted after its 2048-byte slice (`GET /api/v1/:issue/harness` and the dashboard pane carry the same bytes off the box); the on-disk debug transcript (`~/.cymphony/log/cymphony.log.N`) is deliberately **not** redacted — it never leaves the host and an operator debugging an auth failure needs the real bytes. Redacted (`Text.redact_secrets/1`): assignments (`NAME=v`, `NAME => v`, `NAME: v`, `"NAME": "v"`) whose name has a whole `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`PASSWD`/`PAT`/`CREDENTIAL`/`AUTHORIZATION`/`COOKIE` segment, a camelCase spelling (`apiKey`, `authToken`, `clientSecret`, …), or a compound `PWD`; `Authorization`/`Cookie` headers to end of line regardless of scheme (`Bearer`, `Basic`, or none — the scheme is not the secret); and bare vendor-prefixed credentials, case-insensitively (`sk-`, `lin_api_`, `gh[pousr]_`, `github_pat_`, `xox<a>-`, `AIza`, `ya29.`, `1//`, JWTs, `AKIA`, `npm_`, `hf_`). The variable name is kept so the diagnostic still says which one was involved. Two carve-outs keep diagnostics readable: the bare `NAME: value` form requires a **compound** name (`token: rate limit exceeded`, `Unexpected token: '<'`, and `KeyError: key: :model` survive; `MONKEY=banana` was never caught), and a name suffixed `_PATH`/`_FILE`/`_DIR`/`_ID`/`_NAME` keeps its value (`SSH_KEY_PATH=/home/…` names a location, not a secret). It is a redactor, not a scanner: an unnamed high-entropy string with no known prefix still passes through.
9. **Workspace** (`workspace.ex`) — Isolated per-issue directories with path safety validation, lifecycle hooks (after_create, before_run, after_run, before_remove), and SSH worker support. Optional retention sweep (`workspace.retention_days` in config) deletes stale workspaces every 6 hours, skipping currently-running ones; it also removes stale `.agy-<issue>.log` session logs the Antigravity adapter writes beside workspaces (a plain file, so it gets no `before_remove` hook — the hook runs shell in a workspace directory).
10. **Tracker** (`tracker.ex`) — Behaviour-based adapter for issue trackers. `Linear.Adapter` is the production implementation; `Tracker.Memory` is for testing.

### Concurrency

- `max_concurrent_agents` stored in Orchestrator `%State{}` struct (default: 10)
- `available_slots/1` computes `max_concurrent_agents - running_count` to limit dispatches per tick
- `cr N` CLI shorthand sets concurrency at startup and persists to config
- Per-host limit: `max_concurrent_agents_per_host` caps concurrent sessions per worker
- Auto-dispatch: as sessions finish, waiting issues fill open slots on next poll tick

### Dispatch pause (durable)

- Pause is a **persisted per-project preference**, not just process state. `Control.pause/resume`
  writes `dispatch_paused` (boolean) onto each in-scope `projects[]` entry in
  `~/.cymphony/config.json` via `CymphonyConfig.update_dispatch_paused/2`, alongside
  `queue_order` / `queue_pins` / `queue_priority_seen`.
- `Orchestrator.init/1` seeds `state.paused` from `CymphonyConfig.dispatch_paused?/2` **before**
  `schedule_tick(state, 0)`. A `handle_call` cannot be delivered until `init/1` returns, so the
  first `maybe_dispatch` already sees the persisted value — a paused project never dispatches once
  on boot and pauses afterwards. `refresh_runtime_config/1` never touches `paused`.
- All three surfaces persist: `POST /api/v1/pause|resume`, the drawer's global Pause/Resume
  (`pause_dispatch` / `resume_dispatch`), and the per-project header toggle
  (`toggle_project_pause`). None of them may call `Orchestrator.pause/1` directly.
- `Control.apply_scope/3` fans out to **every** in-scope orchestrator even after one project's
  persist fails, and returns the first error afterwards. Halting the fold left the projects
  behind the failure dispatching — the opposite of what "pause everything" asked for.
- The legacy single-orchestrator fallback for `{:project, name}` persists under `name`, never
  `nil`: `nil` means "every project" to `CymphonyConfig`, so a per-project Pause in legacy
  WORKFLOW.md mode used to write `dispatch_paused: true` onto the whole fleet.
- Because the flag is durable, all three surfaces must **report** a persist failure rather than
  claim success: the API answers `422 dispatch_pause_not_persisted` (and `422 project_not_found`),
  and the LiveView flashes "applied, but could not be saved …" while still reloading the board
  (the orchestrator half did happen).
- Every `CymphonyConfig` read-modify-write runs inside one node-wide lock
  (`:global.trans`), and `save/1` stages to a sibling temp file and renames. The orchestrator
  persists `queue_order` from its own poll tick, so an unsynchronized dashboard write silently
  dropped whichever field the other writer had just saved.
- `load_project_dispatch_paused/1` logs a warning when `config.json` exists but cannot be read
  or parsed (the seed is silently discarding a stop-work order); a missing file is legacy mode
  and stays silent.
- The write side mirrors that guard: `Control.persist_dispatch_paused/2` skips the write (and
  returns `:ok`) when `CymphonyConfig.exists?()` is false. In legacy WORKFLOW.md mode there is no
  config store, so nothing durable was lost — failing there made every pause/resume of a working
  pause answer `422` / flash "could not be saved". A config store that exists and cannot be read,
  parsed, or written is still an error.
- **Retries hold while paused.** A retry timer that fires while `state.paused` neither dispatches
  nor reschedules: the entry keeps its `attempt`, `failures`, `identifier`, `error` and original
  `due_at_ms`, gains `held: true`, and drops its `timer_ref`. Rescheduling would add `+1` to
  `attempt` per backoff cycle for the whole pause, inflating the delay and burning the
  `max_retry_attempts` budget on work that never ran. Stale `retry_token`s are still ignored;
  repeated firings are idempotent.
- `held` is in the orchestrator snapshot, the presenter payload, and `/api/v1/state`. A held
  entry's `due_in_ms` clamps to `0` forever, so the presenter must render **no** `due_at` for it
  (deriving `now + 0` produces a value that moves every second, which re-renders every project
  section on every payload load of an idle paused board) and the surfaces show "held" instead.
  On the dashboard that is a tag, not a sentence: `span.chip.chip--held` reading **Held**, beside
  the `chip--warn` "Attempt N". `.chip--held` is neutral (`--ink-mute` on `--surface-deep`, no
  amber) and the row gains `.retry-row--held`, which swaps `.retry-row`'s amber inset edge for
  `--ink-faint` — held is *suppressed*, not failing, and a fully paused board must not read as a
  wall of warnings.
- Fresh failures (crash, stall, spawn failure) still record a retry entry while paused — pause
  suppresses re-litigating an existing backoff, not the recording of a failure.
- `handle_call(:resume, …)` calls `release_held_retries/1`: every `held` entry is re-armed at 0ms
  with a fresh `retry_token` and the **same** `attempt`, so it is eligible immediately without a
  new backoff wait. Entries whose timer never fired keep their armed schedule untouched.
- The dashboard's per-row **Retry** button (`retry_issue` → `{:retry_issue_now, id}`) is an
  explicit operator override and still dispatches while paused; the gate covers the timer-driven
  backoff loop only.

### Retry admission and completed-ticket counters

- Capacity waits perform no retry-related tracker read and preserve coding-attempt/failure counts. Retry refreshes use the exact project-scoped by-ID query; moved or newly blocked issues are not dispatched.
- `Linear.RateLimit` shares HTTP429/explicit GraphQL rate-limit cooldowns across projects using the same endpoint and hashed authorization. Retry-After takes precedence over the native initial-backoff fallback. It is node-local; existing in-flight requests may finish and daemon restart clears the registry.
- `Agent.ProviderFailure` accepts only recognized CLI error envelopes, not words inside tool/test output. Typed authentication/quota refusals reach the orchestrator and park the affected assignment; unknown resets need manual action. Holds do not consume the coding-failure budget. Config/run-spec changes and known expiry are rechecked by the watchdog; explicit Retry may probe while paused but cannot bypass Linear cooldowns.
- `snapshot.completed_count` -> API `projects[].completed_count` / aggregate `counts.completed` is an uncapped set of distinct tracker-confirmed completed issue IDs for the current project run. A normal agent turn only becomes a pending completion until the tracker confirms completion. Canceled/duplicate/active issues do not count. Paused->Resume and fresh runtime startup reset that project's set; repeated Resume, page refreshes and worker retries do not. Prior-run worker completions cannot enter a restarted run.
- Recent100agent-run records remain a bounded durable history and are never used as the ticket counter. `MIX_ENV=test` pins the completion store as well as both log sinks to private test storage.

### Stall watchdog (`stall_timeout_ms`)

- Every tick, `reconcile_stalled_running_issues/1` compares each running session's silence
  (time since its last agent event, else since `started_at`) against
  `config.agent.stall_timeout_ms`. Past the timeout the worker is killed and the issue goes back
  through the retry queue. It exists to catch runs that hang without failing — a foreground
  server command (`mix phx.server`, `npm run dev`), an interactive prompt waiting on stdin, a
  wedged network read — which stop emitting events but never exit, so the slot would otherwise be
  held forever. `<= 0` disables detection (hand-authored `WORKFLOW.md` only).
- Per-project override: `stall_timeout_ms` (milliseconds) on a `projects[]` entry in
  `~/.cymphony/config.json`. `CymphonyConfig.to_schema_map/1` writes it into the generated
  `WORKFLOW.md` `agent` section next to `max_concurrent_agents`/`max_turns`, so it takes effect on
  the next generation/rewrite (add-project, agent-settings change, Linear connect) or daemon start.
- Only a **positive integer** is honored. Absent, `0`, negative, float, or stringified values fall
  back to `Defaults.stall_timeout_ms()` (`300000`, matching the schema default) — a typo must not
  silently disable the watchdog or emit front matter that fails `Schema.parse/1`. There is no CLI
  flag, API route, or dashboard control for it; it is a hand-edited config key.

### Per-project `extra_args` / `new_project` (hand-edited config keys)

Same shape as `stall_timeout_ms`: keys on a `projects[]` entry in `~/.cymphony/config.json` that
`CymphonyConfig.to_schema_map/1` writes into the generated `WORKFLOW.md`. No CLI flag, no API
route, no dashboard control.

- `extra_args` — pass-through CLI flags for the agent binary. Two accepted shapes:

  ```json
  "extra_args": {"antigravity": ["--new-project"], "codex": ["--full-auto"]}
  "extra_args": ["--add-dir", "/srv/shared"]
  ```

  A map is keyed by agent kind and **only the active kind's list is emitted**, into that kind's
  generated section — a project pinned to `codex` must never inherit the `antigravity` list. A
  bare list is the convenience form and applies to the active kind. Like providers, this is a
  per-kind setting, so it never lands in a section other than the active one — which also means
  per-issue overrides (an `agent:` label, a queue pin, a dashboard restart) run **without** any
  `extra_args`, exactly as they run without provider keys.
  Trust boundary: `extra_args` is operator-authored, hand-edited config and is treated as
  trusted — the string form is interpolated into the launch script raw (it can carry its own
  quoting, which also means it can carry arbitrary shell), and nothing validates that a flag
  makes sense for its CLI (a codex flag that expects a value will swallow the prompt
  positional). Escaping the list form is a formatting service, not a security boundary.
- Only a **list of strings** is honored. A bare string, a number, a list with a non-string
  member, or a map whose kind entry is not a string list is ignored and **logged as a warning**
  (`Ignoring invalid extra_args in config.json: …`) — unlike a numeric typo, a mistyped escape
  hatch is otherwise invisible. A map with no entry for the active kind is the normal case and
  stays silent. Nothing invalid is ever written into front matter that would fail
  `Schema.parse/1` and take the project down.
- The `WORKFLOW.md` field itself (`claude.extra_args` / `codex.extra_args` /
  `antigravity.extra_args`) accepts **either** a list of strings **or** a single string, so a
  hand-authored file written against the older string form keeps parsing. The list form is what
  the generator emits, because each item is shell-escaped individually; a string is appended raw
  as one trailing fragment (trusted operator input, may carry its own quoting).
- `new_project` — boolean, antigravity only. Absent means `true` and nothing is emitted (the
  adapter's default). **Only an explicit `false`** writes `antigravity.new_project: false` into
  the front matter and drops `--new-project`; `"false"`, `0`, and `null` keep the flag, because
  a typo here silently sends every run back into `~/.gemini/antigravity-cli/scratch`. In a
  hand-authored `WORKFLOW.md` the field casts through `Schema.LenientBoolean`: `true`/`false`
  and Ecto's string spellings parse normally, while any other value (`0`, `"no"`, `"off"`) is
  logged and treated as unset — falling back to the default `true` — instead of failing
  `Schema.parse/1` and taking the project down over a typo'd boolean.

### Per-project `claude_bare_mode` / `max_retry_backoff_ms` (flat config keys)

Flat keys on a `projects[]` entry in `~/.cymphony/config.json` (the project `agent` stays a
plain string). `to_schema_map/1` maps them to the native nested workflow fields:

- `claude_bare_mode` (boolean) → `claude.bare_mode`. Absent emits nothing, so the adapter default
  (`true`, `--bare`) applies; an explicit `false` is emitted and drops `--bare`, and an explicit
  `true` is emitted too. A non-boolean stored value is logged and ignored (default `true`).
- `max_retry_backoff_ms` (positive integer) → `agent.max_retry_backoff_ms`. Absent keeps the
  schema default (`300000`); `0`, negatives, floats and strings are logged and ignored rather than
  removing the cap or failing `Schema.parse/1`.
- `Config.update_agent_settings/2` accepts both keys next to `agent`/`model`/`effort`; `nil`
  deletes the key. Invalid values return `{:error, :invalid_claude_bare_mode}` /
  `{:error, :invalid_max_retry_backoff_ms}` before `config.json` is loaded, so a valid existing
  value is never replaced. Other `update_*` writers load-modify-save the whole project, so the
  keys survive unrelated saves and workflow regeneration.

### Generated `WORKFLOW.md` files (mode 0600)

- Generated per-project workflow files embed the Linear API key in cleartext
  (`tracker.api_key`), so they are written owner-only. `WorkflowGenerator.write/2` is the single
  writer: it stages the content in a `<path>.tmp-<n>` sibling that is chmod'd `0600` while still
  empty, then renames it over the target. The key never lands under a umask-derived mode (`0644`
  on the usual `022`), a file left loose by an older build is replaced with a `0600` one, the
  rewrite is atomic for the `WorkflowStore` reload poll, and a failed write leaves the previous
  file intact (the staged file is removed).
- All write paths go through it — `write_temp/2` (multi-project startup, dashboard/API
  add-project) and `ProjectSupervisor.rewrite_workflow/1` (agent-settings change, Linear connect).
  Never `File.write` a generated workflow directly.

### Provider Rotation

- `providers` list stored in Orchestrator `%State{}` struct
- `extract_providers/1` reads from the **active agent kind's** section (`config.claude.*`, `config.codex.*`, or `config.antigravity.*`): `providers` list first, single `provider` fallback
- `select_provider/1` picks randomly via `Enum.random(providers)` for even distribution
- `spawn_issue_on_worker_host/6` selects a provider per dispatch and passes it as `provider_override` to AgentRunner
- Dashboard can change a running session's provider (kill & restart with new provider)

### OTP Supervision Tree

```
CymphonyElixir.Supervisor (one_for_one)
├── Phoenix.PubSub
├── HarnessStream (ETS ring of live CLI stdout; after PubSub, before HttpServer)
├── Registry (ProjectRegistry, :unique)
├── Task.Supervisor (application-wide auxiliary callers; not runtime agents)
├── DynamicSupervisor (ProjectDynamicSupervisor)
│   ├── ProjectSupervisor (per configured project)
│   │   ├── WorkflowStore
│   │   ├── PortSupervisor (DynamicSupervisor of Agent.PortGuard children)
│   │   ├── Task.Supervisor (agents and bounded I/O jobs)
│   │   └── Orchestrator
│   └── LegacySupervisor (only in explicit WORKFLOW.md mode)
│       ├── WorkflowStore (global name)
│       ├── LegacyPortSupervisor
│       ├── LegacyTaskSupervisor
│       └── Orchestrator (global name)
├── HttpServer (Bandit + Phoenix)
└── StatusDashboard
```

Each project gets its own `ProjectSupervisor` with a `WorkflowStore` and `Orchestrator`, registered via `ProjectRegistry` for lookup by `{project_name, role}`.
The CLI starts `LegacySupervisor` on demand only for a direct `WORKFLOW.md` path, after `ensure_all_started`; the application and Burrito release can boot without a workflow. Its global store/orchestrator are named and supervised. A repeated legacy start with the same path is idempotent; a different path is rejected before changing the global workflow setting (stop the current runtime first). Store/orchestrator startup errors propagate to the CLI (so background startup does not claim a pidfile). Multi-project startup must not start this global runtime.

### Runtime-owned work and responsive controls

Project and legacy runtimes use `:one_for_all` with the store, port supervisor,
task supervisor, then orchestrator in startup order. Restart/removal shuts down
agents and joins port cleanup before starting a replacement. Keeping port guards
under a **separate** sibling supervisor also preserves that barrier when the task
supervisor itself crashes. Project registry cleanup includes both new roles.
Direct `CymphonyElixir.start_link/1` starts owner-linked unnamed supervisors; it
never silently places its agents beneath the application-wide task supervisor.

`Agent.PortGuard` owns each CLI/hook/local SSH port, monitors its worker, and
kills only its captured OS process group (or captured root PID when group
leadership is unavailable). Task-created shell scripts wait for a silent stdin
readiness marker until the guard captures the group, then close stdin before the
actual command. This prevents a fast-exiting wrapper from escaping capture.
Explicit per-issue restarts and timed-out cleanup jobs asynchronously reap the
old guard before dispatch suppression is lifted. Failed reaping is logged,
exposed as `polling.cleanup_error`, and retried without launching into the old
workspace. Intentionally detached/new-session descendants, whole-BEAM/host
failure, and remote-process cleanup across SSH are outside this local lifetime
guarantee (only the local SSH client group is owned); this is not remote
exactly-once execution.

Tracker/config refresh work is supervised and bounded: one coalesced poll (plus one
pending refresh), at most four per-issue validation intents, and at most four
active ancillary effects sharing the I/O budget. Intent slots refill within the
same poll; a per-poll attempted-ID set prevents transient failures from producing
a tight revalidation loop. Deadlines and monitor failures
release work or enter the explicit reaping phase. Config and prompt arrive as
typed data; results never merge a copied `%State{}` back into the owner. Results
recheck current configuration, pause, capacity, pins, claims and retry tokens;
running-state refreshes additionally match captured monitor references. Agent
messages carry per-run tokens, and tokenless messages are rejected for tokened
production runs. Startup/terminal cleanup, abandonment and retention sweeps run
outside the owner and suppress overlapping dispatch. The watchdog runs during
slow polls. Snapshots read cached state only; file/config refresh occurs at poll
boundaries, not during a snapshot call.

## Web Dashboard

The Phoenix LiveView dashboard (`lib/cymphony_elixir_web/live/dashboard_live.ex`) provides real-time observability. Enabled with `cymphony port <n>` (or `--port <n>`).

### Sections

- **Shell** — `section#dashboard-root.dashboard-shell` (`OverlayDismiss`) is a two-column grid: a persistent `nav.side-rail` and `div#dashboard-top.main-col`. The drawer (`aside.settings-drawer`) and the flash `div.toast-stack` are the rail's siblings, rendered last. Breakpoints are 1200 / 900 / 640: the rail condenses to 64px below 1200 and is hidden below 900 (the top strip regains the brand). Panels are `--surface` + a 1px `--line` hairline; the rail has its own `--rail-surface` token (dark: same graphite as `--surface`; light: `#EFEFEC`, *below* `--page` so the rail reads as anchored furniture instead of floating text on panel-white) — set it in both light blocks. The accent (Signal Cyan) is reserved for focus, primary buttons, the queue **Next** badge, the brand mark and the band's signature rule — never a data category.
- **Nav rail** — `nav.side-rail[aria-label]`, chrome rather than a section (not hideable by the display prefs). Order: `a.side-rail-brand` (→ `#dashboard-top`); `.rail-vitals` (running/queued numerals + the autonomy sentence, inside the `unless @payload_error` guard); `div#rail-nav.rail-group` with a `.rail-link` per anchor — Overview, one per project (`#project-<dom-id>`, `title` = name, `.rail-link-meta` = `running·waiting`), Completions when non-empty — each opening with a `.rail-led--run|retry|paused|idle|done` LED (precedence: paused > retrying > running > idle); then `.rail-foot` with the mode switch (`#mode-switch-rail`, `phx-update="ignore"`), theme toggle, Settings `[data-drawer-toggle]` and Refresh. The rail reads only `@counts` / `@projects` / `@completions` / `@polling` / `@version` and **never `@now`**, so a clock re-anchor cannot re-render it. `RailNav` (`phx-hook` on `#rail-nav`) only paints `aria-current`; every anchor works without it.
- **Top bar** — `header.command-bar`: slim, sticky, `--topbar-h` tall. Status badge (Live/Offline), version, Settings drawer toggle (CSS geometry on `[data-drawer-toggle]`, no ⚙), Refresh button. The mode switch (`#mode-switch-top`), the theme toggle (light / dark / system; CSS geometry on `.theme-toggle-button`, no ☀☾⌂ emoji) and `details#jump-menu.jump-menu` (`phx-hook="JumpMenu"`) are marked `.topbar-only-narrow` and painted only below 900px, where the rail is gone; the delegated layout script syncs every instance so the copies never disagree. The jump menu's `open` attribute is set by the browser and never server-rendered, so morphdom strips it on every patch — `JumpMenu` snapshots it in `beforeUpdate()` and restores it in `updated()` (and closes the menu when a link inside it is clicked, which native `<details>` would not). Below 900px it is the only section-jump control, so a patch closing it mid-read leaves the operator nothing. `.command-bar-brand` is hidden at ≥900px because the rail owns the brand there. `div.reconnect-note` sits under it, always in the DOM and painted only while the socket is in `phx-error`.
- **Instrument band** — `div.instrument-band.command-bar-row--metrics.section--metrics`, a hairline-divided strip of cells (not pills) with 26px/300 tabular numerals, rendered as a sibling of `header.command-bar` rather than inside it: running count, retrying count, total tokens (input/output), runtime, throughput sparkline (10-minute window), plus compact polling-countdown and rate-limit (Primary/Secondary/Credits) cells. Counts stay neutral ink — a nonzero Retry is not colored here; the retry rows below carry the amber. Advanced adds `.metric-pill--queue.section--queue` = `counts.waiting`. Simple mode labels the first two cells **Running** and **To retry** (mappings unchanged: `counts.running` and `counts.retrying`) — the rail already counts running and queued work, so a second word for the running count and a "Waiting" that means *retrying* here but *queued* there put three wait-words on one screen. Every cell is `flex: 1 0 auto`, so a band that wraps (rate limits present at 1600px) fills each row edge-to-edge instead of leaving a left-packed stub; `.metric-pill--ops` therefore carries no `max-width` and must reset `justify-content: flex-start` (the base cell centers on a *column* axis, and `--ops` flips the main axis to a row). A cell with nothing to report renders a static string and adds `.metric-pill-placeholder` (`--ink-faint`) to its value span — never a blank value, which reads as broken chrome: `—` for an empty States / Kinds breakdown, a flat `▁` baseline for the Tput sparkline before there are two token samples.
- **Per-project sections** — One `article#project-<dom-id>.project-section` per project (`dom_id` folds characters an HTML id cannot carry; it is the rail's anchor target). Header shows project name, counts (`N/M running · Q queued · R retrying`), paused state, and inline controls: concurrency input (`cr`), wrapping `form.project-agent-form` (`phx-change="preview_project_agent"`, `phx-submit="set_project_agent"`) with one `.spec-switcher` (`phx-hook="SpecSwitcher"`; trigger is `icon model effort`; panel is an icon strip plus Model/Effort flyouts — no Reset; hidden inputs keep stable ids `agent-<project>` / `model-<project>` / `#effort-<project>`; never embed the kind in the id; Effort hidden when the selected kind is `antigravity` — reasoning is in the model slug; picking a model opens Effort when present, otherwise the switcher closes) and **Set**. Providers input (`form[phx-submit=set_project_providers]`, `#providers-<project.name>`) is visible only when the selected kind is `claude` (`agent_settings.kind`). Changing the agent kind persists immediately (kind only; do not persist model/effort on preview) and hides/shows providers on the next render — do not delete persisted providers when hidden. Header **Set** still saves kind+model+effort. Both paths rewrite the project's generated `WORKFLOW.md` and overlay `config.json` so `snapshot.agent_kind` survives refresh. **Up next / Queue** (`section.queue-board.section--board`) sits **above** In Progress (`.session-row-list`): `div#queue-board-<project.name>.queue-board-list` (`phx-hook="QueueBoard"`) of `article.queue-card` rows. Hide the board when `waiting == []`. Empty-state iff `running`, `retrying`, **and** `waiting` are empty. Card face is id + title + Edit only (no Linear priority/state/agent chips); the printed rank comes from `data-rank-label` (1-based, zero-padded, CSS `::before`) while `data-rank` stays 0-based and hook-owned. Edit (`div#queue-edit-<project>-<identifier>.queue-card-edit`, `form.queue-edit-form`) pins `agent_kind` / model / effort for the next dispatch — empty/`keep` skips; no provider; do not kill. The form opens with a `span.menu-field-label` header — `Pin next run · <identifier>` (identifier in `.mono`) — so the popover names its own subject even when it is flipped above the card or the board scrolls under it. The sheet is a popover, not an inline block: `QueueEditPanel` (`phx-hook`, `layouts.ex`) fixes it to the viewport off the card's rect, flips it above the card when it would overflow the bottom, re-places on `resize`/`scroll`/`updated` (a patch drops the inline styles morphdom does not own), and dismisses on outside `mousedown` — exempting `.queue-card-edit-toggle` (else the click closing one sheet swallows the open of the next) and `.combobox-list`/`.combobox-panel`/`.spec-switcher`. `phx-click-away="dismiss_overlays"` is the server-side half of the same dismiss. In Progress opens with `div.session-grid-head.advanced-only`, a column-header row whose cells reuse the body column classes so `html[data-hidden-cols~=…]` hides header and column together. Each running session is a compact one-line row with issue identifier (linked, green run LED), title (or last activity), state/provider/agent/model/effort/host tags, runtime, tokens, and a Kill button; the disclosure caret is CSS geometry on `.session-row-disclosure` (no server-rendered ▸/▾). Click a row to expand and see session ID (copyable), workspace path (copyable), recent log events, a live **Harness** stdout pane (Follow/Paused; `HarnessStream` ring of 400 × 2048-byte lines; `section#harness-tail-<id>` unchanged), and `form.restart-form` (`phx-change="preview_issue_run_spec"`, `phx-submit="set_issue_run_spec"`) with the same `.spec-switcher` plus Provider (Claude only via `session_spec.suggestion_kind`). Session provider chips and the read-only Provider stat are hidden; agent chips are icons (`/icons/claude.png`, `/icons/codex.png`, `/icons/agy.png`). The retry queue lives inline **below** In Progress (not on the board).
- **Recent completions** — `section#completions-section.section-card.section--completions`. Last 100 sessions that wrapped up: identifier, agent/model chips, runtime, total tokens, ended-at timestamp. Collapsible; backed by the persistent completion store.
- **Settings console (drawer)** — Right-side panel, scrimmed while open. The scrim is `html[data-drawer="open"] body::after`: a real fixed element box, so it actually intercepts clicks (a box-shadow scrim lets them through). The click target becomes `<body>`, which `OverlayDismiss` treats as outside — the console closes and nothing underneath activates. `Escape` also closes it, via a delegated `keydown` listener in `layouts.ex` (not a hook: the open flag is an attribute on `<html>`, outside the LiveView container). Every console control carries an explanatory `p.settings-help` line. The Automation/Orchestrator controls (Pause/Resume, global concurrency, refresh interval) are additionally wrapped one-per-`div.settings-control-row` = control + exactly one `p.settings-help` line, so `.settings-control-row + .settings-control-row` rules a hairline between them; the Linear, Projects, Experience and Display groups keep their help copy as a group-level sibling instead. The refresh row's copy must say it is not Linear polling. Primary actions (Connect, Add project, Resume all, queue Pin) carry `.subtle-button--accent`; Pause all and Restart stay quiet. After Experience and before Automation (simple and advanced): **Linear** (`#linear-connect-form`, `phx-submit="connect_linear"`, `#linear-api-key`) and **Projects** (`#add-project-form`, `phx-submit="add_project"`; `#add-project-slug` is a searchable Combobox, not a native select; `#add-project-provider` visible only when assign `:add_project_kind` is `claude`, drafted by `preview_add_project`). Then orchestrator controls (global Pause/Resume — persists `dispatch_paused` per project; global concurrency `#drawer-global-concurrency`, which prefills the fleet value when every project agrees and otherwise stays empty with `placeholder="mixed"` — `placeholder="10"`, the schema default, when no project reports a limit; `#drawer-refresh-interval` / `set_refresh_interval` persisting `dashboard_refresh_seconds`) and client-side display preferences (density, section visibility including `{Board, board}`, session-row columns, completions length). Drawer fields use class `settings-field`. Display prefs persist per browser in localStorage (`cymphony-prefs`) as `data-*` attributes on `<html>` (`html[data-hidden-sections~=board] .section--board { display: none }`); no server state. Never put the raw Linear key in assigns or flashes. The Linear slug Combobox uses the LiveSocket `Combobox` hook; header/session/add-project/queue-card agent+model+effort use `SpecSwitcher` (`layouts.ex`, beside `HarnessTail`, `QueueBoard`, `Combobox` and `LiveClock`). `Combobox.setChrome` / `SpecSwitcher.setChrome` also toggle the closest `.queue-card`.

### User actions

| Event | Description |
|-------|-------------|
| `toggle_logs` | Expand/collapse a session row to reveal session ID, workspace path, recent logs, Harness stdout pane, restart-with-overrides form |
| `dismiss_stalled_alert` | Dismiss stalled-agent warning |
| `kill_issue` | Terminate a running session; reloads the payload immediately (the task sends `:reload_payload_now` after the call) |
| `retry_issue` | Immediately retry a queued issue (an explicit operator override: still dispatches while paused); reloads the payload immediately |
| `refresh_now` | Trigger Linear refresh from dashboard; reloads the payload immediately so `polling.checking?` flips at once |
| `set_issue_run_spec` | Kill a running session and restart it with pinned `agent_kind`/provider/model/effort overrides (empty / "keep" skips a field); reloads the payload immediately |
| `preview_issue_run_spec` | Draft the restart Harness/provider/model/effort pills. Switching kind hide/shows the Provider field (visible only when `session_spec.suggestion_kind` is `claude`). |
| `reorder_queue` | Params `project` + full identifier `order` list. Optimistic client reorder, then `Control.set_queue_order`, reload. Persists `queue_order` (not Linear). |
| `toggle_queue_edit` | Params `project` + `issue`. Toggle `{project, identifier}` in assign `:queue_edit_ids`. |
| `preview_queue_run_spec` | Draft `:queue_run_spec_drafts[{project, id}]` like `preview_issue_run_spec`. Kind change clears model/effort. No persist. No provider. |
| `set_queue_run_spec` | Hidden `project` + `issue`. Comboboxes preselect the card pin or the project header spec (no `keep`). Empty / keep in the payload still skip. `Control.set_queue_pin`. Does **not** kill (issue is not running). |
| `toggle_harness_follow` | Flip Follow/Paused on the expanded session's Harness stdout pane |
| `pause_dispatch` / `resume_dispatch` | Stop/start dispatching new issues for **all** projects; running sessions complete normally. `Control.pause/resume` persists `dispatch_paused` per project; a persist failure flashes an error (the orchestrators still paused) instead of reporting success |
| `toggle_project_pause` | Pause or resume dispatching for a single project from its section header. Goes through `Control.pause/resume({:project, name})` (never `Orchestrator.pause/1` directly) so it persists like the global buttons; a persist failure flashes "applied, but could not be saved" and still reloads the board |
| `set_concurrency` | Update `max_concurrent_agents` for **all** projects (legacy global form); persists to `~/.cymphony/config.json` |
| `set_project_concurrency` | Update `max_concurrent_agents` for a single project from its section header; persists to config |
| `set_project_providers` | Update the provider list (`provider` + `providers`) for a single project from its section header; persists to config and applies to next dispatch (running sessions unchanged) |
| `set_project_agent` | Update agent kind/model/effort for a single project from its section header; persists to `config.json`, rewrites the project `WORKFLOW.md`, applies to next dispatch |
| `preview_project_agent` | Draft the header agent/model/effort controls. When the kind actually changes to a known kind, persist kind only (`Control.set_agent_settings`), increment payload seq, and reload. Persist error keeps the draft and flashes; does not revert the select. |
| `connect_linear` | Settings drawer: validate + persist Linear API key to `config.json` `linear_api_key`; rewrite each project's `WORKFLOW.md` `tracker.api_key`; flash last-4 mask only |
| `add_project` | Settings drawer: add Linear project to `config.json`, write temp `WORKFLOW.md`, start supervisor (no daemon restart). Hidden/disabled until Linear is connected. |
| `preview_add_project` | Draft add-project slug/name/github/agent/model/effort/provider into the `:add_project_*` assigns, so a payload load mid-edit cannot wipe them. Switching kind hide/shows `#add-project-provider` (visible only when kind is `claude`). Default kind `""` hides provider. A successful `add_project` resets all seven. |
| `preview_field` | Generic draft for the free-text/number controls the payload also renders: hidden `field` names the slot (`concurrency:<project>`, `providers:<project>`, `global-concurrency`, `refresh-interval`), `value` is what was typed. Written into `:field_drafts`; the matching submit handler deletes the key on success. Not read by any other surface — it is purely what the input renders while the operator edits. |
| `set_refresh_interval` | Settings Automation: persist top-level `dashboard_refresh_seconds` from `#drawer-refresh-interval` (min 1, default 3). Does **not** change Linear `polling.interval_ms` or `POST /api/v1/refresh`. Open dashboards keep their assign until remount or this event. |

Each running session row shows the Linear issue identifier (linked to the issue), title (or last activity message when no title), state, provider, host, runtime, and total tokens at a glance. Expanding the row reveals priority badge, session ID, workspace path, and recent log events.

Theme toggle is purely client-side (CSS geometry on `.theme-toggle-button`, no emoji) — sets `data-theme` on `<html>` and persists to localStorage; system mode clears it to follow the OS `prefers-color-scheme` setting. `dashboard.css` ships the light palette twice: once under `:root[data-theme="light"]` and once under `@media (prefers-color-scheme: light) { :root:not([data-theme]) }`. Vanilla CSS cannot share a declaration block between an attribute selector and a media query, so the two are a maintained duplicate — edit both together. The `:not([data-theme])` guard keeps an explicit `dark` choice dark on a light OS.

Flashes render in `div.toast-stack` (fixed, bottom-right, `aria-live="polite"`) so an arriving message never shifts the board; the stalled-agent banner stays in flow because it is persistent state, not a notification. Display preferences in the settings drawer follow the same pattern (`cymphony-prefs` in localStorage → `data-density`/`data-hidden-sections`/`data-hidden-cols`/`data-collapsed-sections`/`data-completions-limit` attributes on `<html>`, including `{Board, board}`), so LiveView patches never clobber them and the page degrades gracefully without JS. Mount assigns `:queue_edit_ids` (`MapSet.new()`), `:queue_run_spec_drafts` (`%{}`) and `:live_connected` (`connected?(socket)`).

**The collapse chevron follows `<html>`, never `aria-expanded`.** `[data-collapse-toggle]` hides its JS-written `▸`/`▾` glyph (`font-size: 0`) and draws a CSS chevron, whose down/right rotation is keyed off the *same* `<html>` attributes that hide the section body: `html[data-ui-mode="simple"]:not([data-expanded-sections~="completions"]) [data-collapse-toggle="completions"]::before` and `html[data-collapsed-sections~="completions"] [data-collapse-toggle="completions"]::before`. There must be no `[data-collapse-toggle][aria-expanded="false"]::before` rule (`extensions_test.exs` refutes it): `aria-expanded` is server-rendered *inside* the LiveView container, so morphdom rewrites it to the template value on every patch while the content stays as localStorage left it — keying the only visible affordance off it flipped the chevron on every payload load. `syncPrefControls()` still writes `aria-expanded`/`aria-label` for screen readers; every write is guarded by a `getAttribute(…) !== value` check so the MutationObserver (which now watches `aria-expanded` as well as `aria-pressed`, to repair a patch-reset accessible name) cannot re-trigger the sync from its own edit.

`section.section-card.fleet-empty` ("No projects" + an accent `[data-drawer-toggle]`) replaces the board only when `@live_connected and @projects == []`. `projects: []` is also the default payload, so without the `:live_connected` gate the card flashed on every dead render of a board that does have projects. The assign is written once at mount and never again. `Presenter.state_payload/2` has to be able to *produce* that shape: a fleet with no orchestrator in `ProjectRegistry` and no registered legacy orchestrator returns a normal empty payload (`projects: []`, zeroed counts/token totals, `polling: nil`, no `:error`), not `snapshot_unavailable` — which stays reserved for an orchestrator that exists and cannot answer. Without that the card was dead markup and a zero-project daemon showed a red error card with no call to action.

### Refresh behavior

Server-side re-render is **change-only** and the second-by-second clock runs in the browser. `dashboard_refresh_seconds` is the single cadence for data-driven reloads.

- Runtime tick: every 1 second. It only schedules the periodic payload refresh — it must **never** `assign(:now, ...)`. Re-assigning `:now` on a timer re-renders every time-derived string in the template every second (this single line was ~55 DOM mutations/sec on an idle board).
- **A pubsub event sets `:payload_dirty` only.** `handle_info(:observability_updated, …)` never reloads and never re-stamps `:last_payload_refresh`. The orchestrator broadcasts twice per Linear poll (`polling.interval_ms`, default 5000) plus once per agent event, so reloading on the message made the *poll* interval the refresh interval — "I set refresh to 20s and it still refreshes every 5s" — and re-stamping the window on every broadcast disabled the configured gate outright. `:payload_dirty` must not be read by `render/1`, or it becomes the next `:token_samples`.
- The 1s tick reloads when the window elapsed **and** (`:payload_dirty` **or** ≥30s since the last load — `@idle_resync_ms`, the safety net that covers a dropped broadcast, `last_agent_timestamp`, and the poll countdown). Leading edge: an event landing after the window already elapsed reloads on the next tick (≤1s). The reload clears `:payload_dirty`.
- **User-initiated events reload immediately** via `reload_payload_now/1`, which also clears `:payload_dirty`. The async orchestrator commands (`kill_issue`, `retry_issue`, `set_issue_run_spec`, `refresh_now`) `send(pid, :reload_payload_now)` from their task **after** the `GenServer.call`, so the repaint is immediate *and* cannot race ahead of the state change; they used to get that for free from the orchestrator's own broadcast.
- Periodic payload refresh: `dashboard_refresh_seconds` from `~/.cymphony/config.json` (positive int, min 1, default 3 when missing/unreadable; not read from env). LiveView assigns `:payload_refresh_seconds` and `:payload_refresh_ms` (seconds × 1000). `:runtime_tick` compares now-`last_payload_refresh` against that assign — never a compile-time `@payload_refresh_ms`. Open dashboards keep their assign until remount or `set_refresh_interval` (`POST /api/v1/refresh-interval`). This is **not** Linear poll timing.
- Payload loads carry a generation token (`payload_seq`). After Connect / add-project / agent persist, increment seq and ignore stale `{:payload_loaded, seq, payload}` so an in-flight snapshot cannot revert `agent_kind` or Linear status.
- **Client-side clocks.** Every time-derived string is server-rendered **once per payload load** inside a span carrying a clock anchor, and the `LiveClock` hook advances it locally. The hook is registered in `layouts.ex` beside `HarnessTail` / `QueueBoard` / `Combobox` and mounts on a single wrapper `div#live-clock` around `#dashboard-root` (LiveView allows one `phx-hook` per element and `#dashboard-root` already runs `OverlayDismiss`). It runs one 1s interval, clears it on `destroyed`, and **must** also repaint on `updated` — every LiveView patch morphs the container and writes the spans back to the text of the last payload load, so without that the clocks rewind on each patch. Its formatting must stay byte-identical to the server formatters (pinned by `extensions_test.exs`): elapsed is `Mm Ss` under the hour and `Hh Mm Ss` from 60 minutes up (`due` shares the elapsed formatter on both sides), countdown is `Ns`. An anchor is always a remaining/elapsed **amount**, never an absolute wall time, so client clock skew cannot accumulate: `data-clock="countdown"` + `data-remaining-ms` (poll countdown), `data-clock="due"` + `data-remaining-ms` (retry due-in), `data-clock="elapsed"` + `data-base-seconds` (session runtime, stall duration). The global runtime tile is `elapsed` and adds `data-rate` = number of running sessions (that total advances one second per running session per wall second); there is no turns suffix. New time-derived text needs a `data-clock` anchor, or it will sit frozen between payload loads. A missing/unparseable anchor is skipped by the hook, leaving the server-rendered text (`n/a`, `unknown`, `now`) as the no-JS fallback. Poll `checking?` ("Checking…") stays server-rendered: it is data, not time.
- **Per-section assigns.** There is **no** `:payload` assign. A loaded payload is fanned into one assign per section — `:counts`, `:token_totals`, `:rate_limits`, `:polling`, `:projects`, `:running`, `:retrying`, `:completions`, `:payload_error` — by `assign_payload_sections/2`; nested `@payload.x` reads mark the whole template dirty on every load. A section whose value did not change is not reassigned. `generated_at` gets no assign. The comparison drops `@volatile_entry_keys` from every entry and recurses into a project's `:running` **and** its `:retrying`:
  - `tokens_per_second` — the presenter re-derives it from the wall clock every load, so it drifts on its own; the rendered `t/s` holds the value from the last load that moved a real field.
  - `last_event_at` — poked by the 2s harness heartbeat, which SPEC defines as a timestamp-only stall poke carrying no operator-visible news; the expanded row's `@ <timestamp>` holds the last real-move value. `last_event`, `last_message`, `log_events` and `tokens` stay in the signature, so anything real lands the fresh section wholesale.
  - `due_at` — an absolute time re-derived as `utc_now + due_in_ms`; every real reschedule also moves `attempt`, `held`, or `error`.

  One volatile field lives on a *section* rather than an entry, so `@volatile_entry_keys` cannot reach it: `polling.next_poll_in_ms`. The orchestrator re-derives it as `max(0, next_poll_due_at_ms - now_ms)` from a per-call monotonic reading, so it moves on every single snapshot — comparing it verbatim reassigned `:polling` on every payload load and made the empty-diff acceptance below unreachable in production. `section_signature(:polling, …)` collapses an integer countdown to a single marker, so only `checking?`, `paused`, `poll_interval_ms` (and `nil`, which means *no poll scheduled* — it drops the anchor and renders `n/a`) can move the section. Holding the previous value is lossless: the countdown is a `data-clock="countdown"` anchor the browser advances on its own, and `checking?` flips true on every tick and false when the cycle ends, landing the refreshed countdown twice per poll.

  A missing section falls back to `@default_payload`.
- **Draft-safe controls.** morphdom rewrites `input.value` from the server value on every patch and only spares the *focused*, non-hidden input, so every user-editable control renders from a draft assign once touched: `:field_drafts` (keyed `concurrency:<project>`, `providers:<project>`, `global-concurrency`, `refresh-interval`; written by `preview_field`, cleared on successful submit so an external `POST /api/v1/concurrency` becomes visible again), `:agent_setting_drafts`, `:issue_run_spec_drafts`, `:queue_run_spec_drafts`, and the `:add_project_*` assigns (slug/name/github included; all reset after a successful add). The drawer's Linear key (`#linear-connect-form`) and the client-owned prefs (`#settings-display`, `#settings-experience`, `#mode-switch-top`) are `phx-update="ignore"` instead — the server has no correct value to render for a secret or for localStorage state. A control with neither is reset by the next patch. Text/number inputs carry `phx-debounce="400"` so a keystroke does not cost a round trip and a full-container morph.
- **The `Combobox` hook owns its open state across patches.** A patch re-applies the panel's server-rendered `hidden`, strips `combobox--open`/`is-combobox-open`, rewrites the search value and every option's `hidden`/`aria-selected`, and blurs the search box by hiding its ancestor. `beforeUpdate()` snapshots query / active option **value** / focus + caret before the morph and `updated()` restores them (`setOpen(true)` → `search.value` → `filter` → `setActive` by value → `focus`/`setSelectionRange`); it must never fall back to `close()`, which clears the typed filter. Pinned by `extensions_test.exs`.
- **`:now` is a clock anchor, not a clock.** It is assigned at mount and re-anchored by a payload load **only when a section that a clock reads moved** (`@clock_sections`: `:token_totals`, `:running`, `:projects`). `@now` reaches the board through exactly three places — the `now` attr of `<.stalled_alert>` and `<.session_row>`, and the retry row's `due` anchor — so a re-anchor re-serializes those clock spans and not the project headers, queue cards or Comboboxes. Hanging a clock off a section that is not in `@clock_sections` renders a stale amount; keep the list in step with the `@now` reads in `render/1`.
- **No template-local bindings in `render/1`.** A `<% x = … %>` binding makes the HEEx compiler give up change tracking for **every dynamic after it** in that template, so one such line inside the per-project comprehension used to put the whole section's Comboboxes on the wire for a single harness stdout line (~12 patches/sec on an expanded row). Rows are function components instead — `<.stalled_alert>`, `<.project_agent_controls>`, `<.queue_card>`, `<.session_row>` — whose attrs are tracked one by one; project / queue / session / retry comprehensions carry `:key` for per-row diffs. A keyed queue reorder previously raised in LiveView 1.1.33 because the Next badge changed the row's structural template; it is now always present and hidden outside rank 0, keeping that template stable. The client `QueueBoard` hook owns the immediate visual move, while the server waits for an authoritative payload instead of optimistically reassigning `:projects`. A projected `:project_views` assign keeps header/editor metadata out of single-card diffs, and queue-only changes do not re-anchor unrelated clocks. A harness line still ships only the harness pane (`dashboard_live_test.exs` asserts no `combobox` / `queue-card` / `session-row-summary`, under 1 KB). Keep the components binding-free; a new `<% … %>` anywhere in `render/1` or in one of these components silently undoes this.
- Acceptance: an idle dashboard ships no per-second diff; **with sessions running and no real state change** a payload load ships an **empty** diff (LiveView skips the morph entirely for `%{}`, which is what leaves every input and every open dropdown alone) and reassigns nothing but `:token_samples`, which no dynamic reads; a 20s setting means at most one data re-render per 20s. "No real state change" includes a moved poll countdown — a live orchestrator moves it on every snapshot, so a test that echoes a frozen fixture back proves nothing and the acceptance payloads must advance it.

### Auth (optional)

Set `CYMPHONY_API_TOKEN=<secret>` in the environment before starting the daemon to require a bearer token on all dashboard and API routes. When unset, all routes are public (default for backward compat).

- API: `Authorization: Bearer <secret>` header.
- Browser: open `http://host:port/?token=<secret>` once — token is stored in the session cookie and the URL is cleaned up via redirect.
- 401 JSON response when missing/wrong.

Plug: `lib/cymphony_elixir_web/plugs/api_auth.ex`. Applied via `:browser` and `:api` pipelines in `router.ex`.

### API endpoints

Routes defined in `lib/cymphony_elixir_web/router.ex`:

| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | LiveView dashboard |
| `/api/v1/state` | GET | Full state snapshot JSON (`waiting` rows + `counts.waiting` / per-project `waiting_count`). A fleet with no orchestrator registered anywhere returns a normal empty payload (`projects: []`, no `error`); `snapshot_unavailable` / `snapshot_timeout` mean an orchestrator exists and could not answer |
| `/api/v1/linear` | GET | Linear connect status JSON (`connected`, `masked_key`, `source`). Never the raw key. Must be declared before the issue catch-all. |
| `/api/v1/linear` | POST | Body `{"api_key":"..."}`. Validate + persist `linear_api_key`; rewrite every registered project's generated workflow, continuing after individual failures. `202` status or `422` (`empty_api_key` / `invalid_api_key` / `linear_unauthorized` / `linear_error` / `linear_workflow_rewrite_failed`). The rewrite error means the key was saved but at least one workflow could not be updated. Never echo `api_key` or raw failure reasons. |
| `/api/v1/linear/projects` | GET | Accessible Linear projects `{"projects":[{"id","name","slug_id"}]}`. `422` `linear_not_connected` if no key. |
| `/api/v1/projects` | GET | Project list with running/retrying counts |
| `/api/v1/projects` | POST | Add + start a project (no daemon restart). Body `name` + `linear_project_slug` (+ optional github/workspace/agent/model/effort/provider). `202` `{name,linear_project_slug,started}`. `422`: `not_connected` / `invalid_project` / `duplicate_project_name` / `duplicate_project_slug` / `project_workflow_failed` / `project_start_failed`. The two failure codes after persistence say the project was saved but could not generate its workflow or start. |
| `/api/v1/:issue_identifier/harness` | GET | Live CLI stdout ring (`HarnessStream.snapshot`); optional `?project=`. Must be declared before the issue catch-all. |
| `/api/v1/:issue_identifier` | GET | Single issue details (optional `?project=` filter) |
| `/api/v1/refresh` | POST | Trigger Linear refresh (returns 202). **Not** `POST /refresh-interval`. |
| `/api/v1/refresh-interval` | POST | Body `{"value": N}` (pos int ≥ 1). Persist top-level `dashboard_refresh_seconds`. `202` `{"dashboard_refresh_seconds":N}`, `422` `invalid_refresh_interval`, or `422` `refresh_interval_not_persisted` when the value could not be written (it would revert on the next restart, so 202 would be a lie). Declare (and `match :*`) **before** `/api/v1/:issue_identifier`. Other methods `405`. Does not change Linear poll timing. |
| `/api/v1/pause` | POST | Stop dispatching new issues; running sessions continue. Optional `?project=<name>` to scope to one project. **Durable**: persists `dispatch_paused: true` on each in-scope project in `~/.cymphony/config.json`, so the project is still paused after a restart. Returns 202 `{"paused":true,"project":<name|null>}`, or `422` `dispatch_pause_not_persisted` when the flag could not be written (the orchestrators are paused but the next restart undoes it) / `422` `project_not_found`. Legacy WORKFLOW.md mode has no `config.json` and no flag to lose, so it still answers 202. |
| `/api/v1/resume` | POST | Resume dispatching new issues; persists `dispatch_paused: false` and releases retries held during the pause. Optional `?project=<name>`. Same 202 / 422 shapes as `/pause`. |
| `/api/v1/concurrency` | POST | Update `max_concurrent_agents` at runtime. JSON body `{"value": <int>}`, optional `?project=<name>`. Persists to `~/.cymphony/config.json`. Returns 202 only on success; `422` `concurrency_not_persisted` means applied in memory but not durable, `project_not_found` means no target orchestrator, and `invalid_scope` rejects malformed project params. |
| `/api/v1/providers` | POST | Update provider list at runtime. JSON body `{"value": "cv1,cz2,ck1"}` or a string list, optional `?project=<name>`. Aliases must be safe shell-function identifiers; malformed lists are `422` `invalid_providers`. Persists `provider` (head) + `providers` (full list) to `~/.cymphony/config.json`. Applies to next dispatch only — running sessions unchanged. Returns 202 with `{"providers": [...]}` only on success; `422` `providers_not_persisted` means applied but not durable. Also reports `project_not_found` / `invalid_scope`. |
| `/api/v1/agent` | POST | Update agent settings at runtime. JSON body `{"kind": "codex", "model": "...", "effort": "..."}` (each optional, at least one required; `kind` must be one of `claude`, `codex`, `antigravity`; empty string clears model/effort), optional `?project=<name>`. Persists to `~/.cymphony/config.json`, rewrites the project's generated `WORKFLOW.md`, and overlays `config.json` so `snapshot.agent_kind` survives refresh. Applies to next dispatch. Returns 202 only on full success; `422` `agent_settings_not_persisted` means the runtime change could not be fully saved/re-written. Also reports `project_not_found` / `invalid_scope`. |
| `/api/v1/queue` | POST | Sticky waiting order. Body `{"order":["LLM-51","LLM-12"]}`. Query `?project=` **required**. `202` `{"order":[...],"project":"Name"}` or `422` `{"error":{"code":"invalid_queue_order","message":"..."}}`. Declare (and `match :*`) **before** `/api/v1/:issue_identifier`. Other methods `405`. No Linear writes. |
| `/api/v1/queue-pin` | POST | Pin `agent_kind` / model / effort for a waiting issue. Body `{"issue":"LLM-51","kind":"codex","model":"...","effort":"..."}` (each of kind/model/effort optional; empty/`keep` skipped; at least one real field). Query `?project=` **required**. `202` `{"issue","agent_kind","model","effort","project"}` or `422` `invalid_queue_pin`. Declare (and `match :*`) **before** `/api/v1/:issue_identifier`. Other methods `405`. Does not kill. No provider. No Linear writes. |
| `/api/v1/completed` | GET | Recent completed sessions (last 100, in-memory ring buffer). Optional `?project=<name>` and `?limit=N`. |

All other methods return 405; all other paths return 404.

## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `CymphonyElixir.Workflow` and `CymphonyElixir.Config` (never read env vars directly in business logic).
- Agent kinds are the closed set from `CymphonyElixir.Agent.known_kinds/0` (`claude`, `codex`, `antigravity`). Select at run time with `cymphony agent antigravity`, a Linear label `agent:antigravity`, or a description directive `cymphony: agent=antigravity`. Antigravity provider env prefixes are `ANTIGRAVITY_` / `GOOGLE_` / `GEMINI_` (plus `API_TIMEOUT`; fallback keys `GOOGLE_API_KEY` / `GEMINI_API_KEY`). Provider prefixes are unchanged by dashboard Linear connect / add-project / agent persist.
- The dashboard expanded session row has a live Harness stdout pane (`HarnessStream`) and a per-session `.spec-switcher` (`phx-hook="SpecSwitcher"`) on `set_issue_run_spec`. Restart is `form.restart-form` (`preview_issue_run_spec` / `set_issue_run_spec`); empty/`keep` still skips a field. Agent kinds render as icons (`/icons/claude.png`, `/icons/codex.png`, `/icons/agy.png`), not the words claude/codex/antigravity.
- Per-project **queue board** (`section.queue-board.section--board`) sits **above** In Progress; retry stays **below**. Cards are `waiting` (active_states, not blocked Todo, not claimed, not running, not `retry_attempts`). Hide when `waiting == []`. Cymphony rank is row-major index (`0` = next slot), not Linear priority. `Queue.reconcile` owns sticky order (`Dispatch.sort_for_dispatch` is INITIAL ORDER only). Events: `reorder_queue`, `toggle_queue_edit`, `preview_queue_run_spec`, `set_queue_run_spec`. Mount assigns `:queue_edit_ids` and `:queue_run_spec_drafts`. Persist on the project in `~/.cymphony/config.json` (chmod 0600; never WORKFLOW.md / `Config.Schema`): `queue_order`, `queue_pins`, `queue_priority_seen`. Card Edit preselects pin or project header spec (no `keep` blank). Pins overlay `dispatch_run_spec/3` as pin > labels > directive > config; empty/`keep` in the payload still skips; no provider; do not kill. No Linear writes. Header counts `N/M running · Q queued · R retrying`. Display `{Board, board}`. `QueueBoard` hook on `div#queue-board-<project.name>.queue-board-list` in `layouts.ex` beside `HarnessTail` / `Combobox` / `SpecSwitcher` / `LiveClock`.
- Settings drawer (after Experience, before Automation; simple and advanced): Linear connect (`phx-submit="connect_linear"`, `#linear-api-key`) persists `linear_api_key` to `~/.cymphony/config.json` (chmod 0600; never log or flash the raw key) and add-project (`phx-submit="add_project"`) starts the new project without a daemon restart. `#add-project-slug` is a searchable Combobox (not a native select). `preview_add_project` drafts add-project agent/model/effort/provider. Automation includes `#drawer-refresh-interval` (`set_refresh_interval`). Drawer fields use class `settings-field`. `LINEAR_API_KEY` is `Schema.finalize_settings/1` fallback only.
- HTTP: `GET`/`POST /api/v1/linear`, `GET /api/v1/linear/projects`, `POST /api/v1/projects`, `POST /api/v1/queue`, `POST /api/v1/queue-pin`, `POST /api/v1/refresh-interval` (declare before `/api/v1/:issue_identifier`). `POST /refresh-interval` is **not** `POST /refresh` (Linear poll). `POST /queue` and `POST /queue-pin` require `?project=`; `202` / `422` / other methods `405`.
- Project-header / session / add-project / queue-card agent+model+effort is one `.spec-switcher` (`phx-hook="SpecSwitcher"` in `layouts.ex` beside `HarnessTail`, `QueueBoard`, `Combobox`, `LiveClock`). The compact trigger is `icon model effort`; the panel is an icon strip (claude/codex/agy) plus Model and Effort flyouts — no Reset. Hidden inputs keep stable ids `#agent-<name>`, `#model-<name>`, `#effort-<name>` (never embed kind/effort). `#add-project-slug` stays a Combobox. Effort row is hidden when the selected kind is `antigravity`. Picking a model opens the Effort flyout when it exists; with no Effort (antigravity) the switcher closes, and choosing the antigravity icon dismisses an open model flyout. Changing a known kind persists immediately (kind only). Header Set and `POST /api/v1/agent` rewrite the project `WORKFLOW.md` and overlay `config.json` so `snapshot.agent_kind` survives refresh.
- Provider pills/fields (`#providers-<name>`, `#add-project-provider`, restart `name=provider`) are visible only when the selected kind is `claude`. Hide for `codex`, `antigravity`, empty/default, and unknown. Do not delete persisted providers when hidden. Session provider chips and the expanded Provider stat are hidden. Queue-card edit has **no** provider field (Claude-only providers unchanged).
- `dashboard_refresh_seconds` is a top-level `~/.cymphony/config.json` key (pos int, min 1, default 3 when missing/unreadable; not env). `Control.set_dashboard_refresh_seconds/1` persists only. LiveView assigns `:payload_refresh_seconds` / `:payload_refresh_ms`. Not `polling.interval_ms`.
- Dashboard re-render is **change-only** and the per-second clock is client-side. `:runtime_tick` must never `assign(:now, ...)`. Time text is server-rendered once per payload load in a span carrying a remaining/elapsed **amount** (`data-clock` + `data-remaining-ms` / `data-base-seconds`, `data-rate` on the global runtime tile; no turns suffix) and the `LiveClock` hook (`layouts.ex` beside `HarnessTail` / `QueueBoard` / `Combobox` / `SpecSwitcher`, on `div#live-clock`, repaints on `updated`) advances it. New time-derived text needs an anchor or it freezes between loads. There is **no** `:payload` assign — one assign per section (`:counts`, `:token_totals`, `:rate_limits`, `:polling`, `:projects`, `:running`, `:retrying`, `:completions`, `:payload_error`), unchanged sections are not reassigned (comparison ignores a running entry's `tokens_per_second`, so the rendered `t/s` holds its last real value). `:now` is an anchor, re-anchored only when `@clock_sections` (`:token_totals`, `:running`, `:projects`) moved — it is read inside the per-project comprehension, and a comprehension is one change-tracked slot.
- Secret-bearing files are owner-only (`0600`): `~/.cymphony/config.json` via `CymphonyConfig.save/1`, the completion store, the MCP config, and generated `WORKFLOW.md` files via `WorkflowGenerator.write/2`.
- Regexes must be compiled at runtime with `Regex.compile!/1` (not sigils) for OTP 28 compat.
- Keep the implementation aligned with [`SPEC.md`](SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same change where practical so the spec stays current.
- Workspace safety is critical:
  - Never run Claude Code / coding agent turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/cymphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
- `AGENTS.md` for CLI, labels, dashboard Harness pane, queue board (`section.queue-board`, `reorder_queue` / `set_queue_run_spec`, `queue_order` / `queue_pins` persist), Linear connect / add-project, agent-select persist, SpecSwitcher (icon + model + effort), Combobox (slug), Claude-only providers, `dashboard_refresh_seconds`, and provider prefixes.

## Release Process

### CI (`make-all.yml`)

- Triggered on PRs and pushes to `main`
- Runs `make all` (setup, build, fmt-check, lint, coverage, dialyzer)

### Release (`release.yml`)

Triggered by pushing a `v*` tag. Three jobs:

1. **`build`** — Sets up mise + Zig, runs `MIX_ENV=prod mix release` with `BURRITO_BUILD=1`. Produces 3 Burrito binaries:
   - `linux` (x86_64)
   - `macos_intel` (x86_64)
   - `macos_arm` (aarch64)

2. **`package-deb`** — Builds `.deb` package from linux binary using `fpm`. Output: `cymphony_<version>_amd64.deb`

3. **`release`** — Downloads all artifacts, creates GitHub Release with `--generate-notes`

### Step-by-step release

1. Bump version in `mix.exs`
2. Commit and push to `main`
3. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`
4. Wait for CI (`make-all.yml`) to pass on `main`
5. Release workflow (`release.yml`) builds binaries + `.deb` and creates GitHub Release
6. Update Homebrew tap (`zaalipro/homebrew-cymphony`):
   ```bash
   curl -sL https://github.com/zaalipro/cymphony/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   # Update Formula/cymphony.rb with new url and sha256
   ```
7. Commit and push to the tap repo
8. Users install/upgrade via `brew update && brew upgrade zaalipro/cymphony/cymphony`

## Provider System

Providers supply the auth env vars the agent CLI uses (`ANTHROPIC_*` for Claude Code, `OPENAI_*` for Codex, `ANTIGRAVITY_*` / `GOOGLE_*` / `GEMINI_*` for Antigravity). Two sources:

### 1. Config-based providers (`~/.cymphony/config.json`)

Stored under the top-level `providers` key. Each provider maps to a set of env vars:

```json
{
  "providers": {
    "cz": {
      "ANTHROPIC_BASE_URL": "https://api.z.ai/coding/v4",
      "ANTHROPIC_API_KEY": "sk-zai-...",
      "ANTHROPIC_MODEL": "glm5-.1"
    }
  }
}
```

Set `provider` on a project to use one by default. Override per-run with `cymphony c <name>`.

### 2. Shell function providers (`~/.cld`)

Shell functions (e.g., `ck`, `ck1`, `cz`) sourced by `.zshrc`. Each calls `_unset` to clear `ANTHROPIC_*` vars, then sets new exports.

Cymphony resolves these via `ShellProvider`: shells out to zsh, noops `claude`/`codex`/`agy`/`antigravity`, calls the function, and captures the resulting env vars for the active agent's prefixes. Results are cached via `persistent_term`.

### Provider rotation

```bash
cymphony c cv1,cz2,ck1    # Distribute sessions across 3 providers
```

Comma-separated providers are randomly assigned per session. The first provider is set as the default; the full list is stored as `providers` in config. At dispatch time, `select_provider/1` picks randomly from the list for even distribution.

### Dashboard provider change

On the dashboard, each running session has a restart-with-overrides form (agent kind, provider, model, effort). Submitting it kills the session and immediately re-dispatches it via `set_issue_run_spec` (`:agent_kind`, `:provider`, `:model`, `:effort`).
