#!/usr/bin/env bash
# mutate.sh -- mutation-test the RTL against the testbenches.
#
# Every mutation below is a single-line edit that changes behaviour the design
# spec pins down. A mutant that SURVIVES means the suite does not actually
# check that behaviour, and is a finding, not a curiosity: the missing
# saturation clamp in feature_engine survived the first run of this list and
# was a real hole -- imbalance could exceed 1.0 and no test noticed.
#
#   ./scripts/mutate.sh            run every mutant
#   ./scripts/mutate.sh feature    run only mutants whose name matches
#
# Exit 0 only if every mutant is killed.
set -uo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-}"
PASS=0; FAIL=0
BACKUP=$(mktemp -d)
trap 'cp -f "$BACKUP"/*.sv rtl/ 2>/dev/null; rm -rf "$BACKUP"' EXIT
cp rtl/*.sv "$BACKUP"/

# Mutants live in scripts/mutants.txt, one per line:
#
#   name @@ file @@ testbench @@ search @@ replace
#
# A data file rather than inline shell calls, because the search strings are
# SystemVerilog and SystemVerilog is full of single quotes -- SCORE_W'(x),
# {1'b0, y} -- which do not survive shell quoting intact. Nothing in this file
# quotes RTL any more.
run_mutant() {
  local name="$1" file="$2" tb="$3" find="$4" repl="$5"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  python3 - "$file" "$find" "$repl" <<'PY' || { printf '%-52s ANCHOR MISSING\n' "$name"; FAIL=$((FAIL+1)); return 0; }
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if sys.argv[2] not in s:
    sys.exit(1)
p.write_text(s.replace(sys.argv[2], sys.argv[3], 1))
PY
  # A kill needs evidence the simulation RAN and failed. A mutant whose
  # replacement text does not compile also makes `make sim` fail, and scoring
  # that as a kill would count a typo in mutants.txt as a test catching a bug.
  local log; log=$(mktemp)
  if make sim TOP="$tb" > "$log" 2>&1; then
    printf '%-52s SURVIVED\n' "$name"; FAIL=$((FAIL+1))
  elif grep -qE "SIMULATION FAILED|no PASS: marker" "$log"; then
    printf '%-52s killed\n' "$name"; PASS=$((PASS+1))
  else
    printf '%-52s DOES NOT BUILD\n' "$name"; FAIL=$((FAIL+1))
  fi
  rm -f "$log"
  cp -f "$BACKUP/$(basename "$file")" "$file"
}

MUTANTS="$(dirname "$0")/mutants.txt"
[ -f "$MUTANTS" ] || { echo "missing $MUTANTS"; exit 1; }

# Baseline: every testbench a selected mutant will be scored against must PASS
# unmutated, before any mutation is applied.
#
# A mutant counts as killed when `make sim` fails, and `make sim` fails for any
# reason -- including a testbench that does not even elaborate. Without this
# check, a broken testbench turns every mutant aimed at it into a "kill". That
# happened: tb_policy_engine stopped elaborating (xsim rejects nonblocking
# writes to associative arrays) and the suite still reported every one of its
# mutants killed, including five written specifically to be hard to kill.
echo "== baseline: unmutated testbenches must pass"
for tb in $(grep -v '^#' "$MUTANTS" | grep ' @@ ' \
            | awk -F' @@ ' -v f="$FILTER" 'f == "" || index($1, f) { print $3 }' \
            | sort -u); do
  if make sim TOP="$tb" >/dev/null 2>&1; then
    printf '   %-30s pass\n' "$tb"
  else
    printf '   %-30s FAILS UNMUTATED\n' "$tb"
    echo "ABORT: $tb does not pass without a mutation, so no kill against it would mean anything."
    exit 2
  fi
done

section=""
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
    '=='*)   section="${line#== }"; echo "== ${section% ==}"; continue ;;
  esac
  name=$(echo "$line" | awk -F' @@ ' '{print $1}')
  file=$(echo "$line" | awk -F' @@ ' '{print $2}')
  tbn=$(echo  "$line" | awk -F' @@ ' '{print $3}')
  find=$(echo "$line" | awk -F' @@ ' '{print $4}')
  repl=$(echo "$line" | awk -F' @@ ' '{print $5}')
  run_mutant "$name" "$file" "$tbn" "$find" "$repl"
done < "$MUTANTS"

echo
if [ $((PASS + FAIL)) -eq 0 ]; then
  echo "ERROR: no mutant matched filter '$FILTER'."
  exit 3
fi
echo "killed $PASS, survived $FAIL"
[ "$FAIL" -eq 0 ]
