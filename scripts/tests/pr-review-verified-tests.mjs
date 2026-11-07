// Tests for .claude/workflows/pr-review-verified.js.
//
//   node scripts/tests/pr-review-verified-tests.mjs
//   WORKFLOW_SCRIPT=<path> node scripts/tests/pr-review-verified-tests.mjs
//
// The second form runs the same cases against another copy of the script. Use
// it to check that a test fails on old code: point it at the old copy and the
// cases that guard the new behavior must fail.
//
// How the script is loaded. The workflow script is not a normal module. Claude
// Code runs it in a sandbox that provides 6 globals: agent(), parallel(),
// pipeline(), phase(), log() and args. It starts with `export const meta`, and
// its last statement is a top-level `return`. To run it here, this file:
//   1. reads the script as text;
//   2. turns `export const meta =` into `const meta =` (an export is not
//      allowed inside a function);
//   3. builds an async function from that text whose parameters are the 6
//      globals (see runWorkflow below);
//   4. calls it with fakes: the fake agent() answers from a table the test
//      supplies and records every call.
// No model runs and nothing touches the network or git.
//
// How a test reads. Each case calls runWorkflow() with a scenario:
//   reviews  what each reviewer agent returns, by agent name
//            (a result object, null for an agent that failed, or an Error to
//            throw)
//   votes    what the 3 verifiers of a finding return, keyed by the finding's
//            location. [true, null, false] means: the truth verifier says
//            real, the scope verifier failed, the impact verifier says
//            not real. The order is truth, scope, impact.
// runWorkflow() returns { result, calls, phases, logs }: the script's return
// value, every agent() call in order, and the phase() and log() messages.
//
// The sandbox has no Date.now() or Math.random() (they would break resume), so
// one case checks the script source for them.

import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const scriptPath = process.env.WORKFLOW_SCRIPT
  || path.join(here, '..', '..', '.claude', 'workflows', 'pr-review-verified.js')
const source = readFileSync(scriptPath, 'utf8')

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const body = '"use strict"\n' + source.replace(/^export const meta =/m, 'const meta =')
const workflow = new AsyncFunction('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', body)

const HEAD = '0123456789abcdef0123456789abcdef01234567'
const LENS_ORDER = ['truth', 'scope', 'impact']

// A reviewer result with nothing wrong in it. Override any field.
function review(verdict, findings = [], more = {}) {
  return { verdict, reviewedSha: HEAD, findings, notChecked: [], coverageHoles: [], rawSummary: '', ...more }
}

function finding(severity, location) {
  return { severity, location, claim: `claim at ${location}`, fix: `fix at ${location}` }
}

function runWorkflow({ reviews = {}, votes = {}, workOrder = { items: [], notes: 'stub' }, args = {} } = {}) {
  const calls = []
  const phases = []
  const logs = []

  // A call the scenario did not plan for is a mistake in the test or in the
  // script. It is recorded and reported when the run ends, because a throw
  // here would be swallowed by parallel() and pipeline().
  const unplanned = []

  function agent(prompt, opts = {}) {
    calls.push({ prompt, opts })
    const label = opts.label || ''

    if (label === 'synthesize') return Promise.resolve(workOrder)

    if (label.startsWith('review:')) {
      if (!(opts.agentType in reviews)) {
        unplanned.push(`a review by ${opts.agentType}, which the test did not script`)
        return Promise.resolve(null)
      }
      const answer = reviews[opts.agentType]
      if (answer instanceof Error) return Promise.reject(answer)
      return Promise.resolve(answer)
    }

    if (label.startsWith('verify:')) {
      const location = Object.keys(votes).find(loc => prompt.includes(loc))
      if (!location) {
        unplanned.push(`a verifier call (${label}) with no votes scripted for it`)
        return Promise.resolve(null)
      }
      const lens = label.split(':').pop()
      const vote = votes[location][LENS_ORDER.indexOf(lens)]
      return Promise.resolve(vote === null ? null : { real: vote, reason: `stub ${lens}` })
    }

    unplanned.push(`an agent call labeled "${label}"`)
    return Promise.resolve(null)
  }

  // Like the real one: a thunk that throws becomes null in its place.
  function parallel(thunks) {
    return Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
  }

  // Like the real one: every stage gets (previous result, item, index), and an
  // item whose stage throws becomes null.
  function pipeline(items, ...stages) {
    return Promise.all(items.map(async (item, i) => {
      try {
        let previous = item
        for (const stage of stages) previous = await stage(previous, item, i)
        return previous
      } catch {
        return null
      }
    }))
  }

  const baseArgs = {
    title: 'Test PR',
    worktree: '/tmp/worktree',
    branch: 'test-branch',
    head: HEAD,
    reviewers: ['pr-correctness'],
    codex: false,
    contextFile: '/tmp/worktree/review-context.md',
  }
  return workflow(agent, parallel, pipeline, p => phases.push(p), m => logs.push(m), { ...baseArgs, ...args })
    .then(result => {
      if (unplanned.length) throw new Error(`the script made calls the test did not plan for: ${unplanned.join('; ')}`)
      return { result, calls, phases, logs }
    })
}

const verifierCalls = calls => calls.filter(c => c.opts.label.startsWith('verify:'))
const verdictOf = (result, reviewer) => result.verdicts.find(v => v.reviewer === reviewer).verdict

// ---- how votes are counted -------------------------------------------------

test('failedVoteCountsReal: votes real, failed, false leave the finding standing', async () => {
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [true, null, false] },
  })
  assert.equal(result.refuted.length, 0)
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
})

test('lensNamesKeptOnFailure: a failed first verifier does not shift the other lens names', async () => {
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [null, false, false] },
  })
  assert.equal(result.refuted.length, 1)
  assert.deepEqual(
    result.refuted[0].votes.map(v => `${v.lens}=${v.real}`),
    ['truth=failed', 'scope=false', 'impact=false'],
  )
})

test('verifiersAreRepoVerifier: every verifier call uses the repo verifier agent', async () => {
  const { calls } = await runWorkflow({
    args: { reviewers: ['pr-correctness', 'pr-tests'] },
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]),
      'pr-tests': review('APPROVE', [finding('FIX', 'Beta.swift:20')]),
    },
    votes: { 'Alpha.swift:10': [true, true, true], 'Beta.swift:20': [true, true, true] },
  })
  const checks = verifierCalls(calls)
  assert.equal(checks.length, 6)
  for (const c of checks) assert.equal(c.opts.agentType, 'verifier')
})

test('escalateNotVerified: an ESCALATE finding gets no verifier and is returned for Stage 2', async () => {
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-code-quality'] },
    reviews: {
      'pr-code-quality': review('APPROVE', [finding('ESCALATE', 'Gamma.swift:5')], {
        coverageHoles: ['no test for the empty list'],
      }),
    },
    // Scripted so that a wrongly verified ESCALATE fails the count below.
    votes: { 'Gamma.swift:5': [true, true, true] },
  })
  assert.equal(verifierCalls(calls).length, 0)
  const verdict = result.verdicts[0]
  assert.deepEqual(verdict.escalations, ['Gamma.swift:5: claim at Gamma.swift:5'])
  assert.deepEqual(verdict.coverageHoles, ['no test for the empty list'])
})

test('only BLOCKER and FIX go to the verifiers: NIT and QUESTION do not', async () => {
  const { result, calls } = await runWorkflow({
    reviews: {
      'pr-correctness': review('APPROVE', [finding('NIT', 'Delta.swift:1'), finding('QUESTION', 'Delta.swift:2')]),
    },
    votes: { 'Delta.swift:1': [true, true, true], 'Delta.swift:2': [true, true, true] },
  })
  assert.equal(verifierCalls(calls).length, 0)
  assert.equal(result.verdicts[0].nits.length, 2)
})

// ---- the per-reviewer verdict ---------------------------------------------

test('refutedBlockerFlipsReviewer: a refuted BLOCKER turns REQUEST_CHANGES into APPROVE', async () => {
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [false, false, true] },
  })
  const verdict = result.verdicts[0]
  assert.equal(verdict.verdict, 'APPROVE')
  assert.equal(verdict.reportedVerdict, 'REQUEST_CHANGES')
  assert.equal(result.refuted.length, 1)
  assert.equal(result.refuted[0].reviewer, 'pr-correctness')
  assert.equal(result.refuted[0].severity, 'BLOCKER')
})

test('a BLOCKER with votes real, real, false survives and keeps REQUEST_CHANGES', async () => {
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [true, true, false] },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
  assert.equal(result.refuted.length, 0)
})

test('a NOT CHECKED entry keeps REQUEST_CHANGES even when every finding is refuted', async () => {
  const { result } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')], {
        notChecked: ['swift test was not run'],
      }),
    },
    votes: { 'Alpha.swift:10': [false, false, false] },
  })
  assert.equal(result.refuted.length, 1)
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
})

test('a result with no notChecked field keeps REQUEST_CHANGES (an unknown is not "none")', async () => {
  const noField = review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')])
  delete noField.notChecked
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': noField },
    votes: { 'Alpha.swift:10': [false, false, false] },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
})

test('pr-code-quality with 3 FIX findings and only 1 refuted keeps REQUEST_CHANGES', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-code-quality'] },
    reviews: {
      'pr-code-quality': review('REQUEST_CHANGES', [
        finding('FIX', 'One.swift:1'), finding('FIX', 'Two.swift:2'), finding('FIX', 'Three.swift:3'),
      ]),
    },
    votes: {
      'One.swift:1': [false, false, false],
      'Two.swift:2': [true, true, true],
      'Three.swift:3': [true, true, true],
    },
  })
  assert.equal(result.refuted.length, 1)
  assert.equal(verdictOf(result, 'pr-code-quality'), 'REQUEST_CHANGES')
})

test('pr-code-quality with 3 FIX findings all refuted becomes APPROVE', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-code-quality'] },
    reviews: {
      'pr-code-quality': review('REQUEST_CHANGES', [
        finding('FIX', 'One.swift:1'), finding('FIX', 'Two.swift:2'), finding('FIX', 'Three.swift:3'),
      ]),
    },
    votes: {
      'One.swift:1': [false, false, true],
      'Two.swift:2': [false, true, false],
      'Three.swift:3': [true, false, false],
    },
  })
  assert.equal(result.refuted.length, 3)
  assert.equal(verdictOf(result, 'pr-code-quality'), 'APPROVE')
})

test('a surviving FIX does not hold back another reviewer once its BLOCKER is refuted', async () => {
  const { result } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10'), finding('FIX', 'Beta.swift:20')]),
    },
    votes: { 'Alpha.swift:10': [false, false, false], 'Beta.swift:20': [true, true, true] },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'APPROVE')
})

test('REQUEST_CHANGES with nothing refuted stays REQUEST_CHANGES', async () => {
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('FIX', 'Beta.swift:20')]) },
    votes: { 'Beta.swift:20': [true, true, true] },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
})

test('an APPROVE reviewer whose BLOCKER survives becomes REQUEST_CHANGES', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-security-privacy'] },
    reviews: { 'pr-security-privacy': review('APPROVE', [finding('BLOCKER', 'Secret.swift:3')]) },
    votes: { 'Secret.swift:3': [true, true, true] },
  })
  const verdict = result.verdicts[0]
  assert.equal(verdict.verdict, 'REQUEST_CHANGES')
  assert.equal(verdict.reportedVerdict, 'APPROVE')
})

// ---- Codex -----------------------------------------------------------------

test('codexVerdictUnchanged: a refuted Codex BLOCKER leaves Codex REQUEST_CHANGES, and is still listed', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('REQUEST_CHANGES', [finding('BLOCKER', 'Codex.swift:7')]),
    },
    votes: { 'Codex.swift:7': [false, false, false] },
  })
  assert.equal(verdictOf(result, 'codex-reviewer'), 'REQUEST_CHANGES')
  assert.equal(result.refuted.length, 1)
  assert.equal(result.refuted[0].reviewer, 'codex-reviewer')
})

test('a surviving Codex BLOCKER leaves a Codex APPROVE alone: the verdict is Codex\'s own', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('APPROVE', [finding('BLOCKER', 'Codex.swift:7')]),
    },
    votes: { 'Codex.swift:7': [true, true, true] },
  })
  assert.equal(verdictOf(result, 'codex-reviewer'), 'APPROVE')
})

test('codexReviewReturned: the whole Codex review comes back verbatim', async () => {
  const text = 'CODEX REVIEW: APPROVE @ 0123456 vs origin/main...HEAD | codex-cli 1.2.3\n\nBlockers: none\nShould fix: none\n'
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: { 'pr-tests': review('APPROVE'), 'codex-reviewer': review('APPROVE', [], { rawSummary: text }) },
  })
  assert.equal(result.codexReview, text)
  assert.equal(result.verdicts.find(v => v.reviewer === 'codex-reviewer').codexLine,
    'CODEX REVIEW: APPROVE @ 0123456 vs origin/main...HEAD | codex-cli 1.2.3')
})

test('codexReview is null when Codex was not asked for, or returned nothing', async () => {
  const without = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE') } })
  assert.equal(without.result.codexReview, null)

  const failed = await runWorkflow({
    args: { codex: true },
    reviews: { 'pr-correctness': review('APPROVE'), 'codex-reviewer': null },
  })
  assert.equal(failed.result.codexReview, null)
  assert.equal(verdictOf(failed.result, 'codex-reviewer'), 'FAILED')
})

// ---- failures and bad input -------------------------------------------------

test('failedReviewer: a reviewer that returns nothing is FAILED, the others still count', async () => {
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-correctness', 'pr-tests'] },
    reviews: { 'pr-correctness': null, 'pr-tests': review('APPROVE') },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'FAILED')
  assert.equal(verdictOf(result, 'pr-tests'), 'APPROVE')
  assert.equal(verifierCalls(calls).length, 0)
})

test('a reviewer whose run throws is still listed, as FAILED', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-correctness', 'pr-tests'] },
    reviews: { 'pr-correctness': new Error('agent crashed'), 'pr-tests': review('APPROVE') },
  })
  assert.deepEqual(result.verdicts.map(v => `${v.reviewer}=${v.verdict}`), ['pr-correctness=FAILED', 'pr-tests=APPROVE'])
})

test('badArgsThrow: a short or malformed head, or a reviewer that is not pr-*, throws before any agent runs', async () => {
  const bad = [
    { head: 'abc1234' },
    { head: HEAD.slice(0, 39) },
    { head: HEAD + '0' },
    { head: 'g'.repeat(40) },
    { head: HEAD.toUpperCase() },
    { head: undefined },
    { reviewers: ['skeptic'] },
    { reviewers: ['pr-tests', 'skeptic'] },
    { reviewers: ['codex-reviewer'] },
    { reviewers: 'pr-tests' },
    { reviewers: [] },
  ]
  for (const args of bad) {
    const calls = []
    await assert.rejects(
      workflow(() => { calls.push(1) }, () => {}, () => {}, () => {}, () => {}, {
        title: 't', worktree: '/w', branch: 'b', head: HEAD, reviewers: ['pr-tests'], codex: false, contextFile: '/c', ...args,
      }),
      /head must be|reviewers must be/,
      JSON.stringify(args),
    )
    assert.equal(calls.length, 0, `an agent ran for ${JSON.stringify(args)}`)
  }
})

// ---- the rest of the contract ---------------------------------------------

test('noFindings: no verifier runs, nothing is refuted, no work order is requested', async () => {
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-correctness', 'pr-tests'], codex: true },
    reviews: {
      'pr-correctness': review('APPROVE'),
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('APPROVE'),
    },
  })
  assert.equal(verifierCalls(calls).length, 0)
  assert.equal(calls.some(c => c.opts.label === 'synthesize'), false)
  assert.deepEqual(result.refuted, [])
  assert.deepEqual(result.workOrder.items, [])
  assert.deepEqual(result.verdicts.map(v => v.verdict), ['APPROVE', 'APPROVE', 'APPROVE'])
})

test('the work order is built from surviving findings only', async () => {
  const { calls } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10'), finding('FIX', 'Beta.swift:20')]),
    },
    votes: { 'Alpha.swift:10': [true, true, true], 'Beta.swift:20': [false, false, false] },
  })
  const synth = calls.filter(c => c.opts.label === 'synthesize')
  assert.equal(synth.length, 1)
  assert.match(synth[0].prompt, /Alpha\.swift:10/)
  assert.doesNotMatch(synth[0].prompt, /Beta\.swift:20/)
})

test('the prompts name a scoped recheck only when since is given', async () => {
  const full = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE') } })
  assert.doesNotMatch(full.calls[0].prompt, /undefined|scoped recheck|git diff/)

  const since = 'f'.repeat(40)
  const scoped = await runWorkflow({ args: { since }, reviews: { 'pr-correctness': review('APPROVE') } })
  assert.match(scoped.calls[0].prompt, new RegExp(`git diff ${since}\\.\\.${HEAD}`))
})

test('the script avoids what the sandbox forbids, and meta is a literal that matches the phases', async () => {
  assert.doesNotMatch(source, /Date\.now|Math\.random|new Date\(\s*\)/)

  // meta must be a pure literal. Evaluating it alone proves it: any variable
  // it used would not exist here.
  const start = source.indexOf('export const meta =')
  const end = source.indexOf('\n}\n', start)
  assert.ok(start >= 0 && end > start, 'could not find the meta block')
  const meta = new Function(`return ${source.slice(start + 'export const meta ='.length, end + 2)}`)()
  assert.equal(meta.name, 'pr-review-verified')
  assert.ok(meta.description.length > 0)

  // A run that reaches every phase uses exactly the titles meta lists, whether
  // through phase() or through the phase option of agent().
  const { phases, calls } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [true, true, true] },
  })
  const used = new Set([...phases, ...calls.map(c => c.opts.phase)])
  assert.deepEqual([...used].sort(), meta.phases.map(p => p.title).sort())
})
