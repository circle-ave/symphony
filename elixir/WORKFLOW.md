---
tracker:
  kind: linear
  required_labels: []
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  waiting_state: Waiting
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
repositories:
  selected: symphony
  allowed:
    - id: symphony
      name: Symphony
      url: https://github.com/openai/symphony
      branch: main
      tracker:
        project_slug: "symphony-0c79b11b75ea"
hooks:
  after_create: |
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  model_router:
    enabled: true
    router_command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
    default_profile: standard
    profiles:
      fast:
        command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5-mini"' --config model_reasoning_effort=medium app-server
        description: Small docs, config, or mechanical edits with low ambiguity.
      standard:
        command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
        description: Normal implementation work with moderate ambiguity.
      deep:
        command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
        description: Architecture, migrations, failed retries, rework, or risky user-facing changes.
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are working on Linear ticket `{{ issue.identifier }}` for {{ repository.name }} (`{{ repository.id }}`).
Prompt phase: `{{ phase }}`.

{% if attempt %}
Continuation context:
- Retry attempt #{{ attempt }}. Resume from the current workspace and workpad state.
- Do not repeat completed investigation or validation unless new changes require it.
{% endif %}

Issue:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Core rules:
- This is unattended orchestration. Never ask a human to perform follow-up actions.
- Work only in the provided repository copy.
- Linear access is required through Linear MCP or `linear_graphql`; if unavailable, stop with a blocker.
- Use exactly one active `## Codex Workpad` comment as the progress source of truth.
- Keep final replies to completed actions and blockers only. No user next steps.
- Move lanes only as specified here.

Status route:
- `Backlog`: do not modify; stop.
- `Todo`: move to `In Progress`, then find/create the workpad before analysis.
- `In Progress`: continue from the current workpad.
- `Human Review`: wait unless explicitly processing review.
- `Merging`: run the `land` skill loop.
- `Rework`: reset approach and rework.
- terminal states: do nothing.

{% if phase == "idle" %}
## Idle Packet

The issue is outside the active workflow. Do not edit code, comments, PRs, or issue state. Report that it is blocked by state only.
{% endif %}

{% if phase == "terminal" %}
## Terminal Packet

The issue is terminal. Do not modify anything. Report that no action was required.
{% endif %}

{% if phase == "review" %}
## Human Review Packet

- Do not code or change ticket content unless explicitly asked to process the review.
- Poll for human/bot review updates and GitHub PR comments.
- If processing review, use exactly one active `## Codex Workpad`, extract `Demo / Review Recipe`, run the visible browser review path, check console warnings/errors, and report the result for the reviewer.
- Treat login redirects, 404s, stale fixtures, and missing credentials as review failures/blockers.
- If feedback requires code changes, move the issue to `Rework` and follow the rework packet.
- The human reviewer owns final acceptance and lane decisions.
{% endif %}

{% if phase == "landing" %}
## Landing Packet

- Open `.codex/skills/land/SKILL.md` and follow it.
- Run the `land` skill in a loop until the PR is merged or a real blocker is recorded.
- Do not call `gh pr merge` directly.
- After merge completes, move the issue to `Done`.
{% endif %}

{% if phase == "rework" %}
## Rework Packet

- Treat `Rework` as an approach reset, not a tiny patch.
- Re-read the issue body and all human comments. Record what will be different this attempt.
- Close the existing PR tied to the issue.
- Reuse and rewrite the existing `## Codex Workpad`; preserve only still-useful historical facts in compact notes.
- Create a fresh branch from `origin/main`.
- Then follow the execution packet from workpad creation through validation, PR, and `Human Review`.
{% endif %}

{% if phase == "execution" %}
## Execution Packet

Startup order:
1. Fetch the current issue state.
2. If `Todo`, immediately move to `In Progress`.
3. Find/create one active `## Codex Workpad`; ignore resolved comments.
4. Reconcile existing checklist state before new edits.
5. Record environment stamp as `<host>:<abs-workdir>@<short-sha>`.
6. Add/update `Plan`, `Acceptance Criteria`, `Validation`, `Demo / Review Recipe`, and `Notes`.
7. Capture reproduction proof before code changes.
8. Run the `pull` skill before edits and record merge source, result, and HEAD.

Execution loop:
- Implement against the workpad checklist. Keep it current after meaningful milestones.
- Treat ticket `Validation`, `Test Plan`, or `Testing` sections as mandatory.
- For user-facing work, required acceptance includes an observe-only browser pass against the final review target; do not remount UI, patch app state, force success with internals, or count self-healing helpers as acceptance.
- Temporary local proof edits are allowed only for verification and must be reverted before commit.
- Before each push, rerun the required validation and fix failures.
- Merge latest `origin/main`, resolve conflicts, rerun checks, push, create/update PR, attach PR URL to Linear, and ensure the PR has label `symphony`.

PR feedback sweep before `Human Review`:
- Gather top-level comments, inline comments, and review summaries.
- Treat every actionable human or bot comment as blocking until code/test/docs address it or a justified pushback reply is posted.
- Re-run validation after feedback changes and repeat until no actionable comments remain.

Completion bar before `Human Review`:
- Workpad plan, acceptance criteria, and validation exactly match completed work.
- Required tests/validation are green for the latest commit.
- User-facing work has a passing independent acceptance review and current `Demo / Review Recipe`; include login credentials when required, otherwise `Login: not required`.
- PR checks are green, branch is pushed, PR is linked, and PR metadata is present.
- Only then move to `Human Review`.
{% endif %}

Blocked-access packet:
- Use only for missing required tools/auth/permissions after documented fallbacks.
- GitHub access is not a blocker by default; try alternate auth/remote/connector fallbacks first.
- If blocked by non-GitHub access, record missing item, impact, and exact unblock action in the workpad, then move to `Human Review`.

Out-of-scope improvements:
- Do not expand scope. Create a separate Backlog issue with clear title, description, acceptance criteria, same project, `related` link, and `blockedBy` when dependent.

Workpad skeleton:
````md
## Codex Workpad

```text
<host>:<abs-workdir>@<short-sha>
```

### Plan
- [ ] 1\. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria
- [ ] Criterion

### Validation
- [ ] targeted tests: `<command>`

### Independent Acceptance Review
- Verdict: `<pass/fail/blocked; not applicable only for non-user-facing work>`
- Claims tested: `<ticket-visible claims>`
- Evidence: `<screenshot/DOM/console/network/realtime observations>`

### Demo / Review Recipe
- Open: `<final review URL>`
- Login: `<not required, or required>`
- Username: `<required only when login is required>`
- Password: `<required only when login is required>`
- Verify: `<visible claims>`

### Notes
- <timestamped progress notes>

### Confusions
- <only include when useful>
````
