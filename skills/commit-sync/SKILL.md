---
name: commit-sync
description: Pause Claude Code work and commit/push dirty repo state when asked for "commit-sync", "checkpoint", or "sync to origin".
---

Pause the active task. Report repo-scope state with `git status --short --untracked-files=all`, current branch, and origin remote. Wait for explicit acknowledgement before staging, committing, or pushing.

After acknowledgement, stage the full dirty tree with `git add -A -- .`, commit all scoped changes, capture the commit SHA with `git rev-parse HEAD`, and push with `git push origin HEAD:<current-branch>`. Report the push result.

Never force push, rewrite history, rebase, reset, or discard unrelated user changes.
