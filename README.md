# ai-review-gate

Two models review a coding agent's answer and **block the turn if it's wrong**,
so the agent has to fix it instead of leaving it.

To be precise about what that means: the first draft still streams to your
terminal. What the gate prevents is a wrong answer being the *final* one — it
forces a correction rather than filtering before display. No hook can intercept
before display; see [limitations](#honest-limitations).

Not a linter. Not an eval suite. A `Stop` hook that runs when the agent thinks
it's finished, hands the answer plus recent context to Codex (GPT) and to a
fresh-context Claude, and refuses to let the turn end if either finds a real
problem. The critique goes back to the agent, which fixes it and tries again.

```bash
git clone https://github.com/GG5533/ai-review-gate
# point your Claude Code Stop hook at review-response.sh
```

## Why bother

An agent that reviews its own output is grading its own homework with the same
blind spots that produced the answer. A second model from a different family
has different ones. That's the entire idea, and it works better than it sounds.

## What it actually caught

Real results from one working session, not a demo. Each of these was blocked
and revised before the human saw it:

| # | What the reviewer caught |
|---|---|
| 1 | A plan whose first step violated a constraint the user had **explicitly stated** one message earlier |
| 2 | A wrong platform fee (a flat rate quoted from a blog; the real one is variable, with a citation) |
| 3 | A self-contradiction: "budget for this" written to someone described as having no budget |
| 4 | An action ranked first that the same answer had already argued should come last |
| 5 | Two claims stated categorically that the cited evidence could not support |
| 6 | A causal explanation invented and presented as research finding |
| 7 | Contradicting itself about whether a system was live |
| 8 | Claiming something was delivered when it had been silently skipped |

Items 5, 6 and 8 are the interesting ones: **overclaiming, invented causation,
and quietly dropping part of a request.** Those are exactly the failure modes a
self-review misses, because the model that made the leap doesn't see it as a
leap.

### Later catches, where the cost of being wrong was public

The table above is from one session. These are from work that was about to be
published under my name in other people's repositories, which is where a wrong
claim is expensive:

| What the reviewer caught | Why it mattered |
|---|---|
| A notification token registered in the handler but never in the validator's allow-list | The feature I had just written was **unusable** — the form rejected it. My own first test cleared it because it replicated the wrong half of the validator. |
| Four overclaims in a security advisory already submitted | Two named sinks did not render HTML at all; the report was withdrawn and corrected. |
| A durability claim resting on unverified call ordering | I asserted two savepoints were equivalent. The reviewer asked what order `drain_before_exit` did things in — it savepoints *before* draining, so they are not. Caught before posting. |
| Attributing an outcome to `AssertUnwindSafe` itself | The wrapper suppresses a bound; the unsafety comes from what you do after. Wrong mechanism, right conclusion. |
| Confusing mutation testing with a bug reproducer | Deleting a guard and watching tests fail proves *coverage*, not a defect. A defect needs a test that fails on unmodified code. |

The pattern across all five: **the answer was confident, internally consistent,
and wrong about something a reader could check.**

## How it works

```
agent finishes  →  Stop hook fires
                   ├── Codex (GPT)          ┐ parallel, ~10s typical
                   └── Claude, fresh context ┘   (120s cap, then fail open)
                   │
                   ├── both PASS  → turn ends, answer delivered
                   └── either REVISE → turn blocked, critique fed back,
                                       agent must fix and re-answer
```

**Design decisions that matter:**

- **Parallel** — two reviewers cost the wall time of one (~10s).
- **Either can block.** They catch different things; requiring consensus would
  discard the reason for having two.
- **Reviewers get no tools.** `--allowedTools ""`, one turn. A judge that reads
  text and returns a verdict has no reason to touch a filesystem, and removing
  the capability removes the risk.
- **High bar, explicitly set.** The prompt tells reviewers they see an excerpt,
  that the agent may know things they don't, and to PASS when in doubt. Without
  this it flags stylistic nits and becomes noise you learn to ignore.
- **Substantive answers only** (>1200 chars by default). Reviewing "ok" wastes
  time and API quota.
- **Two guards against loops:** the hook exits if it already blocked this turn,
  and a recursion guard stops the Claude reviewer — itself a Claude session —
  from firing the same hook forever.
- **Fails open.** Timeout, quota exhaustion, missing binary: it exits 0 and
  lets the answer through. A broken reviewer must never wedge the session.

## Configuration

`review.conf`, beside the script:

```sh
ENABLED=1        # 0 disables the gate entirely
MIN_CHARS=1200   # only review substantive answers
TIMEOUT=120
USE_CODEX=1      # requires the Codex CLI, authenticated
USE_CLAUDE=1     # requires the Claude Code CLI
USE_LOCAL=0      # optional third seat; set LOCAL_REVIEWER to an executable
```

## Honest limitations

- **It fires after the text has streamed.** You see the first answer, then the
  correction. No hook can intercept before display — this reduces bad answers
  reaching you, it doesn't prevent them appearing.
- **It costs a model call per substantive answer**, on whatever quota those
  CLIs use.
- **A third small local model was tested and left off.** A 3B model is a weak
  judge of argument quality — it either rubber-stamps or objects to everything.
  The seat exists (`USE_LOCAL`) but shipping it on by default would be theatre.
- **Reviewers are wrong sometimes.** The instruction on a block is to fix the
  problem *or* say in one line why the critique is wrong and stand by the
  answer. A gate that can't be argued with just teaches you to disable it.
  Observed both ways: a reviewer once proposed splitting a case that did not
  need splitting, because it had the Rust `?` semantics backwards — that
  correction was rejected, and the reviewer was right about the *other* four
  things it raised in the same pass.
- **A reviewer can be rate-limited or hang, and then you have one reviewer,
  not two.** Both happened in a single day: one CLI hit a usage limit twice,
  and a manual call to the same tool hung for nearly four hours. The gate
  itself was unaffected — `run_limited` caps every reviewer at 120s and the
  hook fails open — but "two models reviewed this" quietly became "one model
  reviewed this" with no visible signal. If you rely on this, log which
  reviewers actually answered.
- **Small prompts survive limits that kill large ones.** The gate's review
  calls are short and kept working through a rate limit that was rejecting
  long analysis calls to the same CLI minutes earlier. Useful to know before
  concluding a reviewer is unavailable.

## Prior art

Other people have built review hooks for coding agents; this is not a new idea.
What's here is a working two-model implementation, the specific prompt that
keeps its false-positive rate low enough to leave on, and an honest record of
what it caught.

## Related

**[10 ways your AI feature breaks in production](https://gg5533.github.io/checklist.html)** — production-readiness checklist for AI features. Free, no signup.

MIT.

---

*Built by [Sami Habbal](https://github.com/GG5533) — I make AI systems survive
production. Related: [stripe-fulfilment-kit](https://github.com/GG5533/stripe-fulfilment-kit),
a fenced-lease implementation whose central bug was found by exactly this kind
of cross-model review.*
