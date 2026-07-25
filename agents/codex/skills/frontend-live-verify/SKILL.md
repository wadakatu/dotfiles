---
name: frontend-live-verify
description: Verify frontend UI and UX changes in the project's real local application with Chrome DevTools MCP, and record the evidence in the pull request. Use whenever Codex implements, changes, or fixes user-visible frontend behavior, including components, layouts, styles, interactions, navigation, forms, responsive behavior, accessibility behavior, loading/error states, and other UI/UX work. Also use before creating or updating a PR that contains such changes.
---

# Frontend Live Verify

Validate user-visible frontend changes in the real local application. Automated tests remain required where appropriate, but do not replace browser verification.

## Workflow

1. Read the project documentation, scripts, configuration, and current runtime state to identify:
   - the local application URL;
   - the command that starts the application, if it is not already running;
   - the exact page and data state needed to exercise the changed behavior.
2. Never guess a URL or route when the repository can provide it. For `studio-front`, use `https://front.studio.test` when project documentation confirms that environment.
3. Run the narrowest relevant automated tests before browser verification.
4. Use Chrome DevTools MCP (`mcp__chrome_devtools__*`) to open the local application. Do not substitute source inspection, unit tests, web search, or a different browser automation surface for this step.
5. Navigate through the UI as a user would and exercise the affected state. Inspect the latest page snapshot before interacting with elements.
6. Verify the visible result and the interaction behavior. Inspect relevant console errors and network requests when they can expose integration failures.
7. Capture screenshots when they materially demonstrate the changed state. Save artifacts in a temporary or ignored location unless the user requests tracked fixtures.
8. For a bug fix, demonstrate both sides when safely practical:
   - reproduce the failure with the pre-fix implementation or an equivalent controlled input;
   - restore the fix without discarding unrelated work;
   - repeat the same steps and confirm the corrected behavior.
9. Restore any temporary code or local data changes used only for reproduction. Never revert unrelated user changes.
10. Report exactly what was verified and what could not be verified. Do not call a check successful when the required page, authentication, data, or browser session was unavailable.

## Authentication and local data

- Ask the user to complete interactive login when authentication blocks the target page.
- Never read or expose passwords, tokens, cookies, authorization headers, or denied environment files.
- Create local test data through the project's documented development or seed mechanism when the scenario requires it. Keep temporary data setup scoped and reversible.
- Do not access production systems or mutate external data merely to complete local UI verification.

## Verification evidence

Collect concise evidence appropriate to the change:

- local URL and route;
- user actions performed;
- expected and observed visible result;
- before/after result for bug fixes when available;
- viewport used for responsive changes;
- relevant request status or console result;
- screenshot path when captured;
- limitations or unverified paths.

## Pull request requirement

When creating or updating a PR for UI/UX work, always add the browser verification result to the PR body. If verification is blocked or fails, record that honestly instead of omitting the section.

Use this format unless the repository has a stronger convention:

```markdown
## ローカル実機確認

- 環境: `<local URL>` / Chrome DevTools MCP
- 操作: `<steps performed>`
- 結果: `<expected and observed result>`
- Before/After: `<bug reproduction and corrected behavior, if applicable>`
- Console/Network: `<relevant findings>`
- 証跡: `<screenshot path or not captured>`
- 未確認事項: `<none or explicit limitations>`
```

Preserve all existing PR body content when inserting or updating this section.

## Blocking conditions

If the local application, Chrome DevTools MCP connection, authentication, or required data cannot be made available safely, stop before claiming completion. Explain the blocker and the exact user action needed. Do not create a misleading green verification entry.
