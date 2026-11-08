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
// The fake agent() also checks each scripted review against the schema the
// script passed it: a top-level field with an enum must hold one of the listed
// values. The real runtime refuses any other value at the tool-call layer, so
// a reviewer can never return it. Without this check a scripted verdict the
// schema forbids would pass through the fake and hide a missing enum value.
//
// How a test reads. Each case calls runWorkflow() with a scenario:
//   reviews  what each reviewer agent returns, by agent name
//            (a result object, null for an agent that failed, or an Error to
//            throw)
//   votes    what the 3 verifiers of a finding return, keyed by the finding's
//            location. [true, null, false] means: the truth verifier says
//            real, the scope verifier failed, the impact verifier says
//            not real. The order is truth, scope, impact. A vote can also be
//            an object, which the verifier returns as written: { reason: 'x' }
//            is an answer with no `real` field.
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

// The first top-level field of `answer` that holds a value its schema's enum
// does not list, described in words, or null.
// One call site; a name keeps the enum check readable inside agent().
function schemaRefusal(answer, schema) {
  for (const [key, spec] of Object.entries(schema.properties)) {
    if (spec.enum && key in answer && !spec.enum.includes(answer[key])) {
      return `${key} is ${JSON.stringify(answer[key])}, not one of ${spec.enum.join(', ')}`
    }
  }
  return null
}

// Like the real parallel(): a thunk that throws becomes null in its place.
function parallel(thunks) {
  return Promise.all(thunks.map(t => Promise.resolve().then(t).catch(() => null)))
}

// Like the real pipeline(): every stage gets (previous result, item, index), and
// an item whose stage throws becomes null. These two hold no state, so
// runWorkflow() and badArgsThrow share them.
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

function runWorkflow({ reviews = {}, votes = {}, workOrder = { items: [], notes: 'stub' }, args = {} } = {}) {
  const calls = []
  const phases = []
  const logs = []

  // A call the scenario did not plan for, or a scripted answer the schema
  // forbids, is a mistake in the test or in the script. It is recorded and
  // reported when the run ends, because a throw here would be swallowed by
  // parallel() and pipeline().
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
      const refused = answer && schemaRefusal(answer, opts.schema)
      if (refused) {
        unplanned.push(`a review by ${opts.agentType} that the script's schema refuses (${refused})`)
        return Promise.resolve(null)
      }
      return Promise.resolve(answer)
    }

    if (label.startsWith('verify:')) {
      // The prompt says "raised this BLOCKER at Alpha.swift:10:". Read the
      // location from there, whole. Searching the prompt for each scripted
      // location would let Delta.swift:1 match a prompt about Delta.swift:10.
      const named = /raised this [A-Z]+ at (\S+):\n/.exec(prompt)
      const location = named && named[1] in votes ? named[1] : null
      if (!location) {
        unplanned.push(`a verifier call (${label}) with no votes scripted for it`)
        return Promise.resolve(null)
      }
      const lens = label.split(':').pop()
      const vote = votes[location][LENS_ORDER.indexOf(lens)]
      if (vote === null) return Promise.resolve(null)
      if (typeof vote === 'object') return Promise.resolve(vote)
      return Promise.resolve({ real: vote, reason: `stub ${lens}` })
    }

    unplanned.push(`an agent call labeled "${label}"`)
    return Promise.resolve(null)
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
      if (unplanned.length) throw new Error(`the run did not match the scenario: ${unplanned.join('; ')}`)
      return { result, calls, phases, logs }
    })
}

const verifierCalls = calls => calls.filter(c => c.opts.label.startsWith('verify:'))
const verdictOf = (result, reviewer) => result.verdicts.find(v => v.reviewer === reviewer).verdict

// ---- how votes are counted -------------------------------------------------

test('votes are matched by exact location: Delta.swift:1 does not take the votes for Delta.swift:10', async () => {
  // Delta.swift:1 comes first in `votes` on purpose: a search of the prompt
  // for each scripted location would find it inside Delta.swift:10 first.
  const { result } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Delta.swift:1'), finding('BLOCKER', 'Delta.swift:10')]),
    },
    votes: { 'Delta.swift:1': [false, false, false], 'Delta.swift:10': [true, true, true] },
  })
  assert.deepEqual(result.refuted.map(r => r.location), ['Delta.swift:1'])
  assert.deepEqual(result.survivors.map(s => s.location), ['Delta.swift:10'])
})

// Pin: passes on the old script. Rule 1 refutes on 2 explicit real=false votes.
// An answer with no `real` field, or one that is not a boolean, is a vote for
// real. That is the fail-safe: a malformed answer can never drop a finding.
test('only an explicit real=false refutes: an answer with no real field counts as real', async () => {
  const noReal = { reason: 'no real field' }
  // truth has no real field, scope says false, impact says true. One explicit
  // false is not enough. Under `!!answer.real` the truth vote would be false
  // and the finding refuted.
  for (const answer of [noReal, { real: null }, { real: 0 }, { real: '' }, { real: 'false' }]) {
    const { result } = await runWorkflow({
      reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
      votes: { 'Alpha.swift:10': [answer, false, true] },
    })
    assert.equal(result.refuted.length, 0, JSON.stringify(answer))
    assert.equal(result.survivors[0].votes[0].real, true, JSON.stringify(answer))
  }

  // Two explicit false votes still refute, whatever the third answer holds.
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [noReal, false, false] },
  })
  assert.equal(result.refuted.length, 1)
  assert.equal(result.refuted[0].votes[0].real, true)
})

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
  for (const c of checks) {
    assert.equal(c.opts.agentType, 'verifier')
    // verifier.md assumes a claim is false. A vote of real=false must rest on
    // evidence, and doubt must count as real, so the prompt says both and names
    // the mode that applies.
    assert.match(c.prompt, /Use your finding-verification mode \(verifier\.md\)\./)
    assert.match(c.prompt, /Set real=false only when you cite file:line evidence/)
    assert.match(c.prompt, /If your verdict would be UNPROVEN, set real=true/)
    assert.doesNotMatch(c.prompt, /Default to real=false/)
  }
})

// The verify prompt tells the verifier to "use your finding-verification mode
// (verifier.md)". If that section leaves verifier.md, the prompt names a mode
// that does not exist and the verifier falls back to assuming the claim false.
test('verifier.md carries the finding-verification mode the verify prompt names', () => {
  const verifier = readFileSync(path.join(here, '..', '..', '.claude', 'agents', 'verifier.md'), 'utf8')
  assert.match(verifier, /^## Finding-verification mode/m)
  assert.match(verifier, /`real=false` only with cited file:line evidence/)
  assert.match(verifier, /UNPROVEN, set `real=true`/)
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
  assert.deepEqual(result.verdicts[0].nits, ['Delta.swift:1: claim at Delta.swift:1'])
  assert.deepEqual(result.verdicts[0].questions, ['Delta.swift:2: claim at Delta.swift:2'])
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
  // The entry still carries what was left unchecked, and the sha it reviewed.
  assert.deepEqual(result.verdicts[0].notChecked, ['swift test was not run'])
  assert.equal(result.verdicts[0].reviewedSha, HEAD)
})

test('reviewedShaMustMatchHead: a pr-* reviewer whose sha is not a prefix of head is FAILED', async () => {
  const wrong = [
    ['another head', 'f'.repeat(40)],
    ['no sha', undefined],
    ['an empty sha', ''],
    ['a 6-character prefix', HEAD.slice(0, 6)],
    ['an upper-case copy of head', HEAD.toUpperCase()],
    ['head with an extra character', HEAD + '0'],
  ]
  for (const [what, reviewedSha] of wrong) {
    const { result } = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE', [], { reviewedSha }) } })
    assert.equal(verdictOf(result, 'pr-correctness'), 'FAILED', what)
  }

  // A short sha that is a prefix of head is accepted: 7 characters, and all 40.
  for (const reviewedSha of [HEAD.slice(0, 7), HEAD.slice(0, 12), HEAD]) {
    const { result } = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE', [], { reviewedSha }) } })
    assert.equal(verdictOf(result, 'pr-correctness'), 'APPROVE', reviewedSha)
  }
})

test('a wrong reviewedSha is FAILED even with a surviving BLOCKER, and the finding is still returned', async () => {
  const { result } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')], { reviewedSha: 'f'.repeat(40) }),
    },
    votes: { 'Alpha.swift:10': [true, true, true] },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'FAILED')
  assert.equal(result.verdicts[0].reportedVerdict, 'REQUEST_CHANGES')
  assert.equal(result.survivors.length, 1)
})

test('a pr-* reviewer is told where its reviewedSha comes from, and the schema requires one', async () => {
  const { calls } = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE') } })
  assert.match(calls[0].prompt, /reviewedSha to the output of `git -C \/tmp\/worktree rev-parse HEAD`/)
  assert.ok(calls[0].opts.schema.required.includes('reviewedSha'))
})

// Every pr-* contract says never to APPROVE with a required check left
// unchecked, and notChecked holds required checks only. The script enforces it
// (rule 7), and tells the reviewer what belongs in notChecked.
test('approveWithNotCheckedBecomesRequestChanges: a pr-* APPROVE with NOT CHECKED entries is REQUEST_CHANGES', async () => {
  const { result, calls } = await runWorkflow({
    reviews: { 'pr-correctness': review('APPROVE', [], { notChecked: ['swift test was not run'] }) },
  })
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
  assert.equal(result.verdicts[0].reportedVerdict, 'APPROVE')
  assert.deepEqual(result.verdicts[0].notChecked, ['swift test was not run'])

  // The sentence is in the pr-* prompt and in the notChecked schema field.
  const rule = 'notChecked lists only the required checks from your contract that you did not complete; each one makes your verdict REQUEST_CHANGES. Anything else you could not run, that your contract does not require (for example a CI-only script), goes in your report, not here.'
  const call = calls.find(c => c.opts.agentType === 'pr-correctness')
  assert.ok(call.prompt.includes(rule), 'the pr-* prompt lacks the notChecked sentence')
  assert.ok(call.opts.schema.properties.notChecked.description.includes(rule), 'the notChecked schema field lacks the sentence')
})

test('a pr-* APPROVE with no notChecked field is REQUEST_CHANGES: an unknown is not "none"', async () => {
  const noField = review('APPROVE')
  delete noField.notChecked
  const { result } = await runWorkflow({ reviews: { 'pr-correctness': noField } })
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
})

test('a pr-* APPROVE with an empty notChecked stays APPROVE', async () => {
  const { result } = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE', [], { notChecked: [] }) } })
  assert.equal(verdictOf(result, 'pr-correctness'), 'APPROVE')
})

// Pin: passes on the old script. Codex has no NOT CHECKED line and its verdict
// is its own, so the notChecked rule does not apply to it and its prompt and
// schema do not carry the pr-* sentence.
test('a Codex APPROVE with notChecked entries stays APPROVE, and Codex is not told the pr-* rule', async () => {
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('APPROVE', [], { notChecked: ['something'] }),
    },
  })
  assert.equal(verdictOf(result, 'codex-reviewer'), 'APPROVE')
  const codexCall = calls.find(c => c.opts.agentType === 'codex-reviewer')
  assert.doesNotMatch(codexCall.prompt, /notChecked lists only/)
  assert.doesNotMatch(codexCall.opts.schema.properties.notChecked.description, /REQUEST_CHANGES/)
})

// Pin: passes on the old script. A REQUEST_CHANGES flips to APPROVE only when a
// verifier refuted something. With no BLOCKER or FIX finding there is nothing
// to refute, so nothing may flip it.
test('failClosed: a pr-* REQUEST_CHANGES with no BLOCKER or FIX finding stays REQUEST_CHANGES', async () => {
  const cases = [
    ['no findings', []],
    ['only a NIT', [finding('NIT', 'Delta.swift:1')]],
    ['only a QUESTION', [finding('QUESTION', 'Delta.swift:2')]],
    ['only an ESCALATE', [finding('ESCALATE', 'Gamma.swift:5')]],
    ['a NIT, a QUESTION and an ESCALATE', [finding('NIT', 'Delta.swift:1'), finding('QUESTION', 'Delta.swift:2'), finding('ESCALATE', 'Gamma.swift:5')]],
  ]
  for (const [what, findings] of cases) {
    // No votes are scripted: a verifier call here would fail the run.
    const { result, calls } = await runWorkflow({ reviews: { 'pr-correctness': review('REQUEST_CHANGES', findings) } })
    assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES', what)
    assert.equal(verifierCalls(calls).length, 0, what)
    assert.deepEqual(result.refuted, [], what)
  }
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

// Pin: passes on the old script. The pr-code-quality FIX clause (rule 3) only
// stops a REQUEST_CHANGES from flipping to APPROVE. It never turns a reported
// APPROVE into REQUEST_CHANGES, for pr-code-quality or anyone else.
test('a pr-code-quality APPROVE with a surviving FIX stays APPROVE: the FIX clause only blocks the flip', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-code-quality', 'pr-correctness'] },
    reviews: {
      'pr-code-quality': review('APPROVE', [finding('FIX', 'One.swift:1')]),
      'pr-correctness': review('APPROVE', [finding('FIX', 'Two.swift:2')]),
    },
    votes: { 'One.swift:1': [true, true, true], 'Two.swift:2': [true, true, true] },
  })
  assert.equal(verdictOf(result, 'pr-code-quality'), 'APPROVE')
  assert.equal(verdictOf(result, 'pr-correctness'), 'APPROVE')
  assert.equal(result.survivors.length, 2)
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

// Pin: passes on the old script. The reviewedSha rule is for pr-* reviewers
// only; Codex's verdict is never changed here.
test('a Codex reviewedSha that is not head does not change the Codex verdict', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('APPROVE', [], { reviewedSha: 'f'.repeat(40) }),
    },
  })
  assert.equal(verdictOf(result, 'codex-reviewer'), 'APPROVE')
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

test('codexUnavailablePassesThrough: an UNAVAILABLE Codex comes back as UNAVAILABLE, never APPROVE', async () => {
  const text = 'CODEX REVIEW: UNAVAILABLE @ 0123456 vs origin/main...HEAD | codex-cli 1.2.3\nWORKTREE: /tmp/worktree\nVERDICT: UNAVAILABLE\nREASON: not logged in\nREVIEW:\nNot logged in\n'
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('UNAVAILABLE', [], { rawSummary: text }),
    },
  })
  const codex = result.verdicts.find(v => v.reviewer === 'codex-reviewer')
  assert.equal(codex.verdict, 'UNAVAILABLE')
  assert.equal(codex.reportedVerdict, 'UNAVAILABLE')
  assert.equal(codex.codexLine, 'CODEX REVIEW: UNAVAILABLE @ 0123456 vs origin/main...HEAD | codex-cli 1.2.3')
  assert.equal(result.codexReview, text)
  assert.equal(verdictOf(result, 'pr-tests'), 'APPROVE')

  // The agent has to be told it may report UNAVAILABLE, or it would pick the
  // nearest verdict it is allowed.
  const codexCall = calls.find(c => c.opts.agentType === 'codex-reviewer')
  assert.match(codexCall.prompt, /UNAVAILABLE/)

  // The one rerun of Codex belongs to the engineering manager (org.md Stage 3).
  // A retry inside the agent would be a second one.
  assert.doesNotMatch(codexCall.prompt, /retry once/i)
})

// Pin: passes on the old script. Without the fetch Codex would diff against a
// stale origin/main; without the second sentence the agent could report APPROVE
// for a Codex that said otherwise.
test('the Codex prompt carries its safeguards', async () => {
  const { calls } = await runWorkflow({
    args: { codex: true },
    reviews: { 'pr-correctness': review('APPROVE'), 'codex-reviewer': review('APPROVE') },
  })
  const prompt = calls.find(c => c.opts.agentType === 'codex-reviewer').prompt
  assert.match(prompt, /Run `git fetch origin main` first\./)
  assert.match(prompt, /Never report APPROVE unless Codex did\./)
})

// Pin: passes on the old script. Rule 5 says Codex's RETRY comes back as
// written, and only UNAVAILABLE had a test.
test('codexRetryPassesThrough: a RETRY Codex comes back as RETRY, never APPROVE', async () => {
  const text = 'CODEX REVIEW: RETRY @ 0123456 vs origin/main...HEAD | codex-cli 1.2.3\nWORKTREE: /tmp/worktree\nVERDICT: RETRY\nREASON: timeout\nREVIEW:\nlast 20 lines of output\n'
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('RETRY', [], { rawSummary: text }),
    },
  })
  const codex = result.verdicts.find(v => v.reviewer === 'codex-reviewer')
  assert.equal(codex.verdict, 'RETRY')
  assert.equal(codex.reportedVerdict, 'RETRY')
  assert.equal(codex.codexLine, 'CODEX REVIEW: RETRY @ 0123456 vs origin/main...HEAD | codex-cli 1.2.3')
  assert.equal(result.codexReview, text)
  assert.equal(verdictOf(result, 'pr-tests'), 'APPROVE')

  // A RETRY with a stale reviewedSha is still a RETRY: the head may have moved,
  // which is one of the reasons Codex reports RETRY.
  const moved = await runWorkflow({
    args: { reviewers: ['pr-tests'], codex: true },
    reviews: {
      'pr-tests': review('APPROVE'),
      'codex-reviewer': review('RETRY', [], { reviewedSha: 'f'.repeat(40), rawSummary: text }),
    },
  })
  assert.equal(verdictOf(moved.result, 'codex-reviewer'), 'RETRY')

  // The agent has to be told it may report RETRY, or it would pick the
  // nearest verdict it is allowed.
  assert.match(calls.find(c => c.opts.agentType === 'codex-reviewer').prompt, /RETRY \(also when the head moved\)/)
})

test('prVerdictEnum: RETRY and UNAVAILABLE are Codex\'s verdicts, and the schema refuses them from a pr-* reviewer', async () => {
  const { calls } = await runWorkflow({
    args: { codex: true },
    reviews: { 'pr-correctness': review('APPROVE'), 'codex-reviewer': review('APPROVE') },
  })
  const enumOf = type => calls.find(c => c.opts.agentType === type).opts.schema.properties.verdict.enum
  assert.deepEqual(enumOf('pr-correctness'), ['APPROVE', 'REQUEST_CHANGES'])
  assert.deepEqual(enumOf('codex-reviewer'), ['APPROVE', 'REQUEST_CHANGES', 'RETRY', 'UNAVAILABLE'])

  // The fake refuses a verdict the schema does not list, as the runtime does.
  for (const verdict of ['RETRY', 'UNAVAILABLE']) {
    await assert.rejects(
      runWorkflow({ reviews: { 'pr-correctness': review(verdict) } }),
      /schema refuses/,
      verdict,
    )
  }
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

// Pin: passes on the old script. runWorkflow() always sends codex: false, so no
// other test leaves `codex` out. A guard that rejected undefined would have
// passed the suite and broken every caller that omits the key.
test('codex left out runs no Codex, and nothing throws', async () => {
  const base = { title: 't', worktree: '/w', branch: 'b', head: HEAD, reviewers: ['pr-tests'], contextFile: '/c' }
  const scenarios = [
    ['no codex key', base],
    ['codex undefined', { ...base, codex: undefined }],
    ['codex false', { ...base, codex: false }],
  ]
  for (const [what, args] of scenarios) {
    const labels = []
    const agent = async (prompt, opts) => { labels.push(opts.label); return review('APPROVE') }
    const result = await workflow(agent, parallel, pipeline, () => {}, () => {}, args)
    assert.deepEqual(labels, ['review:pr-tests'], what)
    assert.deepEqual(result.verdicts.map(v => v.reviewer), ['pr-tests'], what)
    assert.equal(result.codexReview, null, what)
  }
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
  // A failed reviewer's entry has empty fields, not missing ones.
  const failed = result.verdicts.find(v => v.reviewer === 'pr-correctness')
  assert.equal(failed.reviewedSha, null)
  assert.deepEqual(failed.notChecked, [])
  assert.deepEqual(failed.coverageHoles, [])
})

test('a reviewer whose run throws is still listed, as FAILED', async () => {
  const { result } = await runWorkflow({
    args: { reviewers: ['pr-correctness', 'pr-tests'] },
    reviews: { 'pr-correctness': new Error('agent crashed'), 'pr-tests': review('APPROVE') },
  })
  assert.deepEqual(result.verdicts.map(v => `${v.reviewer}=${v.verdict}`), ['pr-correctness=FAILED', 'pr-tests=APPROVE'])
})

test('badArgsThrow: a bad head, reviewer list, since, codex or text arg throws before any agent runs', async () => {
  const badHead = /head must be/
  const badReviewers = /reviewers must be/
  const text = key => new RegExp(`${key} must be a non-empty string`)
  const badSince = /since must be a 7 to 40 character lower-case hex sha/
  const badCodex = /codex must be true or false/
  const bad = [
    [{ head: 'abc1234' }, badHead],
    [{ head: HEAD.slice(0, 39) }, badHead],
    [{ head: HEAD + '0' }, badHead],
    [{ head: 'g'.repeat(40) }, badHead],
    [{ head: HEAD.toUpperCase() }, badHead],
    [{ head: undefined }, badHead],
    [{ reviewers: ['skeptic'] }, badReviewers],
    [{ reviewers: ['pr-tests', 'skeptic'] }, badReviewers],
    [{ reviewers: ['codex-reviewer'] }, badReviewers],
    // Well-formed pr-* names that no agent has.
    [{ reviewers: ['pr-foo'] }, badReviewers],
    [{ reviewers: ['pr-tests', 'pr-foo'] }, badReviewers],
    [{ reviewers: ['pr-'] }, badReviewers],
    [{ reviewers: 'pr-tests' }, badReviewers],
    [{ reviewers: [] }, badReviewers],
    [{ reviewers: ['pr-tests', 'pr-tests'] }, /reviewers must not repeat/],
    [{ reviewers: ['pr-tests', 'pr-correctness', 'pr-tests'] }, /reviewers must not repeat/],
    // A scoped recheck needs a real sha. Absent is fine; present and wrong is not.
    [{ since: 'main' }, badSince],
    [{ since: 'HEAD~1' }, badSince],
    [{ since: HEAD.slice(0, 6) }, badSince],
    [{ since: HEAD + '0' }, badSince],
    [{ since: HEAD.toUpperCase() }, badSince],
    [{ since: 'g'.repeat(40) }, badSince],
    [{ since: '' }, badSince],
    [{ since: null }, badSince],
    [{ since: 1234567 }, badSince],
    // codex is a boolean. "false" is truthy and would launch Codex.
    [{ codex: 'false' }, badCodex],
    [{ codex: 'true' }, badCodex],
    [{ codex: 'yes' }, badCodex],
    [{ codex: 1 }, badCodex],
    [{ codex: 0 }, badCodex],
    [{ codex: null }, badCodex],
    // The 4 text args go into every prompt.
    [{ title: undefined }, text('title')],
    [{ title: '' }, text('title')],
    [{ title: '   ' }, text('title')],
    [{ worktree: undefined }, text('worktree')],
    [{ worktree: '' }, text('worktree')],
    [{ branch: undefined }, text('branch')],
    [{ branch: '' }, text('branch')],
    [{ contextFile: undefined }, text('contextFile')],
    [{ contextFile: '' }, text('contextFile')],
    [{ contextFile: 42 }, text('contextFile')],
  ]
  for (const [args, message] of bad) {
    // The agent records its call and returns nothing. parallel and pipeline are
    // the working fakes, so a workflow that got past its checks would reach the
    // agent and the count below would not be 0.
    const calls = []
    const agent = () => { calls.push(1); return Promise.resolve(null) }
    const outcome = await workflow(agent, parallel, pipeline, () => {}, () => {}, {
      title: 't', worktree: '/w', branch: 'b', head: HEAD, reviewers: ['pr-tests'], codex: false, contextFile: '/c', ...args,
    }).then(() => null, error => error)
    assert.equal(calls.length, 0, `an agent ran for ${JSON.stringify(args)}`)
    assert.ok(outcome instanceof Error, `no error for ${JSON.stringify(args)}`)
    assert.match(outcome.message, message, JSON.stringify(args))
  }
})

test('a short since is accepted: 7 to 40 characters, and the diff names it as given', async () => {
  for (const since of [HEAD.slice(0, 7), HEAD.slice(0, 20), 'f'.repeat(40)]) {
    const { calls } = await runWorkflow({ args: { since }, reviews: { 'pr-correctness': review('APPROVE') } })
    assert.match(calls[0].prompt, new RegExp(`git diff ${since}\\.\\.${HEAD}`))
  }
})

test('every known pr-* reviewer is accepted', async () => {
  const known = ['pr-correctness', 'pr-security-privacy', 'pr-tests', 'pr-code-quality', 'pr-accessibility', 'pr-fit-finish']
  const { result } = await runWorkflow({
    args: { reviewers: known },
    reviews: Object.fromEntries(known.map(name => [name, review('APPROVE')])),
  })
  assert.deepEqual(result.verdicts.map(v => v.reviewer), known)
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

test('the synthesizer is told who owns infra files: on-call-engineer for scripts, CI and workflow code, tech-writer for prose', async () => {
  // Findings in a CI file and in a workflow script reach the synthesizer too.
  const { calls } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [
        finding('BLOCKER', 'Alpha.swift:10'),
        finding('FIX', '.github/workflows/guards.yml:12'),
        finding('FIX', '.github/PULL_REQUEST_TEMPLATE.md:3'),
        finding('FIX', '.claude/workflows/pr-review-verified.js:200'),
      ]),
    },
    votes: {
      'Alpha.swift:10': [true, true, true],
      '.github/workflows/guards.yml:12': [true, true, true],
      '.github/PULL_REQUEST_TEMPLATE.md:3': [true, true, true],
      '.claude/workflows/pr-review-verified.js:200': [true, true, true],
    },
  })
  const synth = calls.find(c => c.opts.label === 'synthesize')
  assert.match(synth.prompt, /\.github\/workflows\/guards\.yml:12/)
  assert.match(synth.prompt, /\.github\/PULL_REQUEST_TEMPLATE\.md:3/)
  assert.match(synth.prompt, /\.claude\/workflows\/pr-review-verified\.js:200/)
  // .github/ is split by file type: .md is prose, everything else is CI.
  assert.match(synth.prompt, /scripts and their tests under scripts\/, files under \.github\/ other than \.md, and workflow scripts under \.claude\/workflows\/ → on-call-engineer/)
  assert.match(synth.prompt, /\.md files under \.github\/, and prose under \.claude\/, \.codex\/ and \.agents\/ → tech-writer/)
  // The wording that left a .github/ .md file with 2 owners is gone.
  assert.doesNotMatch(synth.prompt, /CI files under \.github\//)
  assert.doesNotMatch(synth.prompt, /\.agents\/ and \.github\/ → tech-writer/)
  assert.doesNotMatch(synth.prompt, /→ chore/)
  assert.match(synth.prompt, /ENGINEERING_ORG\.md/)
  // App tests keep their owner, and the rules do not overlap.
  assert.match(synth.prompt, /test files under ios\/ or android\/ → qa-engineer/)
  assert.doesNotMatch(synth.prompt, /; test files → qa-engineer/)
  // The work order may name the new owner.
  const owners = synth.opts.schema.properties.items.items.properties.owner.enum
  assert.ok(owners.includes('on-call-engineer'))
  assert.ok(!owners.includes('chore'), 'the old owner name is gone')
  assert.ok(owners.includes('tech-writer'))
})

// Pin: this passes on the old script too. It fixes what the synthesizer's
// answer looks like on its way out.
test('workOrderReturned: the synthesizer\'s work order comes back as it was written', async () => {
  const stub = { items: [{ id: '1', severity: 'BLOCKER', owner: 'ios-engineer', change: 'x' }] }
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [true, true, true] },
    workOrder: stub,
  })
  assert.deepEqual(result.workOrder, stub)
})

test('failedSynthesizerKeepsSurvivors: a synthesizer that returns nothing does not erase the findings', async () => {
  const { result } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [true, true, true] },
    workOrder: null,
  })
  assert.notEqual(result.workOrder, null)
  assert.match(result.workOrder.notes, /synthesizer returned nothing/)
  assert.equal(result.survivors.length, 1)
  assert.equal(result.survivors[0].location, 'Alpha.swift:10')
  assert.equal(result.survivors[0].reviewer, 'pr-correctness')
  assert.equal(verdictOf(result, 'pr-correctness'), 'REQUEST_CHANGES')
})

test('reportReturned: a pr-* reviewer\'s whole report comes back on its verdict, and its prompt asks for it', async () => {
  const report = 'INVARIANTS VERIFIED: x'
  const { result, calls } = await runWorkflow({
    args: { reviewers: ['pr-security-privacy', 'pr-tests'] },
    reviews: {
      'pr-security-privacy': review('APPROVE', [], { rawSummary: report }),
      'pr-tests': review('APPROVE'),
    },
  })
  const entry = result.verdicts.find(v => v.reviewer === 'pr-security-privacy')
  assert.equal(entry.report, report)
  // A reviewer that wrote no report has null, not an empty string.
  assert.equal(result.verdicts.find(v => v.reviewer === 'pr-tests').report, null)
  const prompt = calls.find(c => c.opts.agentType === 'pr-security-privacy').prompt
  assert.match(prompt, /rawSummary/)
})

test('survivors lists each surviving BLOCKER or FIX with its votes, and not a refuted one', async () => {
  const { result } = await runWorkflow({
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10'), finding('FIX', 'Beta.swift:20')]),
    },
    votes: { 'Alpha.swift:10': [true, null, false], 'Beta.swift:20': [false, false, true] },
  })
  assert.deepEqual(result.survivors, [{
    reviewer: 'pr-correctness',
    severity: 'BLOCKER',
    location: 'Alpha.swift:10',
    claim: 'claim at Alpha.swift:10',
    fix: 'fix at Alpha.swift:10',
    votes: [
      { lens: 'truth', real: true, reason: 'stub truth' },
      { lens: 'scope', real: 'failed', reason: 'the verifier returned nothing' },
      { lens: 'impact', real: false, reason: 'stub impact' },
    ],
  }])
})

test('the prompts name a scoped recheck only when since is given', async () => {
  const full = await runWorkflow({ reviews: { 'pr-correctness': review('APPROVE') } })
  assert.doesNotMatch(full.calls[0].prompt, /undefined|scoped recheck|git diff/)

  const since = 'f'.repeat(40)
  const scoped = await runWorkflow({ args: { since }, reviews: { 'pr-correctness': review('APPROVE') } })
  assert.match(scoped.calls[0].prompt, new RegExp(`git diff ${since}\\.\\.${HEAD}`))
})

// Pin: passes on the old script. An agent that is not told the head, worktree,
// branch, context file and target would review whatever it finds.
test('every agent prompt names the head, worktree, branch, context file and target', async () => {
  const { calls } = await runWorkflow({
    args: { reviewers: ['pr-correctness'], codex: true },
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]),
      'codex-reviewer': review('APPROVE'),
    },
    votes: { 'Alpha.swift:10': [true, true, true] },
  })
  // One call of every kind: 2 reviews, 3 verifiers and the synthesizer.
  assert.deepEqual(
    calls.map(c => c.opts.label).sort(),
    ['review:codex-reviewer', 'review:pr-correctness', 'synthesize',
      'verify:pr-correctness:impact', 'verify:pr-correctness:scope', 'verify:pr-correctness:truth'],
  )
  for (const c of calls) {
    for (const text of ['Test PR', HEAD, '/tmp/worktree', 'test-branch', '/tmp/worktree/review-context.md', 'origin/main...HEAD']) {
      assert.ok(c.prompt.includes(text), `${c.opts.label} does not name ${text}`)
    }
  }
})

// Pin: passes on the old script. The votes are counted by lens, so each
// verifier has to get the question for its own lens.
test('each verifier gets its own lens question', async () => {
  const { calls } = await runWorkflow({
    reviews: { 'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]) },
    votes: { 'Alpha.swift:10': [true, true, true] },
  })
  const promptOf = lens => calls.find(c => c.opts.label === `verify:pr-correctness:${lens}`).prompt
  assert.match(promptOf('truth'), /TRUE against the code/)
  assert.match(promptOf('scope'), /IN SCOPE/)
  assert.match(promptOf('impact'), /MATTER/)

  // Each prompt has its own question and not the other two.
  assert.doesNotMatch(promptOf('truth'), /IN SCOPE|MATTER/)
  assert.doesNotMatch(promptOf('scope'), /TRUE against the code|MATTER/)
  assert.doesNotMatch(promptOf('impact'), /TRUE against the code|IN SCOPE/)

  // The scope verifier is sent to the context file by name.
  assert.match(promptOf('scope'), /Check \/tmp\/worktree\/review-context\.md/)
})

test('a scoped recheck reaches the pr-* reviewers and their verifiers, never Codex or its verifiers', async () => {
  const since = 'f'.repeat(40)
  const { calls } = await runWorkflow({
    args: { since, codex: true },
    reviews: {
      'pr-correctness': review('REQUEST_CHANGES', [finding('BLOCKER', 'Alpha.swift:10')]),
      'codex-reviewer': review('APPROVE', [finding('BLOCKER', 'Gamma.swift:30')]),
    },
    votes: { 'Alpha.swift:10': [true, true, true], 'Gamma.swift:30': [true, true, true] },
  })
  const focus = new RegExp(`git diff ${since}\\.\\.${HEAD}`)
  const codexCall = calls.find(c => c.opts.agentType === 'codex-reviewer')
  assert.doesNotMatch(codexCall.prompt, /scoped recheck|git diff/)
  assert.match(calls.find(c => c.opts.label === 'review:pr-correctness').prompt, focus)

  // 3 verifiers for the pr-correctness finding and 3 for the Codex finding.
  assert.equal(verifierCalls(calls).length, 6)
  const checksFor = reviewer => calls.filter(c => c.opts.label.startsWith(`verify:${reviewer}:`))
  assert.equal(checksFor('pr-correctness').length, 3)
  assert.equal(checksFor('codex-reviewer').length, 3)
  for (const c of checksFor('pr-correctness')) assert.match(c.prompt, focus)
  for (const c of checksFor('codex-reviewer')) assert.doesNotMatch(c.prompt, /scoped recheck|git diff/)
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
