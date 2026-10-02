# Git usage

## Scope and preflight

Follow applicable `AGENTS.md` instructions and explicit user constraints. These rules govern Git operations; they do not authorize publishing, merging, or contacting reviewers outside the task's authorized scope.

Before edits or Git mutations:

1. Confirm the repository and checkout with `git rev-parse --show-toplevel`, `git status --short --branch`, and `git worktree list --porcelain`.
2. Identify the intended base branch/commit, current branch, active worktrees, and existing staged, unstaged, and untracked changes. Inspect relevant diffs; do not assume a clean checkout or that the current branch is the requested base.
3. Preserve changes owned by the user or other agents. Do not reset, clean, stash, overwrite, switch their branch, or rewrite their commits to make your task easier.
4. If the folder is not a repository, report that and perform applicable file work. Do not initialize a repository unless requested.

## Parallel work and worktrees

- Give each concurrent write stream its own branch and worktree. Reuse an existing suitable task-owned worktree when safe. Read-only reviewers may share a stable checkout. If worktrees are unavailable or prohibited, serialize writers rather than switching branches in a shared directory.
- The coordinating manager assigns an integration owner and records each stream's owner, absolute worktree path, branch, base commit, owned files, dependencies, and required checks. Pass this record in each agent's brief.
- Prefer the host's managed-worktree tools when available and follow their lifecycle rules. Otherwise use Git worktrees. Each worker runs commands with an explicit working directory or `git -C` pointing to its assigned worktree.
- Worktrees isolate files and indexes, but share repository metadata and refs. Never check out the same branch in multiple worktrees with force options. Coordinate branch/ref mutations and repository-wide configuration or maintenance through one owner. Avoid global Git configuration changes.
- Start independent streams from an agreed committed base. New worktrees do not contain another checkout's uncommitted changes. Transfer required changes explicitly as reviewed commits or a scoped patch, with ownership and user changes preserved.
- Assign one writer per file within a checkout. Across worktrees, avoid overlapping file/API changes where possible; establish contracts and serialize changes to shared schemas, lockfiles, migrations, or interfaces when they would conflict during integration.
- Isolate build outputs, ports, test databases, generated artifacts, and temporary paths too. A worktree does not isolate external services. Serialize tests that mutate the same resource.

CLI example, after resolving the actual paths and base commit (replace all placeholders; do not execute them literally):

```text
git -C "<repository>" worktree add -b feat/task-component "<new-worktree-path>" "<base-commit>"
git -C "<new-worktree-path>" status --short --branch
```

## Branches and commits

| Change         | Branch prefix | Commit type               |
| -------------- | ------------- | ------------------------- |
| Feature        | `feat/`       | `feat`                    |
| Fix            | `fix/`        | `fix`                     |
| Temporary work | `temp/`       | `temp` (local convention) |
| Maintenance    | `chore/`      | `chore`                   |
| Documentation  | `docs/`       | `docs`                    |
| Formatting     | `style/`      | `style`                   |
| Refactor       | `refactor/`   | `refactor`                |
| Tests          | `test/`       | `test`                    |
| CI             | `ci/`         | `ci`                      |

- Use a short descriptive branch suffix, for example `feat/login-page`. Follow a required host prefix if one exists. Do not rename an existing user branch merely to satisfy this convention.
- Use `<type>(<optional-scope>): <imperative summary>`, for example `fix(auth): reject expired tokens`. Mark breaking changes with `!` and describe their impact in the body.
- Keep each commit focused on one coherent change with its relevant tests/docs. Avoid unrelated formatting and generated noise. Correct unpublished task-owned commits when needed; do not rewrite shared history without authorization.
- Stage explicit owned paths or reviewed hunks. Inspect both `git diff` and `git diff --cached` as relevant, and run `git diff --cached --check` before committing. Never include someone else's staged changes, credentials, or unrelated files; avoid blanket staging in a dirty shared checkout.
- Do not commit or push to someone else's branch without authorization. Do not force-push without explicit authorization; if authorized, use an appropriate lease and verify the expected remote state.

## Integration

1. Each worker hands off its worktree path, branch, base and result commits (or scoped patch if commits are not authorized), changed paths, interface impacts, checks, and unresolved issues. Stop writes to the handed-off revision while it is being integrated.
2. One integration owner applies results in dependency order in the assigned integration checkout. Use the repository's merge/cherry-pick convention; do not blindly apply both a branch merge and its commits.
3. Resolve conflicts by understanding both changes and their contracts. Coordinate unclear intent with the responsible manager. Do not accept all of one side or discard unrelated edits to make conflicts disappear.
4. Inspect the combined diff and run required checks against the integrated revision. Isolated passing branches do not establish that their combination passes. Record the revision tested and rerun affected checks after relevant changes.
5. Pause only the dependent integration step when blocked; continue independent authorized work. Report unresolved conflicts and failing checks explicitly.

## Pull requests and merge rules

- Use the repository's PR template when present. Describe the problem, resulting behavior, relevant context, validation, and remaining limitations. If no template exists, use those fields directly.
- Required CI/CD checks, including configured GitHub Actions, must pass for the revision being merged. Local checks do not replace required CI; unavailable checks are unverified, not passed.
- Require at least one System Architect (SA) approval and any additional repository-mandated reviews. The author must not approve or merge their own PR. A subagent review is useful evidence but does not substitute for required repository approval.
- Merge only within the user's authorization and repository protections. Keep PR title and description aligned with the final diff. Do not message reviewers unless authorized.
- After confirmed merge and when cleanup is in scope, delete the task-owned source branch and retire its worktree safely. Preserve branches still used by another stream; record deferred cleanup.

## Safe cleanup

- Confirm all agents/processes have stopped using the worktree. Inspect tracked and untracked changes and needed ignored artifacts; preserve required outputs before removal.
- Verify the result was integrated or otherwise preserved. A squash merge may require checking PR status and resulting content rather than relying solely on ancestry.
- Archive managed worktrees through their host tool. For ordinary worktrees, use `git worktree remove "<verified-worktree-path>"`; do not recursively delete the directory or use force to bypass dirty-worktree protection.
- Remove only task-owned branches after checking they are no longer checked out or needed. Use normal branch deletion where possible; do not force-delete merely because squash history is not recognized as merged.
- Report the final branch/worktree state, validation results, and any deliberately preserved changes or deferred cleanup.
