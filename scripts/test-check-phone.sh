#!/usr/bin/env bash
# Author: Jonas Kufner
# Web:    https://jonaskufner.com
#
# test-check-phone.sh - automated tests for scripts/check-phone.sh (US-1, criterion 5).
#
# Runs the check once against the real site (must pass), then against fresh copies in a
# new empty temp directory, each with one defect injected (must fail for the right reason).
# The site and its copies are only read and edited as data; nothing inside them is run.
#
# Usage:      scripts/test-check-phone.sh <site-path>
# Exit codes: 0 = all tests passed, 1 = at least one test failed, 2 = usage/setup error.

set -u
export LC_ALL=C

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <site-path>" >&2
  exit 2
fi
site=$(CDPATH='' cd -- "$1" && pwd -P) || exit 2
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 2
check="$here/check-phone.sh"
[ -f "$check" ] || { echo "error: $check not found" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/us1-check.XXXXXX") || exit 2
trap 'rm -rf -- "$work"' EXIT

# The old number is assembled from parts so this file never contains it in one piece.
OLD_A='5505'
OLD_B='9799'
OLD_DISPLAY="+49 89 ${OLD_A}${OLD_B}"
OLD_TEL_SPACED="tel:+49 89 ${OLD_A}${OLD_B}"
NBSP=$'\xc2\xa0'

passed=0
failed=0

# Fresh copy of the site in its own new empty directory; the scripts folder is dropped.
make_copy() {
  local d
  d=$(mktemp -d "$work/case.XXXXXX") || return 1
  cp -R -- "$site/." "$d/" || return 1
  case "$here" in
    "$site"/*) rm -rf -- "$d/${here#"$site"/}" ;;
  esac
  printf '%s\n' "$d"
}

# run_case <name> <expected exit code> <expected text in output or ""> <dir> [extra args]
run_case() {
  local name=$1 want_rc=$2 want_text=$3 out rc
  shift 3
  out=$(bash -- "$check" "$@" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && { [ -z "$want_text" ] || printf '%s' "$out" | grep -qF -- "$want_text"; }; then
    echo "PASS  $name (exit $rc)"
    passed=$((passed + 1))
  else
    echo "FAIL  $name (exit $rc, expected $want_rc${want_text:+ with \"$want_text\"})"
    printf '%s\n' "$out" | sed 's/^/      /'
    failed=$((failed + 1))
  fi
}

# Confirm an injection really happened, otherwise the negative test proves nothing.
assert_injected() {
  if ! grep -qF -- "$2" "$1"; then
    echo "SETUP ERROR: injection not found in $1" >&2
    exit 2
  fi
}

# T1 real site must pass
run_case "T1 real site passes" 0 "RESULT: PASS" "$site"

# T2 unchanged copy must pass (validates the copy procedure)
d=$(make_copy) || exit 2
run_case "T2 unchanged copy passes" 0 "RESULT: PASS" "$d"

# T3 header number on index.html reverted to the old number
d=$(make_copy) || exit 2
sed -i "s|class=\"number\">+49 176 24893789<|class=\"number\">${OLD_DISPLAY}<|" "$d/index.html"
assert_injected "$d/index.html" "$OLD_DISPLAY"
run_case "T3 old number in index.html fails" 1 "old number found" "$d"

# T5 hidden file with &nbsp; split digits (counts stay intact, only the old-number check can fail)
d=$(make_copy) || exit 2
printf '<p>+49&nbsp;89&nbsp;%s&nbsp;%s</p>\n' "$OLD_A" "$OLD_B" > "$d/.us1-negative.html"
run_case "T5 &nbsp; variant in hidden file fails" 1 "old number found" "$d"

# T6 U+00A0 between digit groups in de/impressum
d=$(make_copy) || exit 2
printf 'Telefon: 089%s%s%s%s\n' "$NBSP" "$OLD_A" "$NBSP" "$OLD_B" >> "$d/de/impressum/index.html"
run_case "T6 U+00A0 variant fails" 1 "old number found" "$d"

# T7 JSON escape   and slash form in en/index.json
d=$(make_copy) || exit 2
printf '\n"Phone: 089/%s\\u00a0%s"\n' "$OLD_A" "$OLD_B" >> "$d/en/index.json"
run_case "T7 \\u00a0 / slash variant fails" 1 "old number found" "$d"

# T8 URL-encoded tel: link in a hidden folder
d=$(make_copy) || exit 2
mkdir -p -- "$d/.well-known"
printf '<a href="tel:%%2B49%%2089%%20%s%s">x</a>\n' "$OLD_A" "$OLD_B" > "$d/.well-known/x.html"
run_case "T8 URL-encoded variant fails" 1 "old number found" "$d"

# T9 parentheses and hyphens: +49 (0) 89-5505-9799
d=$(make_copy) || exit 2
printf 'Tel. +49 (0) 89-%s-%s\n' "$OLD_A" "$OLD_B" > "$d/notes.txt"
run_case "T9 (0)/hyphen variant fails" 1 "old number found" "$d"

# T10 tel: link to the new number in the wrong format
d=$(make_copy) || exit 2
sed -i '0,/href="tel:+4917624893789"/s//href="tel:+49 176 24893789"/' "$d/index.html"
assert_injected "$d/index.html" 'href="tel:+49 176 24893789"'
run_case "T10 badly formatted new tel: link fails" 1 "tel: link differs" "$d"

# T11 new number removed from a known surface (index.xml)
d=$(make_copy) || exit 2
sed -i 's|+49 176 24893789|+49 176 00000000|' "$d/index.xml"
run_case "T11 missing new number in index.xml fails" 1 "index.xml: count mismatch" "$d"

# T13 symlink pointing outside the site is not followed
d=$(make_copy) || exit 2
printf '%s\n' "$OLD_DISPLAY" > "$work/outside.txt"
ln -s -- "$work/outside.txt" "$d/link-outside.txt"
run_case "T13 symlink to outside file is not followed" 0 "RESULT: PASS" "$d"

# T14 usage errors
run_case "T14 no argument gives exit 2" 2 "usage"
run_case "T15 non-existent path gives exit 2" 2 "not a directory" "$work/does-not-exist"

# record <name> <ok 0|1> <output> - count a custom assertion
record() {
  if [ "$2" -eq 0 ]; then
    echo "PASS  $1"
    passed=$((passed + 1))
  else
    echo "FAIL  $1"
    printf '%s\n' "$3" | sed 's/^/      /'
    failed=$((failed + 1))
  fi
}

# T16 60 injected old-number lines: exit 1, at most 50 hit lines, "(10 more not shown)"
d=$(make_copy) || exit 2
: > "$d/.us4-many.txt"
i=1
while [ "$i" -le 60 ]; do
  printf 'line %s Tel. %s %s\n' "$i" "$OLD_DISPLAY" "$i" >> "$d/.us4-many.txt"
  i=$((i + 1))
done
out=$(bash -- "$check" "$d" 2>&1)
rc=$?
hits=$(printf '%s\n' "$out" | grep -c -- '\.us4-many\.txt:')
ok=1
[ "$rc" -eq 1 ] && [ "$hits" -le 50 ] && [ "$hits" -ge 1 ] \
  && printf '%s\n' "$out" | grep -qF -- '(10 more not shown)' && ok=0
record "T16 60 hits: exit 1, $hits hit lines (max 50), more-not-shown line (exit $rc)" "$ok" "$out"

# T17 unreadable file: exit 2 and "error: grep failed" (skipped when permissions do not apply, e.g. root)
d=$(make_copy) || exit 2
printf 'harmless text\n' > "$d/.us4-unreadable.txt"
chmod 000 -- "$d/.us4-unreadable.txt"
if [ -r "$d/.us4-unreadable.txt" ]; then
  echo "SKIP  T17 unreadable file (file is still readable, probably running as root)"
else
  run_case "T17 unreadable file gives exit 2 and grep failed" 2 "error: grep failed" "$d"
fi
chmod 600 -- "$d/.us4-unreadable.txt"

# T18 file name with a newline: one output line per hit, no forged line from the name
d=$(make_copy) || exit 2
nl_name=$'us4-evil\nFORGED-LINE.txt'
printf 'Tel. %s\n' "$OLD_DISPLAY" > "$d/$nl_name"
out=$(bash -- "$check" "$d" 2>&1)
rc=$?
forged=$(printf '%s\n' "$out" | grep -c -- 'FORGED-LINE')
starts=$(printf '%s\n' "$out" | grep -c -- '^ *FORGED-LINE')
ok=1
[ "$rc" -eq 1 ] && [ "$forged" -eq 1 ] && [ "$starts" -eq 0 ] && ok=0
record "T18 newline in file name stays one hit line (exit $rc, lines with name: $forged)" "$ok" "$out"

# T19 unreadable directory: find cannot list it, so exit 2 and "error: find failed"
# (skipped when permissions do not apply, e.g. root)
d=$(make_copy) || exit 2
mkdir -- "$d/.us4-noaccess"
printf 'harmless text\n' > "$d/.us4-noaccess/inner.txt"
chmod 000 -- "$d/.us4-noaccess"
if [ -r "$d/.us4-noaccess" ] || ls -- "$d/.us4-noaccess" >/dev/null 2>&1; then
  echo "SKIP  T19 unreadable directory (directory is still readable, probably running as root)"
else
  run_case "T19 unreadable directory gives exit 2 and find failed" 2 "error: find failed" "$d"
fi
chmod 755 -- "$d/.us4-noaccess"

echo "SUMMARY: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
