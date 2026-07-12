#!/usr/bin/env bash
#
# nns_autovote.sh
#
# Polls the NNS governance canister for pending proposals and casts a vote
# from a neuron you control, based on rules you define in decide_vote().
#
# Requirements:
#   - dfx installed and an identity configured that is the controller
#     (or a registered hotkey) of NEURON_ID
#   - jq installed
#
# Usage:
#   NEURON_ID=1234567890123456789 ./nns_autovote.sh
#
# Run on a cron/systemd timer, e.g. every 10 minutes:
#   */10 * * * * /path/to/nns_autovote.sh >> /var/log/nns_autovote.log 2>&1

set -euo pipefail

GOVERNANCE_CANISTER="rrkah-fqaaa-aaaaa-aaaaq-cai"
NEURON_ID="${NEURON_ID:?Set NEURON_ID env var to your neuron's ID}"
NETWORK="ic"
STATE_FILE="${STATE_FILE:-$HOME/.nns_autovote_voted.txt}"

touch "$STATE_FILE"

# ---- 1. Fetch pending proposals as JSON --------------------------------
# --output json requires a reasonably recent dfx. If your version doesn't
# support it, fall back to piping through didc decode instead.
proposals_json="$(dfx canister --network "$NETWORK" call "$GOVERNANCE_CANISTER" \
  get_pending_proposals '()' --output json)"

# ---- 2. Decide how to vote on a given proposal -------------------------
# topic and title are passed in; return "yes", "no", or "skip".
# This is intentionally conservative by default — it skips everything
# until you fill in real rules. Replace the echo "skip" with your logic.
decide_vote() {
  local topic="$1"
  local title="$2"

  case "$topic" in
    # Example: always reject anything touching node/subnet management
    # "NodeAdmin"|"SubnetManagement") echo "no" ;;

    # Example: always approve routine participant management proposals
    # "ParticipantManagement") echo "yes" ;;

    *) echo "skip" ;;
  esac
}

# ---- 3. Iterate over pending proposals ----------------------------------
echo "$proposals_json" | jq -c '.[]' | while read -r proposal; do
  id=$(echo "$proposal" | jq -r '.id[0].id')
  topic=$(echo "$proposal" | jq -r '.topic // empty')
  title=$(echo "$proposal" | jq -r '.proposal[0].title // "untitled"')

  # Skip if we've already voted on this one (idempotency across runs)
  if grep -qx "$id" "$STATE_FILE"; then
    continue
  fi

  decision=$(decide_vote "$topic" "$title")

  if [ "$decision" = "skip" ]; then
    continue
  fi

  # RegisterVote: vote = 1 (Yes/Adopt) or 2 (No/Reject)
  if [ "$decision" = "yes" ]; then
    vote_code=1
  else
    vote_code=2
  fi

  echo "Voting $decision on proposal $id ($title)"

  dfx canister --network "$NETWORK" call "$GOVERNANCE_CANISTER" manage_neuron \
    "(record {
       id = opt record { id = $NEURON_ID : nat64 };
       command = opt variant {
         RegisterVote = record {
           proposal = opt record { id = $id : nat64 };
           vote = $vote_code : int32
         }
       }
     })"

  echo "$id" >> "$STATE_FILE"
done
