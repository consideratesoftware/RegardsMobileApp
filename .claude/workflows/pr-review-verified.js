export const meta = {
  name: 'pr-review-verified',
  description: 'Run the Regards review board plus Codex on one head, check every BLOCKER and FIX finding with 3 verifiers, and return per-reviewer verdicts, the refuted findings and a repair work order',
  phases: [
    { title: 'Review', detail: 'pr-* reviewers and Codex in parallel on the same head' },
    { title: 'Verify', detail: '3 verifiers per BLOCKER or FIX finding: true in code, in scope, matters' },
    { title: 'Synthesize', detail: 'merge surviving findings into one repair work order' },
  ],
}

// Claude Code org only. /pr-review (the section "Claude Code org only") says
// when to run this. The tests are scripts/tests/pr-review-verified-tests.mjs;
// read its header for how they run this file without Claude Code.
//
// args:
//   title        short name of the PR
//   worktree     path of the lane worktree
//   branch       branch name
//   head         full 40-character lower-case sha of the head to review
//   since        scoped recheck only: the sha of the last full review
//   reviewers    the Stage 1 set, pr-* agent names only
//   codex        true to add the Codex review
//   contextFile  the lane's review-context.md (the TF row and R-numbers)
//
// Rules this script enforces:
//   1. A finding is refuted only when 2 of its 3 verifiers explicitly say
//      real=false. A verifier that fails or returns nothing counts as a vote
//      for "real", so a crashed verifier can never drop a finding.
//   2. Only BLOCKER and FIX findings go to the verifiers. ESCALATE findings
//      and coverage holes are returned untouched for Stage 2.
//   3. A pr-* reviewer's REQUEST_CHANGES becomes APPROVE only when all of
//      these hold: at least 1 of its findings was refuted, none of its
//      BLOCKERs survived, it has no NOT CHECKED entry, and (pr-code-quality
//      only) none of its FIX findings survived.
//   4. A surviving BLOCKER makes any pr-* reviewer REQUEST_CHANGES.
//   5. Codex's verdict is always Codex's own. The verifiers never change it.
//      A refuted Codex finding is still listed in `refuted`. Codex's RETRY and
//      UNAVAILABLE come back as written, so a Codex that could not review is
//      never read as APPROVE.
//   6. A pr-* reviewer whose reviewedSha is not a prefix of head is FAILED,
//      whatever it reported: it reviewed some other head. A missing, malformed
//      or too-short (under 7 characters) sha is FAILED too. Rerun that
//      reviewer alone. Codex's sha is not checked here, because Codex's
//      verdict is never changed; release-manager.md compares the sha in the
//      posted CODEX REVIEW comment with the head.
//
// Result: { head, verdicts, codexReview, workOrder, survivors, refuted }
//   verdicts[]   one per reviewer: verdict (after verification), reportedVerdict
//                (what the reviewer said), reviewedSha, report (the reviewer's
//                whole report, verbatim, or null), notChecked, coverageHoles,
//                escalations, nits. A reviewer that returned nothing has
//                verdict FAILED, and so does a pr-* reviewer whose reviewedSha
//                is not a prefix of head (rule 6).
//   survivors[]  one per surviving BLOCKER or FIX finding: reviewer, severity,
//                location, claim, fix and votes. The work order is built from
//                these; if the synthesizer returns nothing, workOrder.notes
//                says so and the caller repairs from survivors.
//   refuted[]    one per refuted finding, each with its votes. A vote's `real`
//                is true, false, or 'failed' when that verifier returned
//                nothing; `lens` names the verifier.
//   codexReview  Codex's whole review, verbatim, or null.

const FINDINGS = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['APPROVE', 'REQUEST_CHANGES', 'RETRY', 'UNAVAILABLE'] },
    reviewedSha: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['BLOCKER', 'FIX', 'NIT', 'ESCALATE', 'QUESTION'] },
          location: { type: 'string' },
          claim: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'location', 'claim'],
      },
    },
    notChecked: {
      type: 'array',
      items: { type: 'string' },
      description: 'One entry per NOT CHECKED item, with why. An empty array when the reviewer wrote "none".',
    },
    coverageHoles: {
      type: 'array',
      items: { type: 'string' },
      description: 'One entry per COVERAGE HOLES item (pr-correctness). An empty array when there are none.',
    },
    rawSummary: { type: 'string' },
  },
  required: ['verdict', 'reviewedSha', 'findings', 'notChecked', 'coverageHoles'],
}

const VERDICT = {
  type: 'object',
  properties: {
    real: { type: 'boolean' },
    reason: { type: 'string' },
  },
  required: ['real', 'reason'],
}

const WORKORDER = {
  type: 'object',
  properties: {
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          severity: { type: 'string' },
          owner: { type: 'string', enum: ['qa-engineer', 'ios-engineer', 'senior-ios-engineer', 'tech-writer', 'EM-body', 'tech-lead-ruling', 'owner-question'] },
          location: { type: 'string' },
          change: { type: 'string' },
          raisedBy: { type: 'array', items: { type: 'string' } },
        },
        required: ['id', 'severity', 'owner', 'change'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['items'],
}

const a = args || {}

// Fail before any agent runs when the args are wrong. A short sha or a made-up
// reviewer name would otherwise produce a review of the wrong thing.
if (!/^[0-9a-f]{40}$/.test(a.head)) {
  throw new Error(`head must be a full 40-character lower-case hex sha, got: ${a.head}`)
}
if (!Array.isArray(a.reviewers) || a.reviewers.length === 0 || !a.reviewers.every(r => /^pr-[a-z0-9-]+$/.test(r))) {
  throw new Error(`reviewers must be a non-empty array of pr-* agent names, got: ${JSON.stringify(a.reviewers)}`)
}

const scopedRecheck = a.since ? ` This is a scoped recheck: focus on \`git diff ${a.since}..${a.head}\` plus anything it can break.` : ''
const base = `${a.title}. Worktree ${a.worktree}, branch ${a.branch}, head ${a.head}. Target: origin/main...HEAD.${scopedRecheck} Context, scope, rulings and owner decisions: ${a.contextFile}. No commits land during this review. Do not edit files or post to GitHub.`

// The order of LENSES is the order of each finding's votes.
const LENSES = [
  { key: 'truth', ask: 'Is the claim TRUE against the code and docs at the head? Read the cited lines and their callers. If the claim misreads the code, it is not real.' },
  { key: 'scope', ask: `Is it IN SCOPE for this change and NOT already ruled, deferred or accepted? Check ${a.contextFile} and the lane plan/carry-forward files it names. A finding already recorded as a later-slice obligation, an accepted residual, or an owner ruling is not real for this round.` },
  { key: 'impact', ask: 'Does it MATTER: would a user, a maintainer, or a later slice be misled or harmed if it shipped as is? Pure taste or a restatement of an approved trade-off is not real.' },
]

phase('Review')
const reviewers = a.reviewers.map(r => ({ type: r, prompt: `${base}\n\nReview as ${r}. Report every real defect with severity, location (path:line) and the fix. Also return the NOT CHECKED entries and, for pr-correctness, the COVERAGE HOLES. Set reviewedSha to the output of \`git -C ${a.worktree} rev-parse HEAD\`. Put your whole report, verbatim, in rawSummary. Then return the structured result.` }))
if (a.codex) {
  reviewers.push({ type: 'codex-reviewer', prompt: `${base}\n\nRun the Codex review on head ${a.head}, target origin/main...HEAD. Run \`git fetch origin main\` first; retry once on a timeout or capacity error. In the structured result, set verdict from Codex's verdict line: APPROVE, REQUEST_CHANGES, RETRY (also when the head moved) or UNAVAILABLE. Never report APPROVE unless Codex did. Set reviewedSha to the sha Codex reviewed, put each Codex blocker/should-fix/nit in findings, and put Codex's whole review, verbatim, in rawSummary. Its first line is the verdict line \`CODEX REVIEW: <VERDICT> @ <short sha> vs origin/main...HEAD | codex-cli <version>\`.` })
}

const results = await pipeline(
  reviewers,
  r => agent(r.prompt, { label: `review:${r.type}`, phase: 'Review', agentType: r.type, schema: FINDINGS }),
  async (review, r) => {
    if (!review) return { reviewer: r.type, review: null, verified: [] }
    const toCheck = review.findings.filter(f => f.severity === 'BLOCKER' || f.severity === 'FIX')
    // parallel() never rejects and the function below has no code that can
    // throw, so every entry of `verified` is an object.
    const verified = await parallel(toCheck.map(f => async () => {
      const answers = await parallel(LENSES.map(l => () => agent(
        `${base}\n\nA ${r.type} reviewer raised this ${f.severity} at ${f.location}:\n"${f.claim}"\nProposed fix: ${f.fix || '(none)'}\n\nLens: ${l.ask}\nUse your finding-verification mode (verifier.md). Try to REFUTE it under this lens. Set real=false only when you cite file:line evidence that the finding is wrong, out of scope, or harmless. If your verdict would be UNPROVEN, set real=true. Cite file:line evidence either way.`,
        { label: `verify:${r.type}:${l.key}`, phase: 'Verify', agentType: 'verifier', schema: VERDICT })))
      // answers[i] belongs to LENSES[i], and is null when that verifier failed.
      // Keep the null in its place so the lens names stay right.
      const votes = LENSES.map((l, i) => {
        const answer = answers[i]
        if (!answer) return { lens: l.key, real: 'failed', reason: 'the verifier returned nothing' }
        return { lens: l.key, real: answer.real !== false, reason: answer.reason }
      })
      const refutedVotes = votes.filter(v => v.real === false).length
      return { ...f, reviewer: r.type, votes, survives: refutedVotes < 2 }
    }))
    return { reviewer: r.type, review, verified }
  },
)

// The verdict for one reviewer once its findings have been checked.
function verdictAfterVerification(reviewer, review, verified) {
  if (!review) return 'FAILED'
  if (reviewer === 'codex-reviewer') return review.verdict
  if (!/^[0-9a-f]{7,40}$/.test(review.reviewedSha || '') || !a.head.startsWith(review.reviewedSha)) return 'FAILED'
  if (verified.some(v => v.severity === 'BLOCKER' && v.survives)) return 'REQUEST_CHANGES'
  if (review.verdict !== 'REQUEST_CHANGES') return review.verdict
  const refutedSomething = verified.some(v => !v.survives)
  // Only an array we can see is empty counts as "nothing was left unchecked".
  const nothingUnchecked = Array.isArray(review.notChecked) && review.notChecked.length === 0
  const qualityFixSurvived = reviewer === 'pr-code-quality' && verified.some(v => v.severity === 'FIX' && v.survives)
  return refutedSomething && nothingUnchecked && !qualityFixSurvived ? 'APPROVE' : 'REQUEST_CHANGES'
}

phase('Synthesize')
// results[i] is reviewers[i]. A reviewer whose stages threw comes back as
// null; keep it in the list as a failed reviewer so it cannot go missing.
const done = reviewers.map((r, i) => results[i] || { reviewer: r.type, review: null, verified: [] })
const survivors = done.flatMap(d => d.verified.filter(v => v.survives))
const killed = done.flatMap(d => d.verified.filter(v => !v.survives))
log(`${survivors.length} findings survived verification, ${killed.length} refuted`)

let workOrder = { items: [], notes: 'no surviving findings' }
if (survivors.length) {
  // agent() returns null when the synthesizer fails. Without a fallback every
  // surviving finding would vanish from the result, so say so and let the
  // caller repair from `survivors`.
  workOrder = (await agent(
    `${base}\n\nThese review findings survived adversarial verification:\n${JSON.stringify(survivors.map(s => ({ reviewer: s.reviewer, severity: s.severity, location: s.location, claim: s.claim, fix: s.fix })), null, 2)}\n\nMerge duplicates (same root cause) into one item, keep the most severe rating, list every reviewer that raised it. Assign each item an owner: production code → ios-engineer (senior-ios-engineer for SchedulingPass, engine, schema, concurrency); test files → qa-engineer; ARCHITECTURE.md/TESTFLIGHT_PLAN.md/AGENTS.md → tech-writer; PR body only → EM-body; a design choice → tech-lead-ruling; a product or owner-gate choice → owner-question. Write each change as an exact, minimal instruction.`,
    { label: 'synthesize', phase: 'Synthesize', schema: WORKORDER })) || { items: [], notes: 'the synthesizer returned nothing; repair from survivors' }
}

const codex = done.find(d => d.reviewer === 'codex-reviewer')

return {
  head: a.head,
  verdicts: done.map(d => ({
    reviewer: d.reviewer,
    verdict: verdictAfterVerification(d.reviewer, d.review, d.verified),
    reportedVerdict: d.review ? d.review.verdict : 'FAILED',
    reviewedSha: d.review ? d.review.reviewedSha : null,
    codexLine: d.reviewer === 'codex-reviewer' && d.review ? (d.review.rawSummary || '').split('\n')[0] : undefined,
    report: d.review && d.review.rawSummary ? d.review.rawSummary : null,
    notChecked: d.review ? d.review.notChecked : [],
    coverageHoles: d.review ? d.review.coverageHoles : [],
    escalations: d.review ? d.review.findings.filter(f => f.severity === 'ESCALATE').map(f => `${f.location}: ${f.claim}`) : [],
    nits: d.review ? d.review.findings.filter(f => f.severity === 'NIT' || f.severity === 'QUESTION').map(f => `${f.location}: ${f.claim}`) : [],
  })),
  codexReview: (codex && codex.review && codex.review.rawSummary) || null,
  workOrder,
  survivors: survivors.map(s => ({ reviewer: s.reviewer, severity: s.severity, location: s.location, claim: s.claim, fix: s.fix, votes: s.votes })),
  refuted: killed.map(k => ({ reviewer: k.reviewer, severity: k.severity, location: k.location, claim: k.claim, votes: k.votes })),
}
