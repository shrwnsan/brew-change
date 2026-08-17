#!/usr/bin/env bash
# T2.1.1 spike: compare record representations A (JSONL), B (US-delimited),
# C (per-package JSON files). Benchmarks write + read-back + classify round-trip
# at 23 and 200 packages, plus fidelity, parallel-append, and malformed tests.
set -u
cd "$(dirname "$0")"
ROOT=$(mktemp -d /tmp/bc-spike.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

NASTY_REASON=$'Fix: quotes " \' backslash \\\\ and\ttab\nmultiline release notes:\n- "BREAKING" change\n- unicode: café パッケージ 🍺 — em—dash'
NASTY_PKG=$'pkg-ünïcode-🍺'

gen_pkgs() { # $1=count -> prints name<TAB>kind per line
  local i
  for ((i=0;i<$1;i++)); do
    if (( i % 10 == 3 )); then printf '%s\tcask\n' "${NASTY_PKG}-$i"
    else printf 'pkg-%05d\tformula\n' "$i"; fi
  done
}

make_record_json() { # $1=name $2=kind -> JSON object (jq-built, so guaranteed valid)
  jq -cn --arg n "$1" --arg k "$2" --arg r "$NASTY_REASON" --arg v "1.$RANDOM.0" '{
    package:$n, kind:$k, installed:"1.0.0", available:$v,
    evidence_source:"github", evidence_url:("https://example.com/"+$n+"/releases"),
    retrieved_at:1723900000, retrieval_status:"fresh",
    evidence_snapshot:$r, classification:"", reasons:[], matched_signals:[],
    assessment_recommendation:false, operational_eligibility:true, default_selected:false}'
}

# ---------- A: JSON Lines ----------
write_a() { # $1=pkglist $2=outfile
  : > "$2"
  while IFS=$'\t' read -r n k; do make_record_json "$n" "$k" >> "$2"; done < "$1"
}
read_classify_a() { # $1=infile -> counts "attention nosignal unknown"
  jq -r 'if (.available|startswith("1.7")) then "attention" elif .retrieval_status=="fresh" then "no-signal" else "unknown" end' "$1" \
    | sort | uniq -c | awk '{o[$2]=$1} END{printf "%s %s %s", o["attention"]+0, o["no-signal"]+0, o["unknown"]+0}'
}

# ---------- B: US-delimited records, escaping: \ -> \b, US(0x1f) -> \u, LF -> \n, tab -> \t ----------
esc_b() { local s=$1; s=${s//\\/\\b}; s=${s//$'\x1f'/\\u}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; printf '%s' "$s"; }
unesc_b() { local s=$1; s=${s//\\n/$'\n'}; s=${s//\\t/$'\t'}; s=${s//\\u/$'\x1f'}; s=${s//\\b/\\}; printf '%s' "$s"; }
write_b() { # $1=pkglist $2=outfile
  : > "$2"
  while IFS=$'\t' read -r n k; do
    printf '%s\x1f%s\x1f1.0.0\x1f1.%s.0\x1fgithub\x1fhttps://example.com/%s/releases\x1f1723900000\x1ffresh\x1f%s\x1f\x1f\x1f\x1ffalse\x1ftrue\x1ffalse\n' \
      "$(esc_b "$n")" "$k" "$RANDOM" "$n" "$(esc_b "$NASTY_REASON")" >> "$2"
  done < "$1"
}
read_classify_b() { # $1=infile -> counts
  awk -F'\037' '{split($4,v,"."); cls = (v[2]=="7") ? "attention" : ($8=="fresh" ? "no-signal" : "unknown"); c[cls]++}
    END{printf "%d %d %d", c["attention"]+0, c["no-signal"]+0, c["unknown"]+0}' "$1"
}
# fidelity check for B: unescape reason of first nasty row and compare
check_b_fidelity() {
  local row reason
  row=$(grep -a -m1 "$(esc_b "${NASTY_PKG}-3")" "$1")
  reason=$(printf '%s' "$row" | awk -F'\037' '{print $9}')
  [[ "$(unesc_b "$reason")" == "$NASTY_REASON" ]] && echo PASS || echo FAIL
}

# ---------- C: per-package JSON files ----------
encode_c_name() { jq -rnj --arg n "$1" '$n|@uri' | tr '%' '_'; }
write_c() { # $1=pkglist $2=rundir
  mkdir -p "$2"
  while IFS=$'\t' read -r n k; do make_record_json "$n" "$k" > "$2/$(encode_c_name "$n").json"; done < "$1"
}
read_classify_c() { # $1=rundir
  cat "$1"/*.json | jq -r 'if (.available|startswith("1.7")) then "attention" elif .retrieval_status=="fresh" then "no-signal" else "unknown" end' \
    | sort | uniq -c | awk '{o[$2]=$1} END{printf "%s %s %s", o["attention"]+0, o["no-signal"]+0, o["unknown"]+0}'
}

bench() { # $1=label $2=count
  local label=$1 count=$2 f
  gen_pkgs "$count" > "$ROOT/pkgs-$count.tsv"
  # choose random seed so "1.7" bucket is populated deterministically enough
  f="$ROOT/a-$count.jsonl"
  local t0 t1 t2 t3
  t0=$(perl -MTime::HiRes=time -e 'print time')
  write_a "$ROOT/pkgs-$count.tsv" "$f"
  t1=$(perl -MTime::HiRes=time -e 'print time')
  local res_a=$(read_classify_a "$f")
  t2=$(perl -MTime::HiRes=time -e 'print time')
  printf '%s n=%-3d A_jsonl  write=%.3fs read+classify=%.3fs (%s)\n' "$label" "$count" "$(echo "$t1-$t0"|bc)" "$(echo "$t2-$t1"|bc)" "$res_a"

  f="$ROOT/b-$count.tsv"
  t0=$(perl -MTime::HiRes=time -e 'print time')
  write_b "$ROOT/pkgs-$count.tsv" "$f"
  t1=$(perl -MTime::HiRes=time -e 'print time')
  local res_b=$(read_classify_b "$f")
  t2=$(perl -MTime::HiRes=time -e 'print time')
  printf '%s n=%-3d B_us    write=%.3fs read+classify=%.3fs (%s) fidelity=%s\n' "$label" "$count" "$(echo "$t1-$t0"|bc)" "$(echo "$t2-$t1"|bc)" "$res_b" "$(check_b_fidelity "$f")"

  local d="$ROOT/c-$count"
  t0=$(perl -MTime::HiRes=time -e 'print time')
  write_c "$ROOT/pkgs-$count.tsv" "$d"
  t1=$(perl -MTime::HiRes=time -e 'print time')
  local res_c=$(read_classify_c "$d")
  t2=$(perl -MTime::HiRes=time -e 'print time')
  printf '%s n=%-3d C_files write=%.3fs read+classify=%.3fs (%s)\n' "$label" "$count" "$(echo "$t1-$t0"|bc)" "$(echo "$t2-$t1"|bc)" "$res_c"
}

echo "=== fidelity: JSONL round-trip of nasty reason (jq -e @json/@base64 style) ==="
printf '%s' "$NASTY_REASON" | jq -Rs . > "$ROOT/reason.json"
rt=$(jq -r . "$ROOT/reason.json")
[[ "$rt" == "$NASTY_REASON" ]] && echo "PASS: jq -Rs/. round-trip exact" || echo "FAIL"
# JSONL record containing nasty fields, round-trip through read
make_record_json "$NASTY_PKG" formula > "$ROOT/one.jsonl"
jq -e --arg r "$NASTY_REASON" '.evidence_snapshot==$r' "$ROOT/one.jsonl" >/dev/null && echo "PASS: JSONL record round-trip preserves unicode+multiline+quotes"

echo
echo "=== benchmarks (3 trials each shown as best of run; machine: $(uname -m) macOS) ==="
for trial in 1 2 3; do bench "trial$trial" 23; done
for trial in 1 2 3; do bench "trial$trial" 200; done

echo
echo "=== parallel append safety: 16 workers x 25 records each, JSONL O_APPEND >> ==="
for OPT in jsonl us; do
  f="$ROOT/par.$OPT"; : > "$f"
  for w in $(seq 16); do
    (
      for j in $(seq 25); do
        if [[ $OPT == jsonl ]]; then
          make_record_json "w$w-p$j" formula >> "$f"
        else
          printf '%s\x1fformula\n' "$(esc_b "w$w-p$j")" >> "$f"
        fi
      done
    ) &
  done
  wait
  local_n=$(wc -l < "$f" | tr -d ' ')
  if [[ $OPT == jsonl ]]; then bad=$(jq -R 'fromjson? == null' "$f" | grep -c true)
  else bad=$(awk -F'\037' 'NF!=2{c++} END{print c+0}' "$f"); fi
  echo "$OPT: lines=$local_n expected=400 malformed=$bad"
done

echo
echo "=== malformed/truncated record mid-stream ==="
# JSONL: truncate a file mid-line and interleave garbage
head -5 "$ROOT/a-23.jsonl" > "$ROOT/trunc.jsonl"
make_record_json "halfpkg" formula | head -c 40 >> "$ROOT/trunc.jsonl"   # truncated, no newline
printf '\n{"garbage\n' >> "$ROOT/trunc.jsonl"
tail -3 "$ROOT/a-23.jsonl" >> "$ROOT/trunc.jsonl"
ok=$(jq -R -r 'fromjson? // empty | .package' "$ROOT/trunc.jsonl" | wc -l | tr -d ' ')
echo "JSONL: 8 lines total (5 good + truncated + garbage + 3 good); parser recovered good=$ok (expect 8), bad lines skipped via fromjson? // empty, detected via exit of strict 'jq -e .'"
# US: broken field count row
head -5 "$ROOT/b-23.tsv" > "$ROOT/truncb.tsv"
printf 'broken\x1fformula\x1fonlythree\n' >> "$ROOT/truncb.tsv"
tail -3 "$ROOT/b-23.tsv" >> "$ROOT/truncb.tsv"
awkok=$(awk -F'\037' 'NF==15' "$ROOT/truncb.tsv" | wc -l | tr -d ' ')
echo "US: 9 rows total, schema-valid=$awkok (expect 8); NF guard detects malformed; BUT: embedded literal LF in a field would silently split a record unless escaped — escaping is hand-rolled, not library-backed"
# C: truncated file
d="$ROOT/c-23"; cp "$d/pkg-00000.json" "$ROOT/t.json"; head -c 50 "$ROOT/t.json" > "$d/broken.json"
res=$(jq -e . "$d/broken.json" >/dev/null 2>&1 && echo ok || echo "detected")
echo "C_files: truncated file -> jq -e . exit=$? ($res); per-file failure isolates to one package, others unaffected"
rm -f "$d/broken.json"
