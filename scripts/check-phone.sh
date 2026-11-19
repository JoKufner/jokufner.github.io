#!/usr/bin/env bash
# Author: Jonas Kufner
# Web:    https://jonaskufner.com
#
# check-phone.sh - US-1 regression check for the static site.
#
# Checks:
#   1. The old Munich phone number (replaced in US-1) appears in no text file, in any
#      spelling: spaces, &nbsp;, &#160;, &#xA0;, U+00A0,  , %20, %C2%A0, hyphens,
#      dots, slashes or parentheses between the digits. Hidden files are included.
#   2. Every tel: link in the site is exactly tel:+4917624893789.
#   3. The new number appears with the expected count on every known surface, and every
#      occurrence outside a tel: link uses the display format "+49 176 24893789".
#
# Usage:      scripts/check-phone.sh <site-path>
# Exit codes: 0 = pass, 1 = check failed, 2 = usage or environment error.
#
# The site folder is treated as untrusted data: nothing in it is executed or sourced,
# symlinks are not followed, and printed lines and paths are stripped of control
# characters. At most MAX_SHOWN hit lines are printed per check.
# If this script's own folder lies inside the site, that folder is skipped.

set -uo pipefail
export LC_ALL=C

NEW_DIGITS='24893789'
NEW_DISPLAY='+49 176 24893789'
NEW_TEL='tel:+4917624893789'
MAX_SHOWN=50

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <site-path>" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "error: not a directory: $1" >&2
  exit 2
fi
for tool in find grep sed tr cut wc dirname mktemp rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: required tool missing: $tool" >&2; exit 2; }
done

site=$(CDPATH='' cd -- "$1" && pwd -P) || exit 2
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 2
if [ "$site" = "$script_dir" ]; then
  echo "error: the script must not sit in the site root itself" >&2
  exit 2
fi

# Work dir outside the site for find's stderr; removed on exit.
work_dir=$(mktemp -d) || { echo "error: cannot create work dir" >&2; exit 2; }
trap 'rm -rf -- "$work_dir"' EXIT
find_err="$work_dir/find.err"

# NUL-separated list of regular files. Symlinks are not followed; the script folder is pruned.
list_files() {
  find "$site" -type d -samefile "$script_dir" -prune -o -type f -print0
}

# Remove control characters (keeps tab and newline) and cap the line length.
sanitize() {
  tr -d '\000-\010\013-\037\177' | cut -c1-240
}

# Path relative to the site, on one line: every control character (newline included)
# becomes '?', so a crafted file name cannot split or forge a hit line.
safe_path() {
  printf '%s' "${1#"$site"/}" | tr '\000-\037\177' '?' | cut -c1-200
}

# scan <grep-options> <regex>
# Runs grep on each file separately and prints "<safe relative path>:<grep line>".
# grep rc 0 = hit, rc 1 = no hit, rc >= 2 = error: message on stderr, exit 2.
# The grep options must include -h, so the path prefix comes from safe_path only.
scan() {
  local opts=$1 re=$2 f out rc rel line
  : >"$find_err" || { echo "error: cannot write work dir" >&2; exit 2; }
  while IFS= read -r -d '' f; do
    out=$(grep "$opts" -e "$re" -- "$f")
    rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) printf 'error: grep failed on %s\n' "$(safe_path "$f")" >&2
         exit 2 ;;
    esac
    rel=$(safe_path "$f")
    while IFS= read -r line; do
      printf '%s:%s\n' "$rel" "$line"
    done <<<"$out"
  done < <(list_files 2>"$find_err")
  # The process substitution hides find's exit status, so check its stderr instead.
  if [ -s "$find_err" ]; then
    echo "error: find failed" >&2
    exit 2
  fi
}

# count_lines <text>: number of lines in a non-empty text.
count_lines() {
  printf '%s\n' "$1" | wc -l | tr -d '[:space:]'
}

# print_hits <text>: indented, at most MAX_SHOWN lines, then a note on the rest.
print_hits() {
  local n
  n=$(count_lines "$1")
  printf '%s\n' "$1" | sed -n "1,${MAX_SHOWN}p" | while IFS= read -r line; do
    printf '  %s\n' "$line"
  done
  if [ "$n" -gt "$MAX_SHOWN" ]; then
    printf '  ... (%s more not shown)\n' "$((n - MAX_SHOWN))"
  fi
}

failures=0
fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

# --- 1. Old number --------------------------------------------------------------------
NBSP=$'\xc2\xa0'
SEP='([[:space:]]|&nbsp;|&#0*160;|&#[xX]0*[aA]0;|\\u00[aA]0|%20|%[cC]2%[aA]0|'"$NBSP"'|[-./()])*'
OLD_RE="5${SEP}5${SEP}0${SEP}5${SEP}9${SEP}7${SEP}9${SEP}9"

old_hits=$(scan -IhniE "$OLD_RE" | sanitize) || exit 2
if [ -n "$old_hits" ]; then
  fail "old number found in $(count_lines "$old_hits") line(s) (file:line:content):"
  print_hits "$old_hits"
else
  echo "ok   no old-number variant in any text file"
fi

# --- 2. tel: links --------------------------------------------------------------------
# A tel: token not preceded by a letter/digit (skips words such as "Untertitel:") and
# followed by at least one non-space character. Each must be exactly the new tel: link.
TEL_RE='(^|[^[:alnum:]_])tel:[^"'\''<>[:space:]]+'
tel_all=$(scan -IhnoE "$TEL_RE") || exit 2
tel_bad=''
if [ -n "$tel_all" ]; then
  tel_bad=$(printf '%s\n' "$tel_all" | grep -vE '[^[:alnum:]_]tel:\+4917624893789$' | sanitize)
fi
if [ -n "$tel_bad" ]; then
  fail "tel: link differs from $NEW_TEL in $(count_lines "$tel_bad") place(s) (file:line:link):"
  print_hits "$tel_bad"
else
  echo "ok   every tel: link is exactly $NEW_TEL"
fi

# --- 3. Expected new-number counts per surface ----------------------------------------
# path | occurrences of the digits 24893789 | occurrences of tel:+4917624893789
while IFS='|' read -r rel want_digits want_tel; do
  [ -n "$rel" ] || continue
  f="$site/$rel"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    fail "$rel: missing or a symlink"
    continue
  fi
  got_digits=$(grep -oF -- "$NEW_DIGITS" "$f" | wc -l | tr -d '[:space:]')
  got_tel=$(grep -oF -- "$NEW_TEL" "$f" | wc -l | tr -d '[:space:]')
  got_display=$(grep -oF -- "$NEW_DISPLAY" "$f" | wc -l | tr -d '[:space:]')
  want_display=$((want_digits - want_tel))
  if [ "$got_digits" -ne "$want_digits" ] || [ "$got_tel" -ne "$want_tel" ] \
     || [ "$got_display" -ne "$want_display" ]; then
    fail "$rel: count mismatch - digits $got_digits/$want_digits, tel $got_tel/$want_tel, display $got_display/$want_display"
  else
    echo "ok   $rel: digits $got_digits, tel $got_tel, display $got_display"
  fi
done <<'EOF'
index.html|8|3
de/impressum/index.html|2|0
de/datenschutz/index.html|2|0
en/impressum/index.html|2|0
en/datenschutz/index.html|2|0
index.json|4|0
de/index.json|4|0
en/index.json|4|0
index.xml|2|0
EOF

if [ "$failures" -gt 0 ]; then
  echo "RESULT: FAIL ($failures problem group(s))"
  exit 1
fi
echo "RESULT: PASS"
exit 0
