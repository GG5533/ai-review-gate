# ai-review-gate

Two models review a coding agent's answer **before it reaches you**, and block
it if it's wrong.

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

## How it works

```
agent finishes  →  Stop hook fires
                   ├── Codex (GPT)          ┐ parallel, ~10s
                   └── Claude, fresh context ┘
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
