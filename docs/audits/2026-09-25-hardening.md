# Cymphony hardening audit — 2026-09-25

This report records the findings investigated and changes made on `main` in the 2026-09-25 hardening pass. It distinguishes an exploitable or correctness-relevant code path from a library advisory, and a focused regression test from the final integrated quality gate. No production endpoint, credential, or browser profile was used for the regression tests; tests used temporary config/workspace directories, local tracker endpoints, and fake agent commands.

## Findings and resolution

| Area | Finding and impact | Resolution |
| --- | --- | --- |
| Legacy startup | Direct `WORKFLOW.md` mode could report a started daemon with no supervised store or orchestrator. | Start a dedicated legacy runtime; reject a different workflow while it is active and propagate boot errors before claiming a pidfile. |
| Configuration and shell boundaries | A valid JSON array/scalar crashed normalization; provider aliases and clone URLs could reach shell syntax; concurrent queue-pin patches could overwrite each other; documented provider environment maps were unused. | Reject non-object config; validate provider names before shell use; escape clone URL as a positional argument; patch pins inside one config transaction; read provider environment maps for the active agent kind. |
| Retry ownership | A stale, terminal, missing, or failed final refresh could remove a retry record before dispatch, leaving a claim without runnable work. | Keep the retry entry until dispatch, explicit release, or re-arm. Preserve manual retry and pause-held behavior. |
| Public event retention | Raw event fields could expose credentials via state/API/dashboard, while unbounded JSONL lines and completed-event lists could exhaust memory. | Sanitize public projections (including secret-shaped keys), cap event/line/window size, retain bounded semantic result and usage milestones. The local debug transcript intentionally remains raw for operator diagnosis. |
| Project isolation and paths | Cleanup, presenter metadata, and `assignee: me` could use another project's default context; remote workspace paths could escape a configured root through traversal or symlinks. | Thread project config into cleanup and Linear lookup; snapshot the project workspace/stall metadata; physically validate remote containment before preparation, launch, hooks, and removal, rejecting a symlink at the issue leaf. |
| Workflow reload | Prompt changes were ignored and effective defaults were mistaken for explicit runtime overrides. | Load typed config and prompt as one version, retain the last-good pair on invalid reload, and reapply only explicitly changed control fields. Running sessions remain pinned. |
| Control plane | API/LiveView could acknowledge persistence or workflow-generation failure as success, or crash on malformed provider/project input. | Report partial outcomes and validation errors, keep runtime state visible, and fan out workflow rewrites even if one fails. |
| Runtime lifetime and responsiveness | Global agent tasks could outlive their project/legacy orchestrator; Port-owner death could leave an OS child; synchronous tracker work and sequential dashboard reads could block controls. | Runtime-local task and separate port-guard supervision, a positive reap barrier that reserves capacity through cleanup, fenced bounded async poll/intent work, bounded project snapshot fan-out, and one active plus one pending LiveView payload load. |
| Queue rendering | Keyed queue reorders could raise inside LiveView diff; removing keys avoided that exception but resent unrelated editor/section controls on a single-card update. | Keep explicit row keys and a fixed Next-badge template; project render projections and clock signatures bound row diffs without sacrificing open editor state. |

### Corrected lock finding

The original audit suspected `:global.trans({resource, self()}, fun)` did not serialize distinct callers. That is a false positive: Erlang's lock ID is `{resource, requester}` and mutual exclusion is keyed by the shared resource. Concurrent config-write and `after_create` tests demonstrated serialization. The lock shape was deliberately retained; the real queue-pin read/modify/write race was fixed by moving the entire patch into one transaction.

## Dependency advisories

The original `mix.lock` produced **32 Hex advisories in nine packages** (16 high, 11 medium, five low). This is package-level exposure, not proof that every exploit is reachable. The inbound dashboard stack (Bandit, Plug, HPAX, Phoenix, LiveView) is the priority when the optional listener is enabled, particularly on a non-loopback host. Request parsing precedes API authentication. The configured HTTP listener does not itself prove HTTP/2 reachability; long polling is disabled. Req/Mint issues generally require a malicious/compromised upstream or configured endpoint; `lazy_html` is test-only. Decimal's direct application path is a configured Ecto budget field, not a public arbitrary-decimal parser.

The lock now selects Bandit **1.12.5**, Plug **1.19.5**, HPAX **1.0.4**, Phoenix **1.8.9**, Phoenix LiveView **1.1.33**, Req **0.6.1**, Mint **1.10.1**, LazyHTML **0.1.13**, and Decimal **3.0.0** coordinated with Ecto **3.13.6** and Solid **1.3.1**. Jason **1.4.5** is also necessary for Decimal 3, and Thousand Island **1.5.0** for Bandit 1.12.5. These are the lock's only 13 changed entries; existing declared ranges in `mix.exs` remain unchanged. No blanket update or advisory ignore was used. A sanitized `mix hex.audit` under Elixir 1.19.5 / OTP 28 found no retired or security-advisory packages. The complete application quality gate passed on this lock.

## Architecture and limitations

- Work is owned by a project or legacy runtime. A separate sibling port supervisor preserves local process-group cleanup if the task supervisor crashes. An unexpected agent death or failed cleanup worker cannot release its old issue/capacity reservation until the original guards positively reap. Async workers return typed, fenced results; the orchestrator alone commits against current pause, generation, claim, capacity, queue, and retry state. This avoids stale copied-state merges and duplicate dispatch after ordinary runtime restart.
- Publicly retained event state is bounded and redacted at the retention boundary. CLI lines above **256 KiB** are rejected instead of accumulating indefinitely. The output window keeps semantic milestones; Antigravity fallback text is capped at **64 KiB** and marked when truncated. The host-local debug transcript is intentionally not redacted; operators must protect its filesystem access. The redactor is not a general secret scanner: unnamed high-entropy values without known prefixes may pass through.
- The OS guard can terminate local CLI, hook, and SSH client child process groups, but an SSH-partitioned or separately detached remote process cannot be given an exactly-once guarantee by local supervision. Tracker transition side effects also cannot be atomically rolled back against a later stale-generation fence.
- Remote path validation checks physical containment at operation and launch boundaries. It does not make an untrusted remote filesystem immune to every concurrent race after validation.
- The dashboard's default bind is loopback; an operator who exposes it must protect access and upgrade dependencies. Authentication does not mitigate pre-router parser resource exhaustion.

## Verification ledger

| Check | Evidence | Status |
| --- | --- | --- |
| Behavioral regressions | Task-specific RED/GREEN tests and scoped review reports in `.superpowers/sdd/2026-09-25-cymphony-hardening/`; focused Config/Control/Linear HTTP/dashboard run: 301/0. | Integrated by the final gate below. |
| Baseline dependency audit | `mix hex.audit` on unchanged lock: 32 advisories in nine packages. | Red baseline. |
| Targeted dependency resolver | Scratch copy of only `mix.exs`/`mix.lock`, with temporary exact patched floors, then a lock-only 13-entry main update. | Scratch and main `mix deps.get` passed. |
| Final Hex audit | Sanitized `mise exec -- mix hex.audit` after reviewed lock update. | `No retired or security advisory packages found`, exit 0. |
| Final quality gate | `mise exec -- env -u LINEAR_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u GOOGLE_API_KEY -u GEMINI_API_KEY -u CYMPHONY_API_TOKEN make all` under Elixir 1.19.5 / OTP 28. | Exit 0: escript build, format, specs, strict Credo, **1243 tests / 0 failures / 2 skipped**, **100% tracked coverage**, Dialyzer **0 errors**. Full log: `/tmp/cymphony-task9-make-all-4.log`. |
| Strict compilation | Sanitized `mix compile --warnings-as-errors` after final source/deps. | Exit 0, no project-source warnings. |

The first focused LiveView regression on the upgraded lock (`extensions_test.exs:1082`) was red: Phoenix LiveView 1.1.33 alone did not fix a keyed diff crash after optimistic queue reorder. The final UI fix removes the redundant optimistic server assignment, keeps row keys, stabilizes the badge template, and scopes project rendering so a single-card title diff remains bounded and an open editor survives reorder. Its scoped test suite passed 153/153; the full gate above covers the integrated code. An initial dependency recompilation printed an upstream Burrito 1.5.0 typing warning; the subsequent project-source warnings-as-errors compile exited 0.

No advisory ignore, coverage exemption, push, tag, or deployment is part of this pass. Remaining operational limitations above are not claims that all classes of SSRF, command execution, or duplicate work have been eliminated.

The two skipped tests are live end-to-end checks; no browser smoke test or real Linear/SSH production integration was run in this pass. The local process and HTTP fixtures verify the hardening paths, but deployment-specific network, proxy, and remote-host behavior still needs operator validation.
