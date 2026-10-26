# Unattended Linear access repair

> Execute the authorized repair inline with two bounded workers and one combined independent candidate review, under ALE-732/current policy.

**Goal:** Cymphony workers can read/update Linear unattended and stop on an explicit unchanged tool-permission refusal.

**Architecture:** Reuse native agent settings and provider hold machinery. Give the existing MCP server a packaged/development entrypoint that works from an unrelated bot directory. Approve only the two named Linear server namespaces in project-specific Claude arguments; preserve subscription login and existing domain safeguards.

**Tickets:** ALE-1405 / ALE-1406, native parent ALE-890, Cymphony reliability.

**Constraints:** No new hooks or global permission bypass; Actions suspended; no bot implementation or closure, broker probes, trading or runtime deployments. Preserve existing source/PR evidence, genuine holds, Proof pause, AGY removal and cap12.

**Review focus:** Server must start outside the Cymphony source tree; keys stay in the environment; stdout contains only JSON-RPC; quoted/malformed permission data cannot suspend work; actual model tool results and written-comment readback are mandatory.

- [ ] Reproduce bad MCP startup and Claude tool permission refusals; retain receipts.
- [ ] Prove and apply narrow project Claude permission settings with a bounded real Linear read/write/readback.
- [ ] ALE-1405 worker repairs shared MCP startup with failing/green unrelated-cwd transport checks.
- [ ] ALE-1406 worker classifies typed permission refusals and proves no repeated continuation/model calls.
- [ ] Run affected checks and required make all once for combined final candidate; obtain one independent exact-candidate review.
- [ ] Protected merge, controlled Cymphony-only install with rollback, delivered MCP and both Claude model checks, and native failed-worker recovery.
- [ ] Read back live state and update existing repair tickets/one receipt; release ownership.
