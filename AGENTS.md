# Agent contribution rules

## Starting work in a new chat

- At the start of a new chat, fetch the latest `origin/main` and create a new working branch from it before making changes. Use a descriptive branch name with the `codex/` prefix unless the user specifies another branch.
- If an agent is already working in the current working copy, create and use a separate Git worktree for the new chat so the agents do not interfere with each other's changes.
- Do not reset, overwrite, or otherwise discard existing working-copy changes when preparing a branch or worktree. If the current checkout cannot safely be updated because it has uncommitted work, keep that work intact and create the new worktree from the fetched `origin/main` instead.

## Knowledgebase update required for completed work

When an agent completes implementation work and creates a pull request, the same PR must include an update to `knowledgebase/`.

The update should:

- add the user-visible feature, fix, or operational change to `knowledgebase/CHANGELOG.md`;
- record any new or changed architectural/product decision in `knowledgebase/DECISIONS.md`; and
- update `knowledgebase/PROJECT.md` when the project purpose, supported workflow, or major boundaries change.

If no decision or project overview changed, state that explicitly in the changelog entry. Documentation-only PRs still follow this rule when they change project knowledge.
