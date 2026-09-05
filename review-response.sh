#!/usr/bin/env bash
# Stop hook: two independent reviewers critique the answer before the turn ends.
#
#   1. Codex (GPT)  — a different model family, different blind spots.
#   2. Claude, fresh context — sees only the excerpt, so it is not anchored by
#      the reasoning that produced the answer. Costs no ChatGPT quota.
#
# Either one flagging a real problem blocks the turn and feeds the critique
# back, so the answer gets fixed instead of sent. They run in parallel, so two
# reviewers cost roughly the wall time of one.
#
# Both reviewers are pure judges: no tools, no filesystem, one turn, text in
# and a verdict out. Nothing here can edit anything.
#
# Bails out silently (exit 0 = don't block) on anything unexpected. A broken
# reviewer must never wedge the session.
set -uo pipefail

# Recursion guard: the Claude reviewer is itself a Claude session and would
# otherwise fire this same hook, forever.
[ -n "${CLAUDE_REVIEW_CHILD:-}" ] && exit 0

CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review.conf"
MIN_CHARS=1200          # below this, not a substantive answer
TIMEOUT=120
ENABLED=1
USE_CODEX=1
USE_CLAUDE=1
USE_LOCAL=0             # Ollama 3B — free, but a weak judge of argument quality
# shellcheck disable=SC1090
[ -f "$CFG" ] && . "$CFG"

[ "$ENABLED" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# macOS has no GNU `timeout`. Without a deadline a hung reviewer would wedge
# the session, so run the child in the background and reap it ourselves.
run_limited() {
  local secs="$1"; shift
  "$@" & local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$secs" ] && { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

IN="$(cat)"

# If this hook already blocked once this turn, let the revision through.
[ "$(jq -r '.stop_hook_active // false' <<<"$IN" 2>/dev/null)" = "true" ] && exit 0

T="$(jq -r '.transcript_path // empty' <<<"$IN" 2>/dev/null)"
{ [ -z "$T" ] || [ ! -f "$T" ]; } && exit 0

ANSWER="$(jq -rs '
  [ .[] | select(.type=="assistant")
        | (.message.content // [])
        | map(select(.type=="text") | .text)
        | join("\n") ]
  | map(select(length > 0)) | last // empty' "$T" 2>/dev/null)"

ASK="$(jq -rs '
  [ .[] | select(.type=="user")
        | (.message.content // [])
        | (if type=="string" then . else (map(select(.type=="text") | .text) | join("\n")) end) ]
  | map(select(length > 0)) | last // empty' "$T" 2>/dev/null)"

# Recent history, so a reviewer does not flag facts the conversation settled.
HIST="$(jq -rs --argjson n 6 '
  [ .[] | select(.type=="user" or .type=="assistant")
        | { r: .type,
            t: ((.message.content // [])
                | (if type=="string" then . else (map(select(.type=="text") | .text) | join("\n")) end)) }
        | select(.t | length > 0) ]
  | .[-($n):] | .[:-1]
  | map("[\(.r)] " + (.t | if length > 900 then .[:900] + " …" else . end))
  | join("\n\n")' "$T" 2>/dev/null)"

[ -z "$ANSWER" ] && exit 0
[ "${#ANSWER}" -lt "$MIN_CHARS" ] && exit 0

# One review per turn per transcript, so a revision cycle cannot ping-pong.
STAMP="/tmp/claude-review-$(basename "$T" .jsonl)"
NOW=$(date +%s)
if [ -f "$STAMP" ] && [ $(( NOW - $(cat "$STAMP" 2>/dev/null || echo 0) )) -lt 120 ]; then
  exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

{
  printf '%s\n' \
"You are reviewing an AI assistant's answer before the user sees it. The user is" \
"stressed, needs practical results, and has already been given weak answers" \
"today. Be harsh but fair. Do not rewrite the answer." \
"" \
"Fail it ONLY for something that would actually waste the user's time or mislead" \
"them:" \
"- a factual claim that is likely wrong, or stated with more confidence than the evidence supports" \
"- a recommendation that ignores a constraint the user already stated" \
"- padding, hedging, or restating the question instead of answering it" \
"- a plan whose first step the user cannot actually do" \
"- silently contradicting something established earlier" \
"- claiming something was delivered that was not actually delivered" \
"" \
"Do NOT fail it for style, length, tone, or for being blunt." \
"" \
"You are seeing an excerpt, not the whole conversation. The assistant may know" \
"things from earlier that you cannot. Do NOT fail an answer merely because a" \
"figure is unsupported in what you can see - fail it only if you can point to" \
"something checkably wrong, or a constraint visibly violated below. When in" \
"doubt, PASS." \
"" \
"RECENT CONVERSATION:"
  printf '%s\n\nUSER ASKED:\n%s\n\nASSISTANT ANSWERED:\n%s\n\n' "$HIST" "$ASK" "$ANSWER"
  printf '%s\n' \
"Reply with exactly one line, nothing else:" \
"PASS" \
"or" \
"REVISE: <the single most important problem, in one sentence>"
} > "$WORK/prompt"

# --- reviewers, in parallel -------------------------------------------------

if [ "$USE_CODEX" = "1" ] && command -v codex >/dev/null 2>&1; then
  ( run_limited "$TIMEOUT" sh -c \
      'codex exec -s read-only --skip-git-repo-check --ephemeral -o "$0" - < "$1" >/dev/null 2>&1' \
      "$WORK/codex" "$WORK/prompt" || true ) &
fi

# No tools, one turn: a pure text-in/verdict-out judge that cannot touch anything.
if [ "$USE_CLAUDE" = "1" ] && command -v claude >/dev/null 2>&1; then
  ( run_limited "$TIMEOUT" sh -c \
      'CLAUDE_REVIEW_CHILD=1 claude -p "$(cat "$1")" --allowedTools "" --max-turns 1 --output-format json 2>/dev/null | jq -r ".result // empty" > "$0"' \
      "$WORK/claude" "$WORK/prompt" || true ) &
fi

if [ "$USE_LOCAL" = "1" ] && [ -n "${LOCAL_REVIEWER:-}" ] && [ -x "${LOCAL_REVIEWER}" ]; then
  ( run_limited 90 sh -c '"$0" "$(cat "$1")" > "$2" 2>/dev/null' \
      "${LOCAL_REVIEWER}" "$WORK/prompt" "$WORK/local" || true ) &
fi

wait
echo "$NOW" > "$STAMP"

FLAGS=""
for r in codex claude local; do
  [ -f "$WORK/$r" ] || continue
  V="$(tr -d '\r' < "$WORK/$r" | grep -m1 -E '^(PASS|REVISE)' || true)"
  case "$V" in
    REVISE:*) FLAGS="$FLAGS
- ${r}: ${V#REVISE:}" ;;
  esac
done

[ -z "$FLAGS" ] && exit 0

jq -n --arg r "Reviewers checked this answer before it was sent and flagged:
$FLAGS

Fix the specific problem(s) above and give the corrected answer. If you
disagree with a critique, say so in one line and explain why, then stand by
your answer — do not pad it or hedge." '{decision:"block", reason:$r}'
