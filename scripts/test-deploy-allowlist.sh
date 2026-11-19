#!/usr/bin/env bash
# Author: Jonas Kufner
# Web:    https://jonaskufner.com
#
# test-deploy-allowlist.sh - automated tests for the allow-list deploy in
# .github/workflows/pages.yml and for the top-level entries of the repo (US-4).
#
# Runs the checks once against the real site (must pass), then against fresh copies in a
# new empty temp directory, each with one defect injected. A negative case passes only if
# the check fails (exit 1), reports the expected text, and the unchanged copy does NOT
# report that text, so every defect is caught for its own reason.
# pages.yml and the copies are only read and edited as data; nothing in them is run.
#
# Checks on pages.yml (comments ignored):
#   - cp sources == allow-listed files, rsync sources == allow-listed folders (exact sets)
#   - copy destination is _site/, no '.', './', '..', absolute path, glob or variable as source
#   - rsync excludes '*.md_tbd'; stage step starts from an empty _site
#   - upload 'path:' is exactly _site
#   - the three action pins are unchanged, no other action, 'branches: [main]' present
#   - the guard step names README.md, CHANGELOG.md, SECURITY.md, scripts, .github, .git,
#     'index copy.html', *.md_tbd, has a symlink check and 'exit 1'
# Checks on <site-path>: every top-level entry is on the allow-list or the exclude list
# (and is not a symlink if it is allow-listed); anything else is named and fails.
#
# ASSUMPTION about the workflow layout: the stage step uses plain `cp ... _site/` and
# `rsync ... _site/` commands with literal names (line continuations with \ are allowed);
# the guard is a step whose name contains "guard". A shell loop over a variable list
# would be reported as "variable" source on purpose (the list must be literal).
#
# Usage:      scripts/test-deploy-allowlist.sh <site-path>
# Exit codes: 0 = all tests passed, 1 = at least one test failed, 2 = usage/setup error.

set -u
export LC_ALL=C

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <site-path>" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "usage: $0 <site-path>" >&2
  echo "error: not a directory: $1" >&2
  exit 2
fi
site=$(CDPATH='' cd -- "$1" && pwd -P) || exit 2
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 2
self="$here/$(basename -- "$0")"

work=$(mktemp -d "${TMPDIR:-/tmp}/us4-allow.XXXXXX") || exit 2
trap 'rm -rf -- "$work"' EXIT

# ---------------------------------------------------------------- expected content (US-4)

ALLOW_FILES=(index.html 404.html CNAME .nojekyll robots.txt sitemap.xml landing-sitemap.xml
  index.xml index.json)
ALLOW_DIRS=(about assets categories contact css datenschutz de en impressum js landing posts
  tags ueber-mich)
EXCLUDES=(.git .github scripts README.md CHANGELOG.md SECURITY.md 'index copy.html')
GUARD_NAMES=(README.md CHANGELOG.md SECURITY.md scripts .github 'index copy.html' '*.md_tbd')
PINS=(actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
  actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa
  actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e)

in_list() { local n=$1 x; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# guard_filter keep|drop: stdin is the workflow; "keep" prints only the step whose name
# contains "guard", "drop" prints everything except that step.
guard_filter() {
  awk -v mode="$1" '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    { isb = 0
      if (inb) { if ($0 ~ /^[ \t]*$/) isb = 1; else if (ind($0) > n) isb = 1; else inb = 0 }
      if (!inb && $0 ~ /^[ \t]*- name:.*[Gg]uard/) { inb = 1; n = ind($0); isb = 1 }
      if (mode == "keep" && isb) print
      if (mode == "drop" && !isb) print }'
}

# parse_copies: stdin is the workflow without comments. Joins "\" continuations and prints
#   S <cmd> <source>   D <cmd> <destination>   X <cmd> <exclude/include value>
parse_copies() {
  sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' | awk '
    function split_tokens(s, a,   n, i, c, q, cur, has) {
      n = 0; q = ""; cur = ""; has = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; else cur = cur c; continue }
        if (c == "\"" || c == "\047") { q = c; has = 1; continue }
        if (c == "\\") { i++; cur = cur substr(s, i, 1); has = 1; continue }
        if (c == " " || c == "\t") { if (has || cur != "") { a[++n] = cur; cur = ""; has = 0 } continue }
        cur = cur c; has = 1
      }
      if (has || cur != "") a[++n] = cur
      return n
    }
    {
      line = $0; sub(/^[ \t]+/, "", line)
      if (line !~ /^(cp|rsync)([ \t]|$)/) next
      n = split_tokens(line, t); cmd = t[1]; endopt = 0; np = 0
      for (i = 2; i <= n; i++) {
        w = t[i]
        if (w == "&&" || w == ";" || w == "||") break
        if (!endopt && w == "--") { endopt = 1; continue }
        if (!endopt && (w == "--exclude" || w == "--include")) { i++; print "X\t" cmd "\t" t[i]; continue }
        if (!endopt && w ~ /^--(exclude|include)=/) { v = w; sub(/^[^=]*=/, "", v); print "X\t" cmd "\t" v; continue }
        if (!endopt && w ~ /^-/) continue
        pos[++np] = w
      }
      if (np == 0) next
      print "D\t" cmd "\t" pos[np]
      for (j = 1; j < np; j++) print "S\t" cmd "\t" pos[j]
    }'
}

# --------------------------------------------------------------------------- the checks

errs=0
err() { echo "ERROR: $*"; errs=$((errs + 1)); }

# diff_sets <label> <wanted newline list> <have newline list>
diff_sets() {
  local label=$1 want have missing extra p
  want=$(printf '%s\n' "$2" | sort -u)
  have=$(printf '%s\n' "$3" | sed '/^$/d' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
  extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
  while IFS= read -r p; do
    [ -n "$p" ] && err "$label: allow-list entry '$p' is not copied"
  done <<< "$missing"
  while IFS= read -r p; do
    [ -n "$p" ] && err "$label: unexpected source '$p'"
  done <<< "$extra"
}

check_site() {
  local s=$1 wf body parsed cmd p pin u gb g e ups n_ups
  local cp_src rsync_src want_files want_dirs
  errs=0
  wf="$s/.github/workflows/pages.yml"

  if [ -L "$wf" ] || [ ! -f "$wf" ]; then
    err ".github/workflows/pages.yml: missing"
  else
    body=$(grep -vE '^[[:space:]]*#' "$wf")
    parsed=$(printf '%s\n' "$body" | parse_copies)

    # -- 1. cp / rsync sources match the allow-list exactly
    cp_src=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "S" && $2 == "cp" { print $3 }')
    rsync_src=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "S" && $2 == "rsync" { print $3 }')
    want_files=$(printf '%s\n' "${ALLOW_FILES[@]}")
    want_dirs=$(printf '%s\n' "${ALLOW_DIRS[@]}")
    diff_sets "cp" "$want_files" "$cp_src"
    diff_sets "rsync" "$want_dirs" "$(printf '%s\n' "$rsync_src" | sed 's|/$||')"

    # -- 2. no root / parent / absolute / glob / variable source; destination is _site/
    while IFS=$'\t' read -r _ cmd p; do
      [ -n "$cmd" ] || continue
      case "$p" in
        . | ./ | .. | ../* | /* | *'*'* | *'$'* | *'`'* | *..*)
          err "copy source '$p' is not allowed ($cmd: repo root, parent, absolute path, glob or variable)" ;;
      esac
      if [ "$cmd" = "rsync" ]; then
        case "$p" in */) err "rsync source '$p' ends with '/': copies the contents into the _site root" ;; esac
      fi
    done < <(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "S"')
    while IFS=$'\t' read -r _ cmd p; do
      [ -n "$cmd" ] || continue
      case "$p" in
        _site | _site/) ;;
        *) err "$cmd destination '$p' must be _site/" ;;
      esac
    done < <(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "D"')
    if ! printf '%s\n' "$parsed" | awk -F'\t' '$1 == "X" && $2 == "rsync" && $3 == "*.md_tbd" { f = 1 } END { exit !f }'; then
      err "rsync: missing --exclude '*.md_tbd'"
    fi
    if ! printf '%s\n' "$body" | grep -Eq -- 'rm -[a-zA-Z]+[[:space:]]+(--[[:space:]]+)?_site' \
       || ! printf '%s\n' "$body" | grep -Eq -- 'mkdir[^|&;]*_site'; then
      err "pages.yml: stage step does not start from an empty _site (rm -rf _site && mkdir _site)"
    fi

    # -- 3. upload path is exactly _site
    ups=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*path:[[:space:]]*//p' | sed "s/[[:space:]]*\$//; s/^['\"]//; s/['\"]\$//")
    n_ups=$(printf '%s' "$ups" | grep -c .)
    if [ "$n_ups" -eq 0 ]; then
      err "pages.yml: upload path must be _site, found nothing"
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$p" = "_site" ] || err "pages.yml: upload path must be _site, found '$p'"
    done <<< "$ups"

    # -- 4. pins unchanged, no other action, branches: [main]
    for pin in "${PINS[@]}"; do
      printf '%s\n' "$body" | grep -qF -- "uses: $pin" || err "pages.yml: pinned action missing or changed: $pin"
    done
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      in_list "$u" "${PINS[@]}" || err "pages.yml: unexpected action: $u"
    done < <(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*//p' | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')
    printf '%s\n' "$body" | grep -Eq -- '^[[:space:]]*branches:[[:space:]]*\[[[:space:]]*main[[:space:]]*\]' \
      || err "pages.yml: 'branches: [main]' missing"

    # -- 5. guard step
    gb=$(printf '%s\n' "$body" | guard_filter keep)
    if [ -z "$gb" ]; then
      err "pages.yml: guard step missing (no step whose name contains 'guard')"
    else
      for g in "${GUARD_NAMES[@]}"; do
        printf '%s\n' "$gb" | grep -qF -- "$g" || err "pages.yml: guard does not name '$g'"
      done
      printf '%s\n' "$gb" | grep -Eq -- '(^|[^A-Za-z0-9_.])\.git([^A-Za-z0-9_.]|$)' \
        || err "pages.yml: guard does not name '.git'"
      printf '%s\n' "$gb" | grep -Eq -- '-type[[:space:]]+l|[[:space:]]-L[[:space:]]' \
        || err "pages.yml: guard has no symlink check (find -type l or [ -L ])"
      printf '%s\n' "$gb" | grep -Eq -- '(^|[[:space:]])exit[[:space:]]+1' \
        || err "pages.yml: guard does not exit 1"
    fi
  fi

  # -- 6. every top-level entry is allow-listed or excluded
  while IFS= read -r -d '' e; do
    e=${e##*/}
    if in_list "$e" "${EXCLUDES[@]}"; then
      continue
    elif in_list "$e" "${ALLOW_FILES[@]}" "${ALLOW_DIRS[@]}"; then
      if [ -L "$s/$e" ]; then err "top-level entry '$e' is a symlink"; fi
    else
      err "top-level entry '$e' is neither on the allow-list nor on the exclude list"
    fi
  done < <(find "$s" -mindepth 1 -maxdepth 1 -print0)

  if [ "$errs" -eq 0 ]; then
    echo "RESULT: PASS"
    return 0
  fi
  echo "RESULT: FAIL ($errs error(s))"
  return 1
}

# --------------------------------------------------------------------------- the harness

passed=0
failed=0

# Fresh copy of the site in its own new empty directory; scripts/ and .git are dropped
# (both are on the exclude list, so the top-level check is unaffected).
make_copy() {
  local d
  d=$(mktemp -d "$work/case.XXXXXX") || return 1
  cp -R -- "$site/." "$d/" || return 1
  rm -rf -- "$d/.git" "$d/scripts"
  printf '%s\n' "$d"
}

pass_case() { echo "PASS  $1"; passed=$((passed + 1)); }
fail_case() {
  echo "FAIL  $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'
  failed=$((failed + 1))
}

run_pos() {
  local out rc
  out=$(check_site "$2" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass_case "$1 (exit 0)"; else fail_case "$1 (exit $rc, expected 0)" "$out"; fi
}

run_neg() {
  local name=$1 want_text=$2 out rc
  out=$(check_site "$3" 2>&1); rc=$?
  if printf '%s' "$baseline_out" | grep -qF -- "$want_text"; then
    fail_case "$name (not isolated: the unchanged copy already reports \"$want_text\")"
  elif [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF -- "$want_text"; then
    pass_case "$name (exit 1)"
  else
    fail_case "$name (exit $rc, expected 1 with \"$want_text\")" "$out"
  fi
}

run_self() {
  local name=$1 want_rc=$2 want_text=$3 out rc
  shift 3
  out=$(bash -- "$self" "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_text"; then
    pass_case "$name (exit $rc)"
  else
    fail_case "$name (exit $rc, expected $want_rc with \"$want_text\")" "$out"
  fi
}

# awk_edit <file> <awk args...>: rewrite; fails if file missing or unchanged.
awk_edit() {
  local f=$1 t
  shift
  [ -f "$f" ] || return 1
  t="$f.us4-tmp"
  if ! awk "$@" "$f" > "$t"; then rm -f -- "$t"; return 1; fi
  if cmp -s -- "$f" "$t"; then rm -f -- "$t"; return 1; fi
  mv -- "$t" "$f"
}
# drop_guard <file>: remove the guard step; fails if nothing changed.
drop_guard() {
  local f=$1 t="$1.us4-tmp"
  [ -f "$f" ] || return 1
  guard_filter drop < "$f" > "$t"
  if cmp -s -- "$f" "$t"; then rm -f -- "$t"; return 1; fi
  mv -- "$t" "$f"
}
setup_fail() { fail_case "$1 (setup: injection target not found - $2)"; }

WF=".github/workflows/pages.yml"

# T1 real site must pass
run_pos "T1 real site passes" "$site"

# T2 unchanged copy must pass; its output is the baseline
d=$(make_copy) || exit 2
baseline_out=$(check_site "$d" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass_case "T2 unchanged copy passes (exit 0)"; else fail_case "T2 unchanged copy passes (exit $rc, expected 0)" "$baseline_out"; fi

# T3 README.md added to the cp line
d=$(make_copy) || exit 2
if awk_edit "$d/$WF" '!done && /^[ \t]*cp[ \t]/ { sub(/cp[ \t]+/, "cp README.md "); done = 1 } { print }'; then
  run_neg "T3 README.md in the cp line fails" "cp: unexpected source 'README.md'" "$d"
else setup_fail "T3 README.md in the cp line fails" "no cp line in pages.yml"; fi

# T4 '.' as copy source
d=$(make_copy) || exit 2
if awk_edit "$d/$WF" '!done && /^[ \t]*cp[ \t]/ { sub(/cp[ \t]+/, "cp . "); done = 1 } { print }'; then
  run_neg "T4 '.' as copy source fails" "copy source '.' is not allowed" "$d"
else setup_fail "T4 '.' as copy source fails" "no cp line in pages.yml"; fi

# T5 upload path is the repo root
d=$(make_copy) || exit 2
if awk_edit "$d/$WF" '{ if ($0 ~ /^[ \t]*path:/) sub(/path:.*/, "path: ."); print }'; then
  run_neg "T5 upload 'path: .' fails" "upload path must be _site, found '.'" "$d"
else setup_fail "T5 upload 'path: .' fails" "no 'path:' line"; fi

# T6 new top-level folder foo/
d=$(make_copy) || exit 2
mkdir -- "$d/foo" && : > "$d/foo/index.html"
run_neg "T6 new folder foo/ fails" "top-level entry 'foo' is neither on the allow-list nor on the exclude list" "$d"

# T7 guard step removed
d=$(make_copy) || exit 2
if drop_guard "$d/$WF"; then
  run_neg "T7 guard removed fails" "guard step missing" "$d"
else setup_fail "T7 guard removed fails" "no step whose name contains 'guard'"; fi

# T8 pinned SHA changed
d=$(make_copy) || exit 2
if awk_edit "$d/$WF" '{ sub(/11bd71901bbe5b1630ceea73d27597364c9af683/, "0000000000000000000000000000000000000000"); print }'; then
  run_neg "T8 changed checkout pin fails" "pinned action missing or changed: actions/checkout@11bd" "$d"
else setup_fail "T8 changed checkout pin fails" "checkout pin not found"; fi

# T9 branches: [main] removed
d=$(make_copy) || exit 2
if awk_edit "$d/$WF" '!/^[ \t]*branches:/'; then
  run_neg "T9 branches removed fails" "'branches: [main]' missing" "$d"
else setup_fail "T9 branches removed fails" "no branches: line"; fi

# T10/T11 usage errors
run_self "T10 no argument gives exit 2" 2 "usage"
run_self "T11 non-existent path gives exit 2" 2 "not a directory" "$work/does-not-exist"

echo "SUMMARY: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
