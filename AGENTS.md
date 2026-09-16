# Agent contribution rules

## Knowledgebase update required for completed work

When an agent completes implementation work and creates a pull request, the same PR must include an update to `knowledgebase/`.

The update should:

- add the user-visible feature, fix, or operational change to `knowledgebase/CHANGELOG.md`;
- record any new or changed architectural/product decision in `knowledgebase/DECISIONS.md`; and
- update `knowledgebase/PROJECT.md` when the project purpose, supported workflow, or major boundaries change.

If no decision or project overview changed, state that explicitly in the changelog entry. Documentation-only PRs still follow this rule when they change project knowledge.
