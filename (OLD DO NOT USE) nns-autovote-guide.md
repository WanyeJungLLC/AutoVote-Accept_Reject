# Self-Hosted NNS Neuron Auto-Voting: User Guide

This guide walks through staking a neuron on the Internet Computer's Network Nervous System (NNS) via `dfx`, running a script that votes on proposals automatically based on rules you define, and setting your NNS-dapp neurons to follow it. The end result: your voting power moves the way you've programmed it to, without depending on a third-party known neuron.

**Read the whole guide once before running anything.** Neuron actions on mainnet involve real ICP and are not easily reversible.

---

## Prerequisites

- `dfx` installed and up to date (`dfx upgrade`)
- `jq` installed (used by the voting script to parse proposal data)
- An ICP balance in a ledger account controlled by your dfx identity
- A dfx identity you're comfortable using as the neuron's controller

Check your identity and principal:

```bash
dfx identity whoami
dfx identity get-principal
```

---

## Step 1: Stake the neuron

Canister IDs (mainnet):
- Governance: `rrkah-fqaaa-aaaaa-aaaaq-cai`
- Ledger: `ryjl3-tyaaa-aaaaa-aaaba-cai`

**1. Pick a memo.** This is an arbitrary number used to derive a unique staking subaccount. Any nat64 works, as long as you remember it.

```bash
MEMO=123456789
PRINCIPAL=$(dfx identity get-principal)
```

**2. Derive the neuron's staking account and transfer ICP into it.**

Minimum stake is 1 ICP. If you want this neuron to submit proposals later (not just vote), you need 10+ ICP and a 6-month dissolve delay.

```bash
dfx ledger transfer <DERIVED_NEURON_ACCOUNT_ID> \
  --network ic --amount 10 --memo $MEMO
```

**3. Claim the transfer as a neuron.**

```bash
dfx canister --network ic call rrkah-fqaaa-aaaaa-aaaaq-cai claim_or_refresh_neuron_from_account \
  "(record { controller = opt principal \"$PRINCIPAL\"; memo = $MEMO : nat64 })"
```

This returns a `neuron_id`. Save it — you'll need it for every step that follows.

**4. Set a dissolve delay.**

A neuron with 0 dissolve delay has no voting power. Set at least 6 months (15,897,600 seconds):

```bash
NEURON_ID=<your_neuron_id>

dfx canister --network ic call rrkah-fqaaa-aaaaa-aaaaq-cai manage_neuron \
  "(record {
     id = opt record { id = $NEURON_ID : nat64 };
     command = opt variant {
       Configure = record {
         operation = opt variant {
           IncreaseDissolveDelay = record { additional_dissolve_delay_seconds = 15897600 : nat32 }
         }
       }
     }
   })"
```

Longer dissolve delays increase voting power (up to a max of 8 years), so consider going longer than the minimum if you don't need liquidity.

**5. (Optional) Add a hotkey.**

If a different machine than the one holding the controller identity will run the voting script, register that machine's principal as a hotkey instead of moving the controller key around:

```bash
dfx canister --network ic call rrkah-fqaaa-aaaaa-aaaaq-cai manage_neuron \
  "(record {
     id = opt record { id = $NEURON_ID : nat64 };
     command = opt variant {
       Configure = record {
         operation = opt variant {
           AddHotKey = record { new_hot_key = principal \"<HOTKEY_PRINCIPAL>\" }
         }
       }
     }
   })"
```

---

## Step 2: Set up the auto-voting script

The script is `nns_autovote.sh`. It:

1. Fetches all pending proposals from the governance canister
2. Runs each one through a `decide_vote()` function you customize
3. Casts a vote (`RegisterVote`) for anything that isn't skipped
4. Records voted-on proposal IDs locally so it never double-votes

### Install

```bash
chmod +x nns_autovote.sh
```

### Configure your voting rules

Open the script and edit `decide_vote()`. It receives a proposal's `topic` and `title` and must return `"yes"`, `"no"`, or `"skip"`. As shipped, it returns `"skip"` for everything — that's deliberate. **Do not run this unattended until you've written real rules**, or nothing will happen (safe) versus writing rules that adopt/reject indiscriminately (not safe).

Example rules:

```bash
decide_vote() {
  local topic="$1"
  local title="$2"

  case "$topic" in
    "NodeAdmin"|"SubnetManagement") echo "no" ;;
    "ParticipantManagement") echo "yes" ;;
    *) echo "skip" ;;
  esac
}
```

### Verify the data shape before trusting it

Proposal JSON field names can shift between dfx/replica versions. Before scheduling the script, run this once by hand and inspect the output:

```bash
dfx canister --network ic call rrkah-fqaaa-aaaaa-aaaaq-cai get_pending_proposals '()' --output json | jq .
```

Confirm the paths the script relies on — `.id[0].id`, `.topic`, `.proposal[0].title` — actually match what you see. Adjust the script if they don't.

Also confirm the vote codes against the current governance `.did` file (fetch a local copy with `dfx nns import`):

- `1` = Yes / Adopt
- `2` = No / Reject

### Run it manually first

```bash
NEURON_ID=1234567890123456789 ./nns_autovote.sh
```

Check the output. Confirm it's voting the way you expect before automating it.

### Automate it

Add a cron entry to run it on an interval (every 10 minutes shown here):

```
*/10 * * * * NEURON_ID=1234567890123456789 /path/to/nns_autovote.sh >> /var/log/nns_autovote.log 2>&1
```

Check the log periodically, especially in the first few weeks.

---

## Step 3: Follow this neuron from your other neurons

Once your scripted neuron has a track record you trust:

1. Open the NNS dapp and go to **Neurons**.
2. For each neuron you manage there, open **Follow Neurons**.
3. Under each proposal topic you want automated, enter your scripted neuron's ID as the followee.
4. Save.

From this point, those neurons vote identically to whatever your script decides on the topics you've set. Topics your `decide_vote()` skips simply don't get a vote from either neuron — decide up front whether you want a catch-all rule or intend to handle those manually.

---

## Ongoing maintenance

- **Review `decide_vote()` periodically.** Governance topics and proposal patterns change; rules that made sense six months ago may not still apply.
- **Watch the log file** for errors — a failed `dfx canister call` (network issue, identity expired, etc.) will silently skip a vote unless you're checking.
- **Re-verify field paths and vote codes** after any dfx or replica upgrade, since the interface has changed before and can again.
- **Keep the state file** (`~/.nns_autovote_voted.txt` by default) backed up if you care about not re-processing history after a migration.
