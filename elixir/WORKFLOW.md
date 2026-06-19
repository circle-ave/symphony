---
tracker:
  kind: linear
  required_labels: []
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  comment_reply_states:
    - Human Review
    - In Review
  waiting_state: Waiting
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
jira:
  site: $JIRA_SITE
  email: $JIRA_EMAIL
  api_token: $JIRA_API_TOKEN
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
agent:
  max_concurrent_agents: 6
  max_turns: 5
  ponytail: full
  scope_audit:
    enabled: true
    command: >-
      codex --config shell_environment_policy.inherit=all --config 'notify=[]'
      --config features.apps=false --config features.plugins=false --config features.browser_use=false
      --config features.chronicle=false --config features.computer_use=false --config features.image_generation=false
      --config features.memories=false --config features.multi_agent=false --config features.shell_snapshot=false
      --config features.tool_search=false --config features.tool_suggest=false --config features.workspace_dependencies=false
      --config skills.bundled.enabled=false
      --config 'model="gpt-5.4-mini"' --config model_reasoning_effort=medium app-server
    timeout_ms: 300000
codex:
  command: >-
    codex --config shell_environment_policy.inherit=all --config 'notify=[]'
    --config features.apps=false --config features.plugins=false --config features.browser_use=false
    --config features.chronicle=false --config features.computer_use=false --config features.image_generation=false
    --config features.memories=false --config features.multi_agent=false --config features.shell_snapshot=false
    --config features.tool_search=false --config features.tool_suggest=false --config features.workspace_dependencies=false
    --config skills.bundled.enabled=false
    --config 'model="gpt-5.5"' --config model_reasoning_effort=medium app-server
  tool_allowlist:
    isolated_home: true
    mcp_server_blocklist:
      - blender
      - chrome-devtools
      - computer-use
      - google-drive
      - node_repl
      - jira
      - playwright
    plugin_blocklist:
      - github@openai-curated
      - caveman@caveman-repo
      - documents@openai-primary-runtime
      - spreadsheets@openai-primary-runtime
      - presentations@openai-primary-runtime
      - linear@openai-curated
      - slack@openai-curated
      - google-drive@openai-curated
      - google-calendar@openai-curated
      - gmail@openai-curated
      - computer-use@openai-bundled
      - pdf@openai-primary-runtime
      - ponytail@ponytail
      - browser@openai-bundled
      - chrome@openai-bundled
    surfaces:
      root:
        mcp_servers:
          playwright:
            command: npx
            args:
              - "@playwright/mcp@latest"
              - "--headless"
      router:
        mcp_servers: {}
        plugins: []
      scope_audit:
        mcp_servers: {}
        plugins: []
      comment_reply:
        mcp_servers: {}
        plugins: []
  model_router:
    enabled: true
    timeout_ms: 60000
    router_command: >-
      codex --config shell_environment_policy.inherit=all --config 'notify=[]'
      --config features.apps=false --config features.plugins=false --config features.browser_use=false
      --config features.chronicle=false --config features.computer_use=false --config features.image_generation=false
      --config features.memories=false --config features.multi_agent=false --config features.shell_snapshot=false
      --config features.tool_search=false --config features.tool_suggest=false --config features.workspace_dependencies=false
      --config skills.bundled.enabled=false
      --config 'model="gpt-5.4-mini"' --config model_reasoning_effort=medium app-server
    default_profile: standard
    profiles:
      fast:
        command: >-
          codex --config shell_environment_policy.inherit=all --config 'notify=[]'
          --config features.apps=false --config features.plugins=false --config features.browser_use=false
          --config features.chronicle=false --config features.computer_use=false --config features.image_generation=false
          --config features.memories=false --config features.multi_agent=false --config features.shell_snapshot=false
          --config features.tool_search=false --config features.tool_suggest=false --config features.workspace_dependencies=false
          --config skills.bundled.enabled=false
          --config 'model="gpt-5.4-mini"' --config model_reasoning_effort=medium app-server
        description: Small docs, config, or mechanical edits with low ambiguity.
      standard:
        command: >-
          codex --config shell_environment_policy.inherit=all --config 'notify=[]'
          --config features.apps=false --config features.plugins=false --config features.browser_use=false
          --config features.chronicle=false --config features.computer_use=false --config features.image_generation=false
          --config features.memories=false --config features.multi_agent=false --config features.shell_snapshot=false
          --config features.tool_search=false --config features.tool_suggest=false --config features.workspace_dependencies=false
          --config skills.bundled.enabled=false
          --config 'model="gpt-5.5"' --config model_reasoning_effort=medium app-server
        description: Normal implementation work with moderate ambiguity.
      deep:
        command: >-
          codex --config shell_environment_policy.inherit=all --config 'notify=[]'
          --config features.apps=false --config features.plugins=false --config features.browser_use=false
          --config features.chronicle=false --config features.computer_use=false --config features.image_generation=false
          --config features.memories=false --config features.multi_agent=false --config features.shell_snapshot=false
          --config features.tool_search=false --config features.tool_suggest=false --config features.workspace_dependencies=false
          --config skills.bundled.enabled=false
          --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
        description: Architecture, migrations, failed retries, rework, or risky user-facing changes.
  approval_policy: never
  read_timeout_ms: 30000
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
- This is unattended orchestration. Never ask a human to perform repo, validation, deploy, or review actions.
- Clarification is allowed only by parking the issue: unresolved product, scope, acceptance, or target-surface ambiguity must be recorded in the workpad and the issue must be moved to `Waiting`, not guessed through implementation.
- Work only in the provided repository copy.
- Tool inheritance is deny-by-default via `codex.tool_allowlist`. Root agent profiles may use only the configured Playwright MCP server for headless browser proof; router, scope-audit, and comment-reply turns keep MCP/plugins disabled.
- Linear access is available through injected issue/workpad context and `linear_graphql`; use injected context first.
- Prefer targeted shell commands and searches.
- If the issue or latest human comment references a Jira browse link or imported Jira attachment note, call `jira_issue_attachments` before deciding scope or implementing. Use the downloaded local attachment paths as source evidence.
- Use exactly one active `## Codex Workpad` comment as the progress source of truth.
- Keep final replies to completed actions and blockers only. No user next steps.
- Move lanes only as specified here.

Status route:
- `Backlog`: do not modify; stop.
- `Todo`: move to `In Progress`, then find/create the workpad before analysis.
- `In Progress`: continue from the current workpad.
- `Human Review`: wait unless explicitly processing review.
- `Merging`: run the `land` skill loop.
- `Rework`: claim the issue as the configured agent if possible, move it to `In Progress`, then reset approach and rework.
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
- Poll for human/bot review updates and linked implementation comments.
- If processing review, use exactly one active `## Codex Workpad`, extract `Demo / Review Recipe`, run the visible browser review path, check console warnings/errors, and report the result for the reviewer.
- Reject review recipes whose primary `Open:` target is a PR, source diff, CI run, Linear issue, Jira issue, or other project tracker. Those links are validation evidence, not a functional demo.
- Reject review recipes that require reviewer setup, local services, localhost/loopback URLs, unpublished branches, seed scripts, or guessing. `Open:` must be an exact reviewer-reachable app/runtime/API/dashboard URL, and required login/data details must be in the workpad.
- Treat login redirects, 404s, stale fixtures, and missing credentials as review failures/blockers.
- If feedback requires code changes, move the issue to `Rework` and follow the rework packet.
- The human reviewer owns final acceptance and lane decisions.
{% endif %}

{% if phase == "comment_reply" %}
## Comment Reply Packet

- Handle only the latest actionable human comment. Do not replay the normal implementation workflow.
- If the comment asks for review recipe, demo recipe, validation-note, or workpad repair only, update the one active `## Codex Workpad` and reply with the outcome. Do not edit code, rerun full validation, publish branch changes, inspect Jira attachments, or dump browser/source responses unless the comment specifically requires fresh evidence.
- For review recipe repairs, preserve valid implementation/validation history, move PR/check/source metadata to `Validation` or `Notes`, and rewrite `Demo / Review Recipe` so `Open:` is an exact reviewer-reachable app/runtime/API/dashboard URL, `Login:` includes credentials when needed, and `Verify:` states observable ticket behavior.
- If no functional demo can be derived from the issue, active workpad, existing validation evidence, or directly linked artifacts, record the missing information in `Confusions` and move the issue to `Rework` so a normal agent can inspect the repo and repair the demo recipe.
- If the comment requires code changes, move the issue to `Rework` before changing files, then stop this reply turn.
- Include a concise reply to the latest comment and append the hidden Symphony comment marker.
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
- When this run starts from `Rework`, the orchestrator should already have claimed the issue as the configured agent and moved it to `In Progress`; keep using this rework packet for the approach.
- Re-read the issue body, the latest actionable human comment, and the active workpad. Fetch older comments only when acceptance depends on them, using small issue-scoped pages. Record what will be different this attempt.
- Reuse and rewrite the existing `## Codex Workpad`; preserve only still-useful historical facts in compact notes.
- Sync the configured development branch `{{ repository.branch }}` from `origin/{{ repository.branch }}`. Do not create a feature branch.
- Then follow the execution packet from workpad creation through validation and `Human Review`.
{% endif %}

{% if phase == "execution" %}
## Execution Packet

Startup order:
1. Use the injected issue state first; fetch only missing issue-scoped fields.
2. If `Todo`, immediately move to `In Progress`. If `Rework`, claim the issue as the configured agent if possible and move it to `In Progress` before work.
3. Find/create one active `## Codex Workpad`; ignore resolved comments.
4. Reconcile existing checklist state against the issue body, latest actionable human comment, active workpad, and directly linked review context before new edits. Existing workpad acceptance criteria are evidence, not authority.
5. Record environment stamp as `<host>:<abs-workdir>@<short-sha>`.
6. Add/update `Scope Confidence`, `Plan`, `Acceptance Criteria`, `Validation`, `Demo / Review Recipe`, `Notes`, and `Confusions`.
7. Run the Scope Confidence Gate before code changes.
8. Capture reproduction proof before code changes.
9. Run the `pull` skill before edits and record merge source, result, and HEAD.

Scope Confidence Gate:
- Restate the intended user-facing workflow, target users, target surfaces/modules, and acceptance criteria using only ticket text, active human comments, and directly linked artifacts.
- Mark `Scope Confidence: clear` only when one implementation path is strongly supported and testable.
- Mark `Scope Confidence: blocked` when the ticket supports materially different product interpretations, target surfaces/modules are unclear, acceptance cannot be verified, an existing workpad narrowed scope beyond the ticket, or implementation would choose between product definitions.
- Missing or non-reviewable demo/review recipe details are agent-reworkable; use `Rework`, not `Waiting`, unless underlying product scope, target surfaces, or acceptance behavior is ambiguous.
- If blocked, do not edit code, create branches, open PRs, or move toward review. Update the workpad `Confusions` with the minimal concrete questions, explain the impact, and move the issue to `Waiting`.
- When resuming a ticket, challenge the current workpad against the original issue and human comments before trusting checked boxes or prior acceptance criteria.

Execution loop:
- Implement against the workpad checklist. Keep it current after meaningful milestones.
- Treat ticket `Validation`, `Test Plan`, or `Testing` sections as mandatory.
- For user-facing work, required acceptance includes an observe-only browser pass against the final review target; do not remount UI, patch app state, force success with internals, or count self-healing helpers as acceptance.
- Every completed issue needs a functional `Demo / Review Recipe` that requires no reviewer setup. For backend, data, analytics, pipeline, or workflow work, publish or identify the app/runtime route, review environment, API endpoint, CLI command output artifact, or dashboard that demonstrates the ticket behavior. Do not use the PR, source diff, CI run, Linear issue, Jira issue, localhost, or an unpublished branch as the primary `Open:` target.
- Temporary local proof edits are allowed only for verification and must be reverted before commit.
- Before each push, rerun the required validation and fix failures.
- Rebase or merge latest `origin/{{ repository.branch }}`, resolve conflicts, rerun checks, commit on `{{ repository.branch }}`, and push that same branch. Do not create a feature branch or PR unless a human explicitly asks for one.

Review feedback sweep before `Human Review`:
- Gather only issue-scoped, paginated feedback needed to resolve actionable review comments.
- Treat every actionable human or bot comment as blocking until code/test/docs address it or a justified pushback reply is posted.
- Re-run validation after feedback changes and repeat until no actionable comments remain.

Completion bar before `Human Review`:
- Workpad plan, acceptance criteria, and validation exactly match completed work.
- `Scope Confidence` is `clear`, with no unresolved `Confusions`.
- Required tests/validation are green for the latest commit.
- User-facing work has a passing independent acceptance review and current no-setup `Demo / Review Recipe`; include login credentials when required, otherwise `Login: not required`.
- Non-user-facing work may mark independent browser acceptance as not applicable, but its `Demo / Review Recipe` must still demonstrate runtime/app behavior through an exact reviewer-reachable URL or artifact and must not be a PR/status-check/local-setup inspection recipe.
- Shared development branch commit is pushed and required checks are green.
- Review readiness proof includes `developmentBranchReviewed: true`, `sharedBranchCommitted: true`, `targetContainsSharedBranchCommit: true`, `reviewBranch: "{{ repository.branch }}"`, `reviewRecipeAccessible: true`, and `reviewRecipeUrl` matching the workpad `Open:` target.
- Only then move to `Human Review`.
{% endif %}

Blocked-access packet:
- Use only for missing required tools/auth/permissions after documented fallbacks.
- Product, scope, acceptance, and target-surface ambiguity are not access blockers; use the Scope Confidence Gate and move the issue to `Waiting`.
- GitHub access is not a blocker by default; try alternate auth/remote/connector fallbacks first.
- If blocked by non-GitHub access that prevents implementation or required acceptance, record the missing item, impact, and exact unblock action in the workpad, then move to `Waiting`.

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

### Scope Confidence
- Verdict: `<clear/blocked>`
- Intended workflow: `<who does what and where>`
- Target surfaces/modules: `<specific surfaces/modules, or blocked>`
- Acceptance source: `<ticket/comment/artifact evidence>`

### Acceptance Criteria
- [ ] Criterion

### Validation
- [ ] targeted tests: `<command>`

### Independent Acceptance Review
- Verdict: `<pass/fail/blocked; not applicable only for non-user-facing work>`
- Claims tested: `<ticket-visible claims>`
- Evidence: `<screenshot/DOM/console/network/realtime observations>`

### Demo / Review Recipe
- Open: `<exact final app/runtime/API/dashboard review URL; no reviewer setup; never localhost, PR, source diff, CI run, Linear issue, or Jira issue>`
- Login: `<not required, or required>`
- Username: `<required only when login is required>`
- Password: `<required only when login is required>`
- Verify: `<observable ticket behavior; PR/check metadata belongs in Validation or Notes>`

### Notes
- <timestamped progress notes>

### Confusions
- <unresolved questions; if any remain, issue belongs in Waiting>
````
