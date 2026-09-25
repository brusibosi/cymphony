# README screenshot provenance

Captured on **2026-09-25** from application source commit **`2cdd8e3`**. Subsequent changes in this refresh affect tests and documentation only, not the pictured UI. The source version is still 2.8.2; the latest published v2.8.2 release (2026-08-18) predates the hardening changes shown/described on `main`.

| Asset | View | Pixels |
| --- | --- | --- |
| `webui.png` | Advanced dashboard, dark theme, full overview | 1985 × 1443 |
| `webui-session.png` | Expanded Cymphony Demo session, light theme, project-region capture | 1645 × 1104 |

## Authenticity and data

Both files are genuine captures of the repository's Phoenix endpoint, LiveView, Presenter, CSS and icons, not generated mockups. They use an isolated localhost preview backed by inert fixture orchestrators: **Cymphony Demo** and **Docs Pipeline**, three running harness examples, three queued issues, two retries (one held), and two completions. Every issue, session, token count, duration, model selection and harness line is fictional demonstration data; none is a benchmark or evidence of actual provider availability. The workspace path visible in the detail view belongs to the disposable preview.

No production workflow, agent, Linear request or SSH session was started. The preview used a temporary HOME/config/log/database directory and offline catalog/tracker stubs. No user's browser tabs, cookies, local storage, or existing sessions were cleared or closed.

Known UI-copy caveat: the overview's “Cleared on daemon restart” completion hint is stale. Recent completions are persisted in `sessions.db`, as documented in the main README; the screenshot is unaltered.

## Capture and verification

- Browser: **ego lite**, native `ego-browser` agent API, one task-owned space and page.
- Actions checked: dashboard load and LiveView connection, Simple/Advanced mode, dark/light theme, session expansion, populated harness output, and visible held retry.
- Captured through the page's screenshot/CDP API; the detail image is a region of the actual rendered project. No synthetic UI text, content repaint, or post-capture compositing was used.
- The agent-created space was closed with `finish({keep: []})`; only the task-created local preview process was stopped.
- `tui.png` is an older terminal illustration retained in history/assets; it is not referenced by the current README as a fresh screenshot.

To refresh, run the current app renderer with isolated fictional fixture snapshots (never an operator's real config), capture the intended visible state in one ego lite task space, visually verify each PNG, update this date/source/provenance, and close only resources created for that task.
