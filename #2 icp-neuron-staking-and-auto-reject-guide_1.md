# Staking an ICP Neuron via `dfx` and Automating Reject Votes

A field-tested walkthrough for staking a neuron on the Internet Computer's NNS
purely from the command line, then setting up an unattended script that votes
No on every proposal your neuron becomes eligible for.

This assumes you already have `dfx` installed and an identity configured with
ICP in it.

---

## Part 1: Stake the neuron

### Step 1 — Derive the correct subaccount

The ICP ledger doesn't have a "create neuron" button at the CLI level. Instead
you transfer ICP to a specific subaccount of the governance canister, derived
from your principal and a memo (nonce) you choose. Getting this derivation
wrong sends your ICP to an account you can't recover without redoing the exact
same math.

The correct formula, straight from the NNS governance source:

```
subaccount = sha256( 0x0C || "neuron-stake" || principal_bytes || memo_be_u64 )
```

Two common mistakes to avoid:

- **Don't treat principal text as hex.** Principal text is base32-encoded
  with a 4-byte CRC32 checksum prefix, not hex. `bytes.fromhex()` on it will
  either error out or silently produce garbage.
- **The domain separator prefix byte is `0x0C`** (12, the length of
  `"neuron-stake"`), not any other value.

```bash
MEMO=12345678   # pick any uint64 you like — this becomes your neuron's nonce
GOVERNANCE_CANISTER=rrkah-fqaaa-aaaaa-aaaaq-cai

PRINCIPAL=$(dfx identity get-principal)

SUBACCOUNT=$(python3 -c "
import base64, hashlib, zlib

principal_text = '$PRINCIPAL'
memo = $MEMO

s = principal_text.replace('-', '').upper()
s += '=' * ((8 - len(s) % 8) % 8)
raw = base64.b32decode(s)
checksum, payload = raw[:4], raw[4:]

if zlib.crc32(payload).to_bytes(4, 'big') != checksum:
    raise SystemExit('CRC32 mismatch — principal decode is wrong, aborting')

h = hashlib.sha256()
h.update(bytes([0x0c]))
h.update(b'neuron-stake')
h.update(payload)
h.update(memo.to_bytes(8, 'big'))
print(h.hexdigest())
")

echo "Subaccount: $SUBACCOUNT"

NEURON_ACCOUNT=$(dfx ledger account-id --of-canister "$GOVERNANCE_CANISTER" --subaccount "$SUBACCOUNT")
echo "Target ledger account: $NEURON_ACCOUNT"
```

The CRC32 self-check means the script aborts loudly instead of silently
computing a wrong subaccount from a bad principal decode.

### Step 2 — Confirm the target account is empty before transferring

```bash
dfx ledger balance --network ic "$NEURON_ACCOUNT"
```

Should print `0.00000000 ICP`. If it's already non-zero, stop and figure out
why before proceeding.

### Step 3 — Transfer ICP

The minimum stake to create a neuron is **1 ICP**. Below that, the claim step
in Step 4 will simply fail to create a neuron, and your ICP will sit
unclaimed in the subaccount until you send enough to top it up.

```bash
dfx ledger transfer \
  --network ic \
  --amount 1.0 \
  --memo "$MEMO" \
  "$NEURON_ACCOUNT"
```

Confirm it landed:

```bash
dfx ledger balance --network ic "$NEURON_ACCOUNT"
```

### Step 4 — Claim the neuron

```bash
dfx canister call "$GOVERNANCE_CANISTER" claim_or_refresh_neuron_from_account \
  --network ic \
  "(record { controller = opt principal \"$PRINCIPAL\"; memo = $MEMO : nat64 })"
```

A successful response looks like:

```
(
  record {
    result = opt variant {
      NeuronId = record { id = <NEURON_ID> : nat64 }
    };
  },
)
```

Note the underscores dfx prints in large numbers (e.g. `14_754_754_...`) are
just display formatting — strip them when using the ID in later commands, or
leave them in, Candid parses both.

### Step 5 — Verify the neuron exists

```bash
dfx canister call "$GOVERNANCE_CANISTER" list_neurons \
  --network ic \
  "(record { neuron_ids = vec {}; include_neurons_readable_by_caller = true })"
```

Confirm `stake_e8s`, `controller`, and `dissolve_state` look right.

### Step 6 — Set the dissolve delay

Dissolve delay only ever ratchets **up**, never down — double check the value
before running this. A neuron needs at least 6 months (≈15,778,800 seconds)
dissolve delay to be voting-eligible.

```bash
dfx canister call "$GOVERNANCE_CANISTER" manage_neuron \
  --network ic \
  "(record { id = opt record { id = <NEURON_ID> : nat64 }; command = opt variant { Configure = record { operation = opt variant { IncreaseDissolveDelay = record { additional_dissolve_delay_seconds = 31536000 : nat32 } } } } })"
```

`31536000` = 365 days. A successful response is:

```
(record { command = opt variant { Configure = record {} } })
```

Note: the governance canister may round the delay up slightly to align with
internal epoch boundaries — a small favorable difference from the exact
second count you requested, not an error.

---

## Part 2: Important eligibility rule

**A neuron can only vote on proposals created after the neuron itself was
created.** Check `created_timestamp_seconds` on your neuron (from
`list_neurons`) — any open proposal with an earlier
`proposal_timestamp_seconds` will always return
`"Neuron not authorized to vote on proposal."` This is expected NNS behavior,
not a bug in any script.

---

## Part 3: Auto-reject script

This script checks currently open proposals across all topics and casts a No
vote on any your neuron is eligible for.

```bash
#!/bin/bash
# ICP Neuron Auto-Reject Script
# Votes NO on open proposals the neuron is eligible for, across every topic.
set -euo pipefail

# On macOS, dfx installed via dfxvm often isn't on the PATH that launchd/cron
# use. Set it explicitly. Adjust to match `which dfx` on your machine.
export PATH="$HOME/Library/Application Support/org.dfinity.dfx/bin:$PATH"

NEURON_ID="<YOUR_NEURON_ID>"
NETWORK="ic"
GOVERNANCE_CANISTER="rrkah-fqaaa-aaaaa-aaaaq-cai"

echo "[$(date -u +%FT%TZ)] Checking open proposals..."

PROPOSALS_JSON=$(dfx canister call "$GOVERNANCE_CANISTER" list_proposals \
  --network "$NETWORK" --output json \
  "(record { include_reward_status = vec {}; limit = 100 : nat32; exclude_topic = vec {}; include_status = vec { 1 : int32 } })")

PROPOSAL_IDS=$(echo "$PROPOSALS_JSON" | jq -r '.proposal_info[].id[0].id')

if [[ -z "$PROPOSAL_IDS" ]]; then
  echo "No open proposals found."
  exit 0
fi

echo "$PROPOSAL_IDS" | while read -r PROPOSAL_ID; do
  RESULT=$(dfx canister call "$GOVERNANCE_CANISTER" manage_neuron \
    --network "$NETWORK" \
    "(record { id = opt record { id = $NEURON_ID : nat64 }; command = opt variant { RegisterVote = record { vote = 2 : int32; proposal = opt record { id = $PROPOSAL_ID : nat64 } } } })" 2>&1) \
    || true

  if echo "$RESULT" | grep -q "not authorized"; then
    echo "Proposal $PROPOSAL_ID: not eligible (predates neuron), skipping"
  elif echo "$RESULT" | grep -q "Error"; then
    echo "Proposal $PROPOSAL_ID: FAILED -> $RESULT"
  else
    echo "Proposal $PROPOSAL_ID: voted NO successfully"
  fi
done

echo "[$(date -u +%FT%TZ)] Done."
```

### Why `--output json` instead of parsing plain `dfx` text output

The default `idl` text output prints large numbers with underscore digit
separators (e.g. `id = 142_806 : nat64;`). A naive regex like `[0-9]+` will
split on those underscores and extract wrong, fragmented numbers. It's also
easy to accidentally match unrelated nested `id = ...` fields (like
`proposer`) if you grep loosely across the whole output. `--output json`
avoids both problems — no digit grouping, and `jq` can target the exact field
you want (`.proposal_info[].id[0].id`, the proposal's own ID).

### Test manually before scheduling anything

```bash
chmod +x reject-all.sh
./reject-all.sh
```

You should see either `not eligible ... skipping` (expected for a backlog
that predates your neuron) or `voted NO successfully` (for anything newer).
`FAILED` lines are the only ones that need investigating.

---

## Part 4: Scheduling it (macOS — use `launchd`, not `cron`)

Modern macOS versions have quietly deprioritized `cron`; it can silently fail
to fire at all, even with a correctly installed crontab, especially without
Full Disk Access granted. `launchd` is the native scheduler and doesn't have
this problem.

### Create the plist

```bash
nano ~/Library/LaunchAgents/com.example.reject-all.plist
```

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.reject-all</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/full/path/to/reject-all.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>StandardOutPath</key>
    <string>/full/path/to/reject-all.log</string>
    <key>StandardErrorPath</key>
    <string>/full/path/to/reject-all.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

`StartInterval` is in seconds — `1800` = every 30 minutes. `RunAtLoad` fires
it immediately on load too, useful for testing.

### Load it using the modern commands

Prefer `bootstrap`/`bootout` over the legacy `load`/`unload` — the legacy
commands can leave a stale cached job definition behind on modern macOS,
which will keep running an old version of your script even after you've
edited it and reloaded.

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.reject-all.plist
```

Check it's registered:

```bash
launchctl list | grep example
```

### If you ever edit the script after loading

Fully tear down and reload, don't just `load` again:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.example.reject-all.plist
launchctl list | grep example   # confirm it's gone — should print nothing
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.reject-all.plist
```

### Checking on it

```bash
cat /full/path/to/reject-all.log
```

Or live:

```bash
tail -f /full/path/to/reject-all.log
```

### Confirming it actually voted (not just skipped) on something real

```bash
dfx canister call rrkah-fqaaa-aaaaa-aaaaq-cai list_neurons \
  --network ic \
  "(record { neuron_ids = vec { <YOUR_NEURON_ID> : nat64 }; include_neurons_readable_by_caller = true })"
```

Check `recent_ballots` in the output — it only populates once the neuron has
actually cast a real vote. An empty `vec {}` means it hasn't voted on
anything yet, which is expected until a proposal newer than your neuron's
creation timestamp appears.

---

## Quick troubleshooting reference

| Symptom | Likely cause |
|---|---|
| `zsh: parse error near '\n'` | Multi-line `\`-continued command broke on paste; use one-line `&&`-chained versions instead |
| `Neuron not authorized to vote on proposal` | Proposal predates the neuron's creation timestamp — expected, not a bug |
| `dfx: command not found` under cron/launchd | Scheduler's minimal environment doesn't have your interactive shell's `$PATH`; export it explicitly in the script |
| Cron job never fires at all | macOS Full Disk Access / launchd deprecation of cron — switch to `launchd` |
| Stale/old script output reappears after editing and reloading | Legacy `load`/`unload` left a cached job; use `bootout` then `bootstrap` instead |
| Regex-extracted proposal IDs look wrong or split | Underscore digit-grouping in default `dfx` text output; use `--output json` + `jq` instead |
