# Issue tracker: GitHub

Issues and specs for this repo live in GitHub Issues for `lvivvde/deepseek-harness-ipad`. Use the `gh` CLI from this checkout.

## Conventions

- Create an issue: `gh issue create --title "..." --body-file <file>`.
- Read an issue and comments: `gh issue view <number> --comments`; fetch its labels with `gh issue view <number> --json labels`.
- List issues: `gh issue list --state open --json number,title,body,labels`, with appropriate `--label` and `--state` filters.
- Comment on an issue: `gh issue comment <number> --body-file <file>`.
- Apply or remove labels: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- Close an issue: `gh issue close <number>`.

For multiline bodies and comments, write the exact text to a temporary file and pass it with `--body-file`.

The remote identifies the repository; `gh` infers it when run inside this clone. Outside the checkout, pass `--repo lvivvde/deepseek-harness-ipad`.

## Pull requests as a triage surface

**PRs as a request surface: no.**

If this flag is changed to `yes`, triage external pull requests with the same labels and states as issues, using `gh pr view`, `gh pr diff`, `gh pr list`, `gh pr comment`, `gh pr edit`, and `gh pr close`. External authors have association `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE`.

GitHub shares one number space across issues and pull requests. Resolve an ambiguous number with `gh pr view <number>`, falling back to `gh issue view <number>`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments` and fetch its labels.

## Wayfinding operations

The canonical map is a GitHub issue labelled `wayfinder:map`. Decision tickets use
`wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`.
Refer to issues by linked title in human-facing text.

1. Create the map and tickets with `gh issue create --body-file <file>`. Attach each
   ticket through `POST repos/lvivvde/deepseek-harness-ipad/issues/<map-number>/sub_issues`
   with integer `sub_issue_id` (the REST issue id, not its issue number).
2. After creation, wire blockers through
   `POST repos/lvivvde/deepseek-harness-ipad/issues/<blocked-number>/dependencies/blocked_by`
   with integer `issue_id` for each blocking issue. Use native dependencies.
3. Query children with `gh api --paginate
   repos/lvivvde/deepseek-harness-ipad/issues/<map-number>/sub_issues`.
   For each open, unassigned child, query its `dependencies/blocked_by` endpoint.
   The frontier consists of children whose blockers are all closed, in child order.
4. Claim a frontier ticket before work with `gh issue edit <number> --add-assignee @me`.
   Apply `ready-for-agent` only to unblocked AFK tickets; human decisions stay open
   for a live exchange, even after their research prerequisites close.
5. Resolve with a comment containing the answer and asset links, then close the ticket.
   Re-read the map before appending a linked-title gist to Decisions so far, preserving
   concurrent edits. Store answer detail in the ticket, not in the map body.

Research assets live on `research/<name>` branches, linked from the claimed ticket
before research begins. Each branch holds a cited Markdown note under `docs/research/`.
Use an isolated checkout for each concurrent branch. Publish the note and its commit
link before closing; local-only notes are not sufficient for tracker resolution.
