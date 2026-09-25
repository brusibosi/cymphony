# Pre-push Test Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove four observed test-harness races before the authorized `main` push, without changing application behavior or weakening assertions.

**Architecture:** Match the snapshot API's documented transient result, make the fake SSH client participate in port readiness, and wait for completed asynchronous poll cycles rather than fixed sleeps or a fleeting idle window. Reuse existing synchronization helpers; leave production modules unchanged.

**Tech Stack:** Elixir 1.19.5 / OTP 28, ExUnit, shell fixtures.

**Spec:** Existing snapshot, PortGuard readiness, and asynchronous polling contracts in `lib/cymphony_elixir/orchestrator.ex` and `lib/cymphony_elixir/agent/port_guard.ex`; `AGENTS.md`. No separate design spec is needed for these test-only corrections.

## Global Constraints

- Work directly on `main`, as explicitly authorized by the user.
- No production changes, disabled tests, weakened security/lifecycle assertions, or blanket timeout increases.
- Only one Mix process for this repository at a time. Unset credentials after `mise exec`.
- Do not edit the README or screenshot assets in this task; they are independently reviewed and owned by the controller.
- The controller owns commits and the normal, non-force push after review and the full gate.

### Task 1: Synchronize the four failing test paths

**Files:**
- Modify: `test/cymphony_elixir/final_review_regression_test.exs`
- Modify: `test/cymphony_elixir/workspace_and_config_test.exs`
- Modify: `test/cymphony_elixir/core_test.exs`
- Modify: `test/cymphony_elixir/orchestrator_status_test.exs`

**Interfaces:**
- `Orchestrator.snapshot(pid, 100)` returns a map, `:timeout`, or `:unavailable`.
- `PortGuard.prepare/1` gates remote shell execution on one stdin readiness line.
- `Orchestrator.run_poll_cycle_for_test/1` requests/coalesces a cycle and waits for polling to finish with a scheduled next poll.

- [x] **Step 1: Preserve the red evidence.** The pre-push `make all` run on `2cdd8e3` produced 1,267 tests, four failures, and two skipped tests. Its log is `.superpowers/readme-push-gate.log`. Failures were snapshot atom dereference, missing remote removal-hook trace, premature missing-issue state assertion, and an unobserved 50ms poll idle window. Read the failures and affected contracts before editing.

- [x] **Step 2: Match the snapshot result inside the existing retry poll.** Keep the 100ms call and existing bounded `eventually` helper. Do not alter redaction assertions.

```elixir
retry =
  eventually(fn ->
    case Orchestrator.snapshot(pid, 100) do
      %{retrying: [entry | _]} -> entry
      %{retrying: []} -> nil
      :timeout -> nil
      :unavailable -> flunk("orchestrator became unavailable while waiting for retry")
    end
  end)
```

- [x] **Step 3: Make the fake SSH lifecycle client read readiness before logging or exiting.** Insert immediately after its `#!/bin/sh` line, retaining all argv/path/hook assertions:

```sh
IFS= read -r __cymphony_guard_ready || exit 1
```

- [x] **Step 4: Fence missing-issue reconciliation.** In the missing-running-issue test only, remove the startup `Process.sleep(50)` and replace `send(pid, :tick)` plus `Process.sleep(100)` with:

```elixir
assert :ok = Orchestrator.run_poll_cycle_for_test(pid)
state = :sys.get_state(pid)
```

Keep the configured 30,000ms interval and assertions for removal from running/claimed, terminated worker, and preserved workspace.

- [x] **Step 5: Observe countdown reset without racing the next automatic tick.** In the countdown-reset test only, configure `poll_interval_ms: 5_000`. Replace forged polling state, the raw `:run_poll_cycle` message, and the 200ms wait with the existing cycle-completion helper. Keep integer/nonnegative countdown assertions and assert the configured interval and its upper bound:

```elixir
assert :ok = Orchestrator.run_poll_cycle_for_test(pid)
snapshot = GenServer.call(pid, :snapshot)
assert %{polling: %{checking?: false, poll_interval_ms: 5_000, next_poll_in_ms: next_poll_in_ms}} = snapshot
assert is_integer(next_poll_in_ms)
assert next_poll_in_ms >= 0
assert next_poll_in_ms <= 5_000
```

The larger *poll interval* prevents a new cycle from obscuring the completed cycle; it is not a looser test deadline or production setting.

- [x] **Step 6: Verify the focused suite, repeat the affected tests, and format only the touched files.** Prefix every Mix command with `mise exec -- env -u LINEAR_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u GOOGLE_API_KEY -u GEMINI_API_KEY -u CYMPHONY_API_TOKEN`. Run the four complete test files with `--seed 291596`, then repeat the four affected selectors at least three times with independent seeds. Use line selectors matching the edited file locations. Preserve failures if any and investigate; do not disable assertions. Run `git diff --check`.

- [ ] **Step 7: Review and integrate.** Return the precise diff, root causes, commands/results, and any limitations in the task report. The controller requests an independent review, reruns `make all && mix compile --force --warnings-as-errors && mix hex.audit`, updates the README verification snapshot, and commits only the intended files before the authorized push. No release, tag, deployment, or force push.
