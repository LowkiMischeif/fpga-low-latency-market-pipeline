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

# name | file | testbench | search | replace
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
  if make sim TOP="$tb" >/dev/null 2>&1; then
    printf '%-52s SURVIVED\n' "$name"; FAIL=$((FAIL+1))
  else
    printf '%-52s killed\n' "$name"; PASS=$((PASS+1))
  fi
  cp -f "$BACKUP/$(basename "$file")" "$file"
}

echo "== top_of_book =="
run_mutant "tob: ask better-direction flipped" rtl/top_of_book.sv tb_top_of_book \
  '(s_event.price < cur.ask_price)' '(s_event.price > cur.ask_price)'
run_mutant "tob: trust gate removed" rtl/top_of_book.sv tb_top_of_book \
  'assign trusted = !(s_err.bad_type' "assign trusted = 1'b1; wire unused_t = !(s_err.bad_type"
run_mutant "tob: qty_add does not saturate" rtl/top_of_book.sv tb_top_of_book \
  "return sum[QTY_W] ? {QTY_W{1'b1}} : sum[QTY_W-1:0];" 'return sum[QTY_W-1:0];'
run_mutant "tob: qty_sub does not floor" rtl/top_of_book.sv tb_top_of_book \
  "return (b >= a) ? '0 : (a - b);" 'return a - b;'
run_mutant "tob: zero-qty ADD guard removed" rtl/top_of_book.sv tb_top_of_book \
  "EVT_ADD: if (s_event.qty != '0) begin" 'EVT_ADD: begin'
run_mutant "tob: book indexed at a fixed symbol" rtl/top_of_book.sv tb_top_of_book \
  'assign cur = book[s_event.symbol];' 'assign cur = book[0];'

echo "== feature_engine =="
run_mutant "feat: spread sign flipped" rtl/feature_engine.sv tb_feature_engine \
  "s_book.ask_price}) - \$signed({1'b0, s_book.bid_price})" "s_book.bid_price}) - \$signed({1'b0, s_book.ask_price})"
run_mutant "feat: mid not halved" rtl/feature_engine.sv tb_feature_engine \
  's_book.ask_price}) >> 1)' 's_book.ask_price}))'
run_mutant "feat: divide-by-zero not folded into empty" rtl/feature_engine.sv tb_feature_engine \
  "assign empty1 = !both_sides || (den == '0);" 'assign empty1 = !both_sides;'
# The gating rule this branch unified. tb_feature_engine kills it; the
# integrated testbench does not, because top_of_book's qty == 0 rule makes the
# divergent state unreachable through the real pipeline.
run_mutant "feat: spread/mid back on split gating" rtl/feature_engine.sv tb_feature_engine \
  '  assign spread1 = empty1' '  assign spread1 = !both_sides'
run_mutant "feat: mid back on split gating" rtl/feature_engine.sv tb_feature_engine \
  '  assign mid1 = empty1' '  assign mid1 = !both_sides'
run_mutant "feat: imbalance numerator reversed" rtl/feature_engine.sv tb_feature_engine \
  "s_book.bid_qty}) - \$signed({1'b0, s_book.ask_qty})" "s_book.ask_qty}) - \$signed({1'b0, s_book.bid_qty})"
run_mutant "feat: wrong reciprocal shift" rtl/feature_engine.sv tb_feature_engine \
  'prod2 >>> (16 - sh1_r)' 'prod2 >>> (15 - sh1_r)'
run_mutant "feat: imbalance high clamp removed" rtl/feature_engine.sv tb_feature_engine \
  "else if (shifted2 >  IMB_PROD_W'(IMB_ONE))      imb2 =  IMB_W'(IMB_ONE);" "else if (1'b0) imb2 = IMB_W'(IMB_ONE);"
run_mutant "feat: imbalance low clamp removed" rtl/feature_engine.sv tb_feature_engine \
  "else if (shifted2 < -IMB_PROD_W'(IMB_ONE))      imb2 = -IMB_W'(IMB_ONE);" "else if (1'b0) imb2 = -IMB_W'(IMB_ONE);"
run_mutant "feat: momentum ignores prev_valid" rtl/feature_engine.sv tb_feature_engine \
  '(empty1_r || !pv)' '(empty1_r)'
run_mutant "feat: momentum history is global" rtl/feature_engine.sv tb_feature_engine \
  'assign pm = prev_mid[ev1.symbol];' 'assign pm = prev_mid[0];'
run_mutant "feat: stale book advances history" rtl/feature_engine.sv tb_feature_engine \
  'v1 && advance && !stale1 && !empty1_r' 'v1 && advance && !empty1_r'

echo "== latency accounting =="
run_mutant "lat: package claims one cycle too many" rtl/market_pkg.sv tb_fixed_latency \
  'localparam int LAT_TOB        = 1;' 'localparam int LAT_TOB        = 2;'
run_mutant "lat: feature_engine collapsed to one cycle" rtl/feature_engine.sv tb_fixed_latency \
  '      m_valid <= v1;' '      m_valid <= s_valid;'

echo
echo "killed $PASS, survived $FAIL"
[ "$FAIL" -eq 0 ]
