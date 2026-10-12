#!/bin/bash
# TITLE: G-B0 (T0) Mac Steam's steamclient.dylib has an x86_64 slice and the exports lsteamclient needs
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# With the Xcode CLT: runs the Steam team's tests/mac/t0_steamclient_dylib.sh unchanged (lipo, nm).
# Without them (lipo/nm are CLT shims that would pop up an install dialog): fallback that reads the
# Mach-O fat header with od/dd, extracts the x86_64 slice into the job dir and looks for the export
# names in it ("approximate": a name in the slice's string table, not a parsed export trie).
# Read-only towards Steam. Args: [--steam-dir DIR]
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-B0 "Mac Steam steamclient.dylib x86_64 slice + exports"
gate_require_mac
dir=$STEAM_MACOS_DIR
while [ $# -gt 0 ]; do case "$1" in --steam-dir) dir=$2; shift 2 ;; *) shift ;; esac; done
dylib="$dir/steamclient.dylib"
[ -f "$dylib" ] || gate_finish_as blocked "no $dylib: Mac Steam must be installed and started once (H-STEAM)"
metric dylib_sha256 "$(sha256_of "$dylib")" str
metric dylib_bytes "$(file_size "$dylib")"
cv=$(steam_client_version); [ -n "$cv" ] && { version_set steam_client "$cv"; metric steam_client_version "$cv" str; }
file -b "$dylib" > "$GLOG/file.txt" 2>&1
metric file_type "$(head -1 "$GLOG/file.txt")" str
codesign -dv "$dylib" > "$GLOG/codesign.txt" 2>&1
metric signing "$(grep -E '^(Authority|TeamIdentifier)=' "$GLOG/codesign.txt" | head -2 | tr '\n' ' ')" str

REQUIRED="CreateInterface Steam_BGetCallback Steam_FreeLastCallback Steam_GetAPICallResult Steam_ReleaseThreadLocalMemory"
OPTIONAL="Steam_IsKnownInterface Steam_NotifyMissingInterface"

if clt_ok && ensure_tests && [ -f "$TESTS/mac/t0_steamclient_dylib.sh" ]; then
  metric method t0-script str
  bash "$TESTS/mac/t0_steamclient_dylib.sh" "$dir" --logs "$GLOG/t0" > "$GLOG/t0.out" 2>&1; rc=$?
  cat "$GLOG/t0.out"
  metric t0_exit "$rc"
  if grep -q '^PASS: x86_64 slice present' "$GLOG/t0.out"; then crit x86_64_slice pass "x86_64 slice present" "$(sed -n 's/^INFO: archs: //p' "$GLOG/t0.out")"
  else crit x86_64_slice fail "x86_64 slice present" "$(sed -n 's/^INFO: archs: //p' "$GLOG/t0.out") - B2 blocked until an arm64 Wine exists"; fi
  for s in $REQUIRED; do
    if grep -q "^PASS: export $s\$" "$GLOG/t0.out"; then crit "export_$s" pass "export $s (x86_64)"; else crit "export_$s" fail "export $s (x86_64)"; fi
  done
  for s in $OPTIONAL; do
    if grep -q "^PASS: export $s (optional)" "$GLOG/t0.out"; then crit "export_$s" info "optional export $s present"; else crit "export_$s" info "optional export $s absent (patch 0001 copes)"; fi
  done
  [ "$rc" = 0 ] || note "t0 reported failures (exit $rc); see logs/G-B0/t0.out"
  gate_end
fi

# ---- fallback without the CLT
metric method "fallback-od-grep (no Xcode CLT)" str
note "Xcode CLT absent: used the no-CLT fallback; rerun with the CLT for an exact nm export check"
be32() { od -An -j "$2" -N4 -tu1 "$1" | awk '{ printf "%.0f", $1*16777216 + $2*65536 + $3*256 + $4 }'; }
le32() { od -An -j "$2" -N4 -tu1 "$1" | awk '{ printf "%.0f", $4*16777216 + $3*65536 + $2*256 + $1 }'; }
magic=$(od -An -N4 -tx1 "$dylib" | tr -d ' \n')
slice="$GTMP/steamclient-x86_64.slice"; archs=""
case "$magic" in
  cafebabe)
    n=$(be32 "$dylib" 4); i=0
    while [ "$i" -lt "$n" ]; do
      o=$(( 8 + i * 20 )); cpu=$(be32 "$dylib" "$o"); off=$(be32 "$dylib" $(( o + 8 ))); size=$(be32 "$dylib" $(( o + 12 )))
      case "$cpu" in 16777223) a=x86_64 ;; 16777228) a=arm64 ;; *) a="cpu$cpu" ;; esac
      archs="$archs $a"
      if [ "$a" = x86_64 ]; then
        if [ $(( off % 4096 )) -eq 0 ]; then dd if="$dylib" of="$slice" bs=4096 skip=$(( off / 4096 )) count=$(( (size + 4095) / 4096 )) 2>/dev/null
        else dd if="$dylib" of="$slice" bs=1 skip="$off" count="$size" 2>/dev/null; fi
      fi
      i=$(( i + 1 ))
    done ;;
  cffaedfe)
    cpu=$(le32 "$dylib" 4)
    case "$cpu" in 16777223) archs=" x86_64"; cp "$dylib" "$slice" ;; 16777228) archs=" arm64" ;; *) archs=" cpu$cpu" ;; esac ;;
  *) archs=" unknown(magic $magic)" ;;
esac
archs=${archs# }
metric archs "$archs" str
case " $archs " in
  *" x86_64 "*) crit x86_64_slice pass "x86_64 slice present (fat header)" "$archs" ;;
  *) crit x86_64_slice fail "x86_64 slice present (fat header)" "$archs - B2 blocked until an arm64 Wine exists"; gate_end ;;
esac
for s in $REQUIRED; do
  if LC_ALL=C grep -a -q "_$s" "$slice" 2>/dev/null; then crit "export_$s" pass "symbol name _$s in the x86_64 slice (approximate)"
  else crit "export_$s" fail "symbol name _$s in the x86_64 slice (approximate)"; fi
done
for s in $OPTIONAL; do
  if LC_ALL=C grep -a -q "_$s" "$slice" 2>/dev/null; then crit "export_$s" info "optional _$s present"; else crit "export_$s" info "optional _$s absent (patch 0001 copes)"; fi
done
rm -f "$slice"
gate_end
