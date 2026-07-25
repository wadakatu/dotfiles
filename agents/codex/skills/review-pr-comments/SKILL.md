---
name: review-pr-comments
description: Fetch and address GitHub pull request review feedback end to end, then commit and push accepted fixes and acknowledge each actionable thread. Use when Codex is asked to check PR review comments, respond to requested changes, fix unresolved review threads, handle reviewer feedback, re-check a PR after review, or automatically pick up actionable comments on the current or specified PR. Resolve the PR, retrieve complete thread-aware review context, implement all unambiguous actionable fixes, run relevant verification, commit and push the focused changes, react with thumbs-up when feedback is accepted, and reply with a reason when it is not accepted.
---

# Review PR Comments

Handle unresolved PR feedback as a verified implementation loop. Treat GitHub thread state as authoritative and keep every code change traceable to a review comment.

## Fetch review context

1. Read repository instructions and inspect the working tree before editing. Preserve unrelated changes.
2. Confirm `gh auth status`. Ask the user to run `gh auth login` if authentication is unavailable.
3. Resolve the target:
   - use the PR number or URL when supplied;
   - otherwise resolve the PR associated with the current branch.
4. Run the bundled script by using the absolute path of this skill directory:

```bash
python3 <this-skill-directory>/scripts/fetch_comments.py [PR_NUMBER_OR_URL]
```

5. Use `review_threads` for inline thread state. Flat comments do not preserve `isResolved`, `isOutdated`, or complete thread context.

## Classify feedback

Group feedback by behavior or file and classify it as:

- actionable: requests a concrete code, test, documentation, or behavior change;
- explanation-only: requests reasoning or clarification without requiring code;
- informational: approval, summary, observation, status output, or non-actionable bot noise;
- resolved or outdated: no implementation needed;
- ambiguous or conflicting: requires user direction before editing.

By default, implement every unresolved, non-outdated, unambiguous actionable item in the selected PR. Do not pause merely to ask the user to choose among independent actionable threads. Stop and ask only when comments conflict, materially expand scope, require a product decision, or could introduce a regression.

## Implement fixes

1. Read the commented code, related implementation, tests, and project documentation before changing anything.
2. Map each edit to one or more thread IDs, paths, and line anchors.
3. Use TDD for bug fixes when a focused regression test is practical: add or adjust a failing test, confirm the failure, apply the minimum fix, then confirm the test passes.
4. Keep refactors scoped to the feedback. Do not silently fix unrelated findings.
5. Run the narrowest relevant checks first, then broader checks in proportion to risk.
6. If the change affects frontend UI or UX, invoke `$frontend-live-verify` and complete its local browser verification before declaring the feedback addressed.
7. Re-fetch review context after implementation when comments may have changed during the work.

## Publish accepted fixes

1. Confirm the current local branch is the selected PR's head branch before committing. If it is not, preserve unrelated work and switch to the correct tracking branch; stop with the exact blocker if this cannot be done safely.
2. Inspect the final diff and stage only paths changed for accepted review feedback. Never include unrelated tracked or untracked work.
3. Do not create an empty commit. When accepted feedback produced changes, create one focused conventional commit whose message describes the review fix.
4. Push the commit to the selected PR's head branch. Never force-push.
5. Re-fetch thread state after the push before acknowledging comments. Do not acknowledge a thread whose requested change was not successfully pushed and verified.

## Acknowledge actionable threads

Treat invoking this skill as authorization to perform the acknowledgements below after verification and any required push succeeds.

- Accepted feedback: add only a thumbs-up (`THUMBS_UP`) reaction to the actionable review comment. Do not post a text reply.
- Not accepted feedback: do not add a thumbs-up. Reply in the review thread with a concise, concrete reason, including relevant evidence or tradeoffs.
- Ambiguous, conflicting, or unsafe feedback: treat it as not accepted for now and reply with the blocker or clarification needed. Do not implement, commit, or claim it is addressed.
- Informational, resolved, outdated, or duplicate feedback: do not react or reply unless a response is materially useful.
- Do not resolve review threads or dismiss reviews unless the user explicitly requests it.
- Before adding a reaction or reply, re-check the thread and avoid duplicating an existing equivalent reaction or response.

## Report results

Report each actionable thread with:

- thread ID and reviewer;
- requested change;
- changed paths or drafted explanation;
- verification result;
- commit SHA and push result when changes were made;
- acknowledgement performed: thumbs-up, explanatory reply, or none;
- status: addressed, needs clarification, intentionally not changed, or blocked.

List informational, resolved, outdated, and duplicate comments separately without presenting them as unfinished work.

## GitHub write safety

- Invocation of this skill authorizes focused commits, a normal push to the selected PR head branch, thumbs-up reactions for accepted actionable feedback, and explanatory replies for actionable feedback that is not accepted.
- It does not authorize force-pushes, resolving threads, dismissing reviews, submitting reviews, merging, closing the PR, or modifying unrelated GitHub content.
- Re-fetch thread state immediately before every reaction or reply.
- Never acknowledge an accepted comment until its change is verified and pushed successfully.
- Never expose tokens, cookies, authorization headers, private environment values, or other secrets in output or PR comments.
- If `gh` is rate-limited, unauthenticated, or unable to access the repository, report the exact blocker instead of using an incomplete comment view.
