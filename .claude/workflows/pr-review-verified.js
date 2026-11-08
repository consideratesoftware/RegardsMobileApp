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
//   title        short name of the PR (non-empty)
//   worktree     path of the lane worktree (non-empty)
//   branch       branch name (non-empty)
//   head         full 40-character lower-case sha of the head to review
//   since        scoped recheck only: the last reviewed head, 7 to 40
//                lower-case hex characters. Leave it out for a full review.
//   reviewers    the Stage 1 set: names from KNOWN_REVIEWERS below, no others
//   codex        true to add the Codex review; false or left out for none.
//                A boolean only: the string "false" is truthy.
//   contextFile  the lane's review-context.md (the TF row and R-numbers) (non-empty)
//
// Rules this script enforces:
//   1. A finding is refuted only when 2 of its 3 verifiers explicitly say
//      real=false. A verifier that fails or returns nothing counts as a vote
//      for "real", so a crashed verifier can never drop a finding.
//   2. Only BLOCKER and FIX findings go to the verifiers. ESCALATE findings
//      and coverage holes are returned untouched for Stage 2.
//   3. A pr-* reviewer's REQUEST_CHANGES becomes APPROVE only when all of
//      these hold: at least 1 of its findings was refuted, none of its
//      BLOCKERs survived, it has no NOT CHECKED entry, its blockerCount (its
//      own BLOCKERS count) equals the number of BLOCKER findings it listed,
//      and (pr-code-quality only) none of its FIX findings survived.
//   4. A pr-* reviewer with a surviving BLOCKER of its own is REQUEST_CHANGES.
//   5. Codex's verdict is always Codex's own. The verifiers never change it.
//      A refuted Codex finding is still listed in `refuted`. Codex's RETRY and
//      UNAVAILABLE come back as written, so a Codex that could not review is
//      never read as APPROVE. One check only: the verdict word on the first
//      line of Codex's review (codexLine) must be the same as its structured
//      verdict, or the entry is FAILED and codex-reviewer is rerun alone. A
//      Codex with no review text has no line to compare and keeps its verdict.
//   6. A pr-* reviewer whose reviewedSha is not a prefix of head is FAILED,
//      whatever it reported: it reviewed some other head. A missing, malformed
//      or too-short (under 7 characters) sha is FAILED too. Rerun that
//      reviewer alone. Codex's sha is not checked here, because Codex's
//      verdict is never changed; release-manager.md compares the sha in the
//      posted CODEX REVIEW comment with the head.
//   7. A pr-* reviewer with any notChecked entry is REQUEST_CHANGES, even when
//      it reported APPROVE. Every pr-* contract says never to APPROVE with a
//      required check left unchecked, and notChecked holds required checks
//      only (the prompt and the schema say so), so this script enforces the
//      contract. A notChecked that is missing is not read as empty. Codex has
//      no NOT CHECKED line and is not affected.
//
// Result: { head, verdicts, codexReview, workOrder, survivors, refuted }
//   verdicts[]   one per reviewer: verdict (after verification), reportedVerdict
//                (what the reviewer said), reviewedSha, codexLine (Codex only),
//                report (the reviewer's whole report, verbatim, or null),
//                notChecked, coverageHoles, escalations, nits, questions. A
//                reviewer that returned nothing has verdict FAILED, and so
//                does a pr-* reviewer whose reviewedSha is not a prefix of
//                head (rule 6).
//   survivors[]  one per surviving BLOCKER or FIX finding: reviewer, severity,
//                location, claim, fix and votes. The work order is built from
//                these; if the synthesizer returns nothing, workOrder.notes
//                says so and the caller repairs from survivors.
//   refuted[]    one per refuted finding, each with its votes. A vote's `real`
//                is true, false, or 'failed' when that verifier returned
//                nothing; `lens` names the verifier.
//   codexReview  Codex's whole review, verbatim, or null.

// Said to every pr-* reviewer in its prompt and in the notChecked schema field.
// Rule 7 turns any entry into REQUEST_CHANGES, so an entry must be a required
// check and nothing else.
const NOT_CHECKED_RULE = 'notChecked lists only the required checks from your contract that you did not complete; each one makes your verdict REQUEST_CHANGES. Anything else you could not run, that your contract does not require (for example a CI-only script), goes in your report, not here.'

// The schema a pr-* reviewer answers with. Its contract has 2 verdicts.
const FINDINGS = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['APPROVE', 'REQUEST_CHANGES'] },
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
      description: `One entry per NOT CHECKED item, with why. An empty array when you wrote "none". ${NOT_CHECKED_RULE}`,
    },
    coverageHoles: {
      type: 'array',
      items: { type: 'string' },
      description: 'One entry per COVERAGE HOLES item (pr-correctness). An empty array when there are none.',
    },
    blockerCount: {
      type: 'integer',
      description: 'The number on your BLOCKERS line, your own count of blockers. 0 when your report has no BLOCKERS line.',
    },
    rawSummary: { type: 'string' },
  },
  required: ['verdict', 'reviewedSha', 'findings', 'notChecked', 'coverageHoles', 'blockerCount'],
}

// Codex's schema is the same with 2 more verdicts: RETRY (also when the head
// moved) and UNAVAILABLE (Codex missing or not logged in). No pr-* contract
// defines them, so the runtime refuses them from a pr-* reviewer.
const CODEX_FINDINGS = {
  ...FINDINGS,
  properties: {
    ...FINDINGS.properties,
    verdict: { type: 'string', enum: ['APPROVE', 'REQUEST_CHANGES', 'RETRY', 'UNAVAILABLE'] },
    notChecked: { type: 'array', items: { type: 'string' }, description: 'Codex has no NOT CHECKED line. Return an empty array.' },
  },
  // Codex's verdict is never changed by a count, so it is not asked for one.
  required: FINDINGS.required.filter(key => key !== 'blockerCount'),
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
          owner: { type: 'string', enum: ['qa-engineer', 'ios-engineer', 'senior-ios-engineer', 'on-call-engineer', 'tech-writer', 'EM-body', 'tech-lead-ruling', 'owner-question'] },
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

// The pr-* reviewers /pr-review's Stage 1 can pick from.
const KNOWN_REVIEWERS = ['pr-correctness', 'pr-security-privacy', 'pr-tests', 'pr-code-quality', 'pr-accessibility', 'pr-fit-finish']

// Fail before any agent runs when the args are wrong. A short sha or a made-up
// reviewer name would otherwise produce a review of the wrong thing.
if (!/^[0-9a-f]{40}$/.test(a.head)) {
  throw new Error(`head must be a full 40-character lower-case hex sha, got: ${a.head}`)
}
// A scoped recheck diffs against `since`. Anything else, an empty string and
// null included, would send the reviewers to diff against nothing useful.
if (a.since !== undefined && (typeof a.since !== 'string' || !/^[0-9a-f]{7,40}$/.test(a.since))) {
  throw new Error(`since must be a 7 to 40 character lower-case hex sha when given, got: ${JSON.stringify(a.since)}`)
}
// codex decides whether Codex launches. The string "false" is truthy, so it
// would launch Codex during an UNAVAILABLE gate, when the caller meant not to.
if (a.codex !== undefined && typeof a.codex !== 'boolean') {
  throw new Error(`codex must be true or false when given, got: ${JSON.stringify(a.codex)}`)
}
// These four go into every prompt. A missing one would put the word "undefined"
// in front of the agent, most harmfully in place of the context file the scope
// verifier reads.
for (const key of ['title', 'worktree', 'branch', 'contextFile']) {
  if (typeof a[key] !== 'string' || a[key].trim() === '') {
    throw new Error(`${key} must be a non-empty string, got: ${JSON.stringify(a[key])}`)
  }
}
if (!Array.isArray(a.reviewers) || a.reviewers.length === 0 || !a.reviewers.every(r => KNOWN_REVIEWERS.includes(r))) {
  throw new Error(`reviewers must be a non-empty array of names from ${KNOWN_REVIEWERS.join(', ')}, got: ${JSON.stringify(a.reviewers)}`)
}
if (new Set(a.reviewers).size !== a.reviewers.length) {
  throw new Error(`reviewers must not repeat a name, got: ${JSON.stringify(a.reviewers)}`)
}

// The focus line goes into the pr-* review prompts and the verify prompts for
// pr-* findings only. Codex always reviews all of origin/main...HEAD, so neither
// its prompt nor the verify prompts for its findings get it.
const scopedRecheck = a.since ? ` This is a scoped recheck: focus on \`git diff ${a.since}..${a.head}\` plus anything it can break.` : ''
const base = `${a.title}. Worktree ${a.worktree}, branch ${a.branch}, head ${a.head}. Target: origin/main...HEAD. Context, scope, rulings and owner decisions: ${a.contextFile}. No commits land during this review. Do not edit files or post to GitHub.`

// The order of LENSES is the order of each finding's votes.
const LENSES = [
  { key: 'truth', ask: 'Is the claim TRUE against the code and docs at the head? Read the cited lines and their callers. If the claim misreads the code, it is not real.' },
  { key: 'scope', ask: `Is it IN SCOPE for this change and NOT already ruled, deferred or accepted? Check ${a.contextFile} and the lane plan/carry-forward files it names. A finding already recorded as a later-slice obligation, an accepted residual, or an owner ruling is not real for this round.` },
  { key: 'impact', ask: 'Does it MATTER: would a user, a maintainer, or a later slice be misled or harmed if it shipped as is? Pure taste or a restatement of an approved trade-off is not real.' },
]

phase('Review')
const reviewers = a.reviewers.map(r => ({ type: r, schema: FINDINGS, prompt: `${base}${scopedRecheck}\n\nReview as ${r}. Report every real defect with severity, location (path:line) and the fix. Also return the NOT CHECKED entries and, for pr-correctness, the COVERAGE HOLES. ${NOT_CHECKED_RULE} Set reviewedSha to the output of \`git -C ${a.worktree} rev-parse HEAD\`. Set blockerCount to the number on your BLOCKERS line, or 0 if your report has none. Put your whole report, verbatim, in rawSummary. Then return the structured result.` }))
if (a.codex) {
  reviewers.push({ type: 'codex-reviewer', schema: CODEX_FINDINGS, prompt: `${base}\n\nRun the Codex review on head ${a.head}, target origin/main...HEAD. Run \`git fetch origin main\` first. In the structured result, set verdict from Codex's verdict line: APPROVE, REQUEST_CHANGES, RETRY (also when the head moved) or UNAVAILABLE. Never report APPROVE unless Codex did. Set reviewedSha to the sha Codex reviewed, put each Codex blocker/should-fix/nit in findings, and put Codex's whole review, verbatim, in rawSummary. Its first line is the verdict line \`CODEX REVIEW: <VERDICT> @ <short sha> vs origin/main...HEAD | codex-cli <version>\`.` })
}

const results = await pipeline(
  reviewers,
  r => agent(r.prompt, { label: `review:${r.type}`, phase: 'Review', agentType: r.type, schema: r.schema }),
  async (review, r) => {
    if (!review) return { reviewer: r.type, review: null, verified: [] }
    const toCheck = review.findings.filter(f => f.severity === 'BLOCKER' || f.severity === 'FIX')
    // parallel() never rejects and the function below has no code that can
    // throw, so every entry of `verified` is an object.
    const verified = await parallel(toCheck.map(f => async () => {
      const answers = await parallel(LENSES.map(l => () => agent(
        `${base}${r.type === 'codex-reviewer' ? '' : scopedRecheck}\n\nA ${r.type} reviewer raised this ${f.severity} at ${f.location}:\n"${f.claim}"\nProposed fix: ${f.fix || '(none)'}\n\nLens: ${l.ask}\nUse your finding-verification mode (verifier.md). Try to REFUTE it under this lens. Set real=false only when you cite file:line evidence that the finding is wrong, out of scope, or harmless. If your verdict would be UNPROVEN, set real=true. Cite file:line evidence either way.`,
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

// One call site; a function keeps these early returns out of the verdicts map below.
function verdictAfterVerification(reviewer, review, verified) {
  if (!review) return 'FAILED'
  if (reviewer === 'codex-reviewer') {
    // Codex's first line is "CODEX REVIEW: <VERDICT> @ ...", the verdict that
    // gets posted. The structured verdict has to be the same word. If they
    // differ, or a first line is not a verdict line, one of them is wrong and
    // the entry is FAILED. No review text means no line to compare.
    const firstLine = (review.rawSummary || '').split('\n')[0]
    if (firstLine === '') return review.verdict
    const named = /^CODEX REVIEW: (APPROVE|REQUEST_CHANGES|RETRY|UNAVAILABLE) @ /.exec(firstLine)
    return named && named[1] === review.verdict ? review.verdict : 'FAILED'
  }
  if (!/^[0-9a-f]{7,40}$/.test(review.reviewedSha || '') || !a.head.startsWith(review.reviewedSha)) return 'FAILED'
  if (verified.some(v => v.severity === 'BLOCKER' && v.survives)) return 'REQUEST_CHANGES'
  // Any notChecked entry is a required check left undone: REQUEST_CHANGES,
  // whatever the reviewer reported (rule 7). Only an array we can see is empty
  // counts as "nothing was left unchecked".
  const nothingUnchecked = Array.isArray(review.notChecked) && review.notChecked.length === 0
  if (!nothingUnchecked) return 'REQUEST_CHANGES'
  if (review.verdict !== 'REQUEST_CHANGES') return review.verdict
  const refutedSomething = verified.some(v => !v.survives)
  // The reviewer's own blocker count has to match the BLOCKER findings it
  // listed. A blocker it counted and did not list was never checked by a
  // verifier, so a refuted finding beside it cannot clear the REQUEST_CHANGES.
  const blockersListed = review.findings.filter(f => f.severity === 'BLOCKER').length
  const blockersAccountedFor = Number.isInteger(review.blockerCount) && review.blockerCount === blockersListed
  const qualityFixSurvived = reviewer === 'pr-code-quality' && verified.some(v => v.severity === 'FIX' && v.survives)
  return refutedSomething && blockersAccountedFor && !qualityFixSurvived ? 'APPROVE' : 'REQUEST_CHANGES'
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
    `${base}\n\nThese review findings survived adversarial verification:\n${JSON.stringify(survivors.map(s => ({ reviewer: s.reviewer, severity: s.severity, location: s.location, claim: s.claim, fix: s.fix })), null, 2)}\n\nMerge duplicates (same root cause) into one item, keep the most severe rating, list every reviewer that raised it. Assign each item an owner: production code → ios-engineer (senior-ios-engineer for SchedulingPass, engine, schema, concurrency); test files under ios/ or android/ → qa-engineer; scripts and their tests under scripts/, files under .github/ other than .md, and workflow scripts under .claude/workflows/ → on-call-engineer; every .md file outside ios/Regards* and android/*/src (ios/docs, android/docs, .github/, and the root docs README.md, ANDROID_PORT.md, CLAUDE.md, AGENTS.md, ARCHITECTURE.md, TESTFLIGHT_PLAN.md and ENGINEERING_ORG.md), and prose under .claude/, .codex/ and .agents/ → tech-writer; PR body only → EM-body; a design choice → tech-lead-ruling; a product or owner-gate choice → owner-question. Write each change as an exact, minimal instruction.`,
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
    nits: d.review ? d.review.findings.filter(f => f.severity === 'NIT').map(f => `${f.location}: ${f.claim}`) : [],
    questions: d.review ? d.review.findings.filter(f => f.severity === 'QUESTION').map(f => `${f.location}: ${f.claim}`) : [],
  })),
  codexReview: (codex && codex.review && codex.review.rawSummary) || null,
  workOrder,
  survivors: survivors.map(s => ({ reviewer: s.reviewer, severity: s.severity, location: s.location, claim: s.claim, fix: s.fix, votes: s.votes })),
  refuted: killed.map(k => ({ reviewer: k.reviewer, severity: k.severity, location: k.location, claim: k.claim, votes: k.votes })),
}
