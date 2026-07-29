---
name: regards-pr-review
description: Run and consolidate the Regards repository's staged multi-agent pull-request review. Use when reviewing a branch, PR diff, or uncommitted worktree against the architecture, privacy, accessibility, testing, and quality gates.
---

# Regards PR review

Review the current branch against `main` unless the user supplies another ref.
Treat the literal target `worktree` as all tracked and untracked changes against
`HEAD`.

## Pre-flight

1. Read `ARCHITECTURE.md` in the order §18 → §19 → §14, then the sections cited
   by the change.
2. Inventory the target:
   - Branch/ref: `git diff --stat <target>` and `git diff <target>`.
   - Worktree: `git status --short`, `git diff HEAD`, and every untracked file.
3. Stop if the target is empty.
4. Run the mechanical gates before spawning reviewers:
   - Copy `ios/` into a temporary directory, run `xcodegen generate` inside the
     temporary `ios/`, and compare its `Regards.xcodeproj` with the working
     tree. Do not generate into the working tree during a review.
   - Run `swiftlint --strict`.
   - Run the privacy and domain-purity checks defined in
     `.github/workflows/guards.yml`.
5. If a gate fails, return `REQUEST_CHANGES` with the gate evidence and do not
   dispatch reviewers.

## Dispatch

Spawn the selected project agents in one parallel batch. Give each agent the
exact target, the relevant §14 PR row, and any R-numbers the change claims to
close. Do not paste the diff; agents read it locally.

- Always run `pr-correctness`, `pr-security-privacy`, and `pr-code-quality`.
- Run `pr-tests` when code or tests changed.
- Run `pr-accessibility` when the diff touches `Features/`, `DesignSystem/`,
  app view code, `RegardsAccessibilityTests`, or `ios/docs/accessibility*`.
- Run `pr-fit-finish` when the diff touches UI, user-facing strings, docs, or
  `.github/`.

Wait for all selected agents. If code quality returns `ESCALATE`, send those
items to correctness for a ruling. If correctness returns coverage holes, send
them to tests for confirmation.

## Consolidate

Return one review in this shape:

```text
## PR Review — <target> — <date>
PRE-FLIGHT: determinism ✅/❌ | swiftlint ✅/❌ | guards ✅/❌
VERDICT: APPROVE | REQUEST_CHANGES

### Blockers
### Should fix
### Nits
### Questions for Sid
### Audit trail
```

Deduplicate identical file-and-line findings, credit all reporting agents, and
keep the highest severity. Any blocker means `REQUEST_CHANGES`. Drop a finding
only when it contradicts `ARCHITECTURE.md`, and record the governing section in
the audit trail. Cap nits at ten.

For every claimed R-closure, verify the §19 acceptance check directly. Mark it
`CONFIRMED` or `NOT MET`; `NOT MET` is a blocker.
