#!/usr/bin/env bash
#
# connectivity_tests.sh - end-to-end checks for the Hybrid Cloud Connectivity Lab.
#
# Run from your LAPTOP (needs terraform state + the .pem key). It SSHes into the on-prem
# strongSwan box, and hops through it to reach the private test EC2s.
#
#   KEY_FILE=~/.ssh/hybrid-lab.pem ./tests/connectivity_tests.sh
#
# Exit code 0 = every test passed, 1 = at least one failed.

set -uo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/hybrid-lab.pem}"
SSH_OPTS=(-i "$KEY_FILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)

[[ -f "$KEY_FILE" ]] || { echo "Key file not found: $KEY_FILE (set KEY_FILE=...)" >&2; exit 2; }

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

ONPREM_PUB=$(tf_out onprem_public_ip)  || exit 2
ONPREM_PRIV=$(tf_out onprem_private_ip) || exit 2
PROD_IP=$(tf_out prod_private_ip)      || exit 2
DEV_IP=$(tf_out dev_private_ip)        || exit 2
SHARED_IP=$(tf_out shared_private_ip)  || exit 2

# ---------- helpers ----------
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
PASS=0; FAIL=0

report() { # report <PASS|FAIL> <description> [detail]
  if [[ "$1" == PASS ]]; then PASS=$((PASS+1)); printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$2"
  else FAIL=$((FAIL+1)); printf '%s[FAIL]%s %s %s\n' "$RED" "$RESET" "$2" "${3:-}"; fi
}

# run_on <source> <command...>
#   source = "onprem" or "prod|dev|shared" (reached by hopping through the on-prem box).
# Prints command output and a final line __RC=<exit code>.  If SSH itself fails, no __RC line appears.
run_on() {
  local src=$1; shift
  local cmd="$* ; echo __RC=\$?"
  if [[ $src == onprem ]]; then
    ssh "${SSH_OPTS[@]}" "ubuntu@$ONPREM_PUB" "$cmd" 2>/dev/null
  else
    local target
    case $src in prod) target=$PROD_IP;; dev) target=$DEV_IP;; shared) target=$SHARED_IP;; esac
    ssh "${SSH_OPTS[@]}" \
      -o ProxyCommand="ssh ${SSH_OPTS[*]} -W %h:%p ubuntu@$ONPREM_PUB" \
      "ubuntu@$target" "$cmd" 2>/dev/null
  fi
}

rc_of() { sed -n 's/^__RC=//p' <<<"$1" | tail -n1; }

# expect_reach <from> <to-ip> <label> : ping must SUCCEED
expect_reach() {
  local out rc
  out=$(run_on "$1" "ping -c 3 -W 2 $2"); rc=$(rc_of "$out")
  if   [[ -z $rc ]];  then report FAIL "$3" "(SSH to source failed - is the tunnel up?)"
  elif [[ $rc == 0 ]]; then report PASS "$3"
  else report FAIL "$3" "(ping failed)"; fi
}

# expect_blocked <from> <to-ip> <label> : ping must FAIL (but SSH to the source must work)
expect_blocked() {
  local out rc
  out=$(run_on "$1" "ping -c 3 -W 2 $2"); rc=$(rc_of "$out")
  if   [[ -z $rc ]];  then report FAIL "$3" "(could not SSH to source, so the result is meaningless)"
  elif [[ $rc != 0 ]]; then report PASS "$3"
  else report FAIL "$3" "(ping SUCCEEDED - segmentation is broken!)"; fi
}

echo "=== Hybrid Cloud Connectivity Lab: tests ==="
echo "on-prem=$ONPREM_PRIV  prod=$PROD_IP  dev=$DEV_IP  shared=$SHARED_IP"
echo

# ---------- 0. tunnels ----------
echo "--- Tunnel state ---"
out=$(run_on onprem "sudo swanctl --list-sas | grep -c ESTABLISHED")
n=$(sed -n '1p' <<<"$out")
if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )); then report PASS "At least one IKE SA ESTABLISHED ($n)"
else report FAIL "At least one IKE SA ESTABLISHED" "(got: ${n:-no output})"; fi
[[ "$n" =~ ^[0-9]+$ ]] && (( n >= 2 )) && echo "       (both tunnels up)" || echo "       (only one tunnel up - HA is degraded)"

# ---------- 1. on-prem -> all VPCs ----------
echo; echo "--- On-prem -> AWS (must all PASS) ---"
expect_reach onprem "$PROD_IP"   "On-prem -> Prod   ($PROD_IP)"
expect_reach onprem "$DEV_IP"    "On-prem -> Dev    ($DEV_IP)"
expect_reach onprem "$SHARED_IP" "On-prem -> Shared ($SHARED_IP)"

# ---------- 2. traceroute ----------
echo; echo "--- Traceroute from on-prem (path goes through the tunnel) ---"
for pair in "Prod:$PROD_IP" "Dev:$DEV_IP" "Shared:$SHARED_IP"; do
  name=${pair%%:*}; ip=${pair##*:}
  out=$(run_on onprem "sudo traceroute -n -I -m 6 -w 2 $ip")
  echo "$out" | grep -v '^__RC=' | sed 's/^/       /'
  if grep -qE "^ *[0-9]+ +$ip " <<<"$out"; then report PASS "Traceroute reaches $name ($ip)"
  else report FAIL "Traceroute reaches $name ($ip)"; fi
done

# ---------- 3. spokes <-> shared ----------
echo; echo "--- Prod/Dev <-> Shared (must PASS) ---"
expect_reach prod   "$SHARED_IP" "Prod -> Shared"
expect_reach dev    "$SHARED_IP" "Dev  -> Shared"

# ---------- 4. return to on-prem ----------
echo; echo "--- AWS -> On-prem (must PASS) ---"
expect_reach prod   "$ONPREM_PRIV" "Prod   -> On-prem"
expect_reach dev    "$ONPREM_PRIV" "Dev    -> On-prem"
expect_reach shared "$ONPREM_PRIV" "Shared -> On-prem"

# ---------- 5. segmentation ----------
echo; echo "--- Segmentation (Dev <-> Prod must be BLOCKED) ---"
expect_blocked dev  "$PROD_IP" "Dev  -> Prod is BLOCKED"
expect_blocked prod "$DEV_IP"  "Prod -> Dev  is BLOCKED"

# ---------- summary ----------
echo
echo "=== Result: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
