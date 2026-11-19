#!/usr/bin/env bash
# Author: Jonas Kufner
# Web:    https://jonaskufner.com
#
# test-robots.sh - automated tests for the root robots.txt and its deploy setup (US-3).
#
# Runs the checks once against the real site (must pass), then against fresh copies in a
# new empty temp directory, each with one defect injected. A negative case passes only if
# the check fails (exit 1), reports the expected text, and the unchanged copy does NOT
# report that text, so every defect is caught for its own reason.
# The site, its copies and the workflow file are only read and edited as data; nothing
# inside them is run.
#
# Note (US-4): while 'index copy.html' still exists in the repo root, T1 and T2 fail
# (check 8) and T18 fails as "not isolated" (the unchanged copy already reports it). They
# pass once the developer has deleted that file. The deploy checks (check 9) follow the
# allow-list workflow: path _site, no rsync ./ or cp -R ., guard names the excluded items.
#
# Usage:      scripts/test-robots.sh <site-path>
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

work=$(mktemp -d "${TMPDIR:-/tmp}/us3-robots.XXXXXX") || exit 2
trap 'rm -rf -- "$work"' EXIT

# ---------------------------------------------------------------- expected content (US-3)

BLOCKED_AGENTS=(GPTBot ClaudeBot anthropic-ai Google-Extended CCBot Bytespider
  Applebot-Extended Meta-ExternalAgent Amazonbot ChatGPT-User Claude-User
  Perplexity-User Meta-ExternalFetcher Diffbot ImagesiftBot Omgilibot cohere-ai
  FacebookBot)

# Never disallowed anywhere (so never on a post path) and, except '*', never with a group
# of their own. '*' is quoted so it is never globbed.
ALLOWED_AGENTS=('*' Googlebot Bingbot OAI-SearchBot Claude-SearchBot PerplexityBot
  facebookexternalhit)

# Identical Disallow list for every blocked group (21 lines). Root /search/, /page/ and /
# are deliberately absent (the first two do not exist, / is the landing page).
EXPECTED_PATHS=('/de/$' '/de/posts/' '/de/categories/' '/de/tags/' '/de/search/' '/de/page/'
  '/de/index.xml' '/de/index.json'
  '/en/$' '/en/posts/' '/en/categories/' '/en/tags/' '/en/search/' '/en/page/'
  '/en/index.xml' '/en/index.json'
  '/posts/' '/categories/' '/tags/'
  '/index.xml' '/index.json')

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

# --------------------------------------------------------------------------- the checks

errs=0
err() { echo "ERROR: $*"; errs=$((errs + 1)); }

# Parse robots.txt into tab-separated records:
#   A <group> <agent lowercase> <agent as written>
#   R <group> <allow|disallow> <value>
#   S 0 <sitemap url>
#   E <line> <message>
# A User-agent line after rule lines starts a new group (RFC 9309). Comments and blank
# lines are ignored; a trailing CR is stripped here (CRLF is reported separately).
parse_robots() {
  awk '
    BEGIN { g = 0; inrules = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      i = index(line, ":")
      if (i == 0) { print "E\t" NR "\tnot a \"field: value\" line"; next }
      f = tolower(substr(line, 1, i - 1)); gsub(/[ \t]+$/, "", f)
      v = substr(line, i + 1); gsub(/^[ \t]+/, "", v)
      if (f == "user-agent") {
        if (g == 0 || inrules) { g++; inrules = 0 }
        print "A\t" g "\t" tolower(v) "\t" v
        next
      }
      if (f == "allow" || f == "disallow") {
        if (g == 0) { print "E\t" NR "\t" f " outside a group (no User-agent line before it)"; next }
        inrules = 1
        print "R\t" g "\t" f "\t" v
        next
      }
      if (f == "sitemap") { print "S\t0\t" v; next }
      print "E\t" NR "\tunknown field \"" f "\""
    }' "$1"
}

check_site() {
  local s=$1 r parsed name lc gs n g others have want missing extra allows rules p
  local anchored base rel f dir domain want_sm n_exact n_all wf body x upaths joined guard
  errs=0
  r="$s/robots.txt"
  want=$(printf '%s\n' "${EXPECTED_PATHS[@]}" | sort)

  # -- 1. robots.txt exists, regular file, not empty, not a symlink
  local robots_ok=1
  if [ -L "$r" ]; then err "robots.txt: is a symlink"; robots_ok=0
  elif [ ! -e "$r" ]; then err "robots.txt: missing"; robots_ok=0
  elif [ ! -f "$r" ]; then err "robots.txt: not a regular file"; robots_ok=0
  elif [ ! -s "$r" ]; then err "robots.txt: empty"; robots_ok=0
  fi

  if [ "$robots_ok" -eq 1 ]; then
    # -- 7. format: no CR, no secrets, every rule inside a group
    if grep -q $'\r' "$r"; then err "robots.txt: contains CR characters (CRLF line endings)"; fi
    if grep -qEi -- 'ghp_|github_pat_|AKIA[0-9A-Z]{16}|-----BEGIN|(api[_-]?key|access[_-]?token|secret|password)[[:space:]]*[=:]' "$r"; then
      err "robots.txt: contains something that looks like a token or key"
    fi
    parsed=$(parse_robots "$r")
    while IFS=$'\t' read -r _ n p; do
      err "robots.txt line $n: $p"
    done < <(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "E"')

    # -- 2. each blocked agent: exactly one group, only this agent, identical Disallow list
    for name in "${BLOCKED_AGENTS[@]}"; do
      lc=$(lower "$name")
      gs=$(printf '%s\n' "$parsed" | awk -F'\t' -v a="$lc" '$1 == "A" && $3 == a { print $2 }' | sort -u)
      n=$(printf '%s' "$gs" | grep -c .)
      if [ "$n" -ne 1 ]; then
        err "robots.txt: agent '$name': expected exactly one group, found $n"
        continue
      fi
      g=$gs
      others=$(printf '%s\n' "$parsed" | awk -F'\t' -v g="$g" -v a="$lc" '$1 == "A" && $2 == g && $3 != a { print $4 }' | oneline)
      [ -z "$others" ] || err "robots.txt: agent '$name': group must name only this agent, also names: $others"
      allows=$(printf '%s\n' "$parsed" | awk -F'\t' -v g="$g" '$1 == "R" && $2 == g && $3 == "allow" { print $4 }' | oneline)
      [ -z "$allows" ] || err "robots.txt: agent '$name': unexpected Allow line(s): $allows"
      have=$(printf '%s\n' "$parsed" | awk -F'\t' -v g="$g" '$1 == "R" && $2 == g && $3 == "disallow" { print ($4 == "" ? "(empty)" : $4) }' | sort)
      missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
      extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
      while IFS= read -r p; do
        [ -n "$p" ] && err "robots.txt: agent '$name': missing Disallow $p"
      done <<< "$missing"
      while IFS= read -r p; do
        [ -n "$p" ] && err "robots.txt: agent '$name': unexpected Disallow $p"
      done <<< "$extra"
    done

    # -- 3./4. search engines and AI search bots: never a non-empty Disallow
    for name in "${ALLOWED_AGENTS[@]}"; do
      lc=$(lower "$name")
      if [ "$lc" != "*" ] && printf '%s\n' "$parsed" | awk -F'\t' -v a="$lc" '$1 == "A" && $3 == a { f = 1 } END { exit !f }'; then
        err "robots.txt: agent '$name': must not have a group of its own"
      fi
      while IFS= read -r p; do
        [ -n "$p" ] && err "robots.txt: agent '$name': must not be disallowed (Disallow: $p)"
      done < <(printf '%s\n' "$parsed" | awk -F'\t' -v a="$lc" '
        $1 == "A" && $3 == a { g[$2] = 1 }
        $1 == "R" && ($2 in g) && $3 == "disallow" && $4 != "" { print $4 }')
    done

    # -- 3. the '*' group is exactly one group holding exactly one rule: Allow: /
    gs=$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "A" && $3 == "*" { print $2 }' | sort -u)
    n=$(printf '%s' "$gs" | grep -c .)
    if [ "$n" -ne 1 ]; then
      err "robots.txt: agent '*': expected exactly one group, found $n"
    else
      rules=$(printf '%s\n' "$parsed" | awk -F'\t' -v g="$gs" '$1 == "R" && $2 == g { print $3 ": " $4 }')
      if [ "$rules" != "allow: /" ]; then
        err "robots.txt: agent '*': group must hold exactly one rule 'Allow: /', found: $(printf '%s\n' "$rules" | sed 's/$/;/' | oneline)"
      fi
    fi

    # -- 5. exactly one Sitemap line, domain taken from CNAME
    if [ ! -f "$s/CNAME" ]; then
      err "CNAME: missing"
    else
      domain=$(tr -d '\r' < "$s/CNAME" | awk 'NF { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }')
      if [ -z "$domain" ]; then
        err "CNAME: empty"
      else
        want_sm="Sitemap: https://$domain/sitemap.xml"
        n_exact=$(grep -cxF -- "$want_sm" "$r")
        n_all=$(grep -ciE '^[[:space:]]*sitemap[[:space:]]*:' "$r")
        if [ "$n_exact" -ne 1 ] || [ "$n_all" -ne 1 ]; then
          err "robots.txt: Sitemap: expected exactly one line '$want_sm' and no other Sitemap line, found $n_exact exact of $n_all"
        fi
      fi
    fi
    [ -f "$s/sitemap.xml" ] || err "sitemap.xml: missing in site root"

    # -- 6. every Disallow path (any group) is real; '/' is never blocked
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        / | '/$') err "robots.txt: Disallow $p: must not block '/' (landing page)"; continue ;;
        /*) ;;
        *) err "robots.txt: Disallow $p: must start with /"; continue ;;
      esac
      case "$p" in
        *'*'* | *..*) err "robots.txt: Disallow $p: wildcards and '..' are not allowed"; continue ;;
      esac
      case "$p" in
        *'$') anchored=1; base=${p%\$} ;;
        *) anchored=0; base=$p ;;
      esac
      case "$base" in
        *'$'*) err "robots.txt: Disallow $p: '\$' is only allowed at the end"; continue ;;
      esac
      rel=${base#/}
      if [ "$anchored" -eq 1 ]; then
        case "$base" in
          */) f="$s/${rel}index.html" ;;
          *) f="$s/$rel" ;;
        esac
        if [ ! -f "$f" ] || [ -L "$f" ]; then err "robots.txt: Disallow $p: ${f#"$s"/} missing"; fi
      else
        case "$base" in
          */)
            dir="$s/$rel"
            if [ -d "$dir" ] && [ ! -L "$dir" ] && { [ -f "$dir/index.html" ] || [ -n "$(ls -A -- "$dir" 2>/dev/null)" ]; }; then
              :
            else
              err "robots.txt: Disallow $p: does not exist in the site (no directory with index.html or children)"
            fi
            ;;
          *)
            if [ -L "$s/$rel" ] || [ ! -e "$s/$rel" ]; then err "robots.txt: Disallow $p: does not exist in the site"; fi
            ;;
        esac
      fi
    done < <(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "R" && $3 == "disallow" && $4 != "" { print $4 }' | sort -u)
  fi

  # -- 8. cleanup: the stale copy of the landing page is gone
  if [ -e "$s/index copy.html" ] || [ -L "$s/index copy.html" ]; then
    err "index copy.html: must not exist in the site root"
  fi

  # -- 9. deploy workflow: allow-list copy, upload _site, guard (read as data, never run)
  wf="$s/.github/workflows/pages.yml"
  if [ -L "$wf" ] || [ ! -f "$wf" ]; then
    err ".github/workflows/pages.yml: missing"
  else
    body=$(grep -vE '^[[:space:]]*#' "$wf")
    printf '%s\n' "$body" | grep -q 'actions/upload-pages-artifact@' || err "pages.yml: no actions/upload-pages-artifact step"
    printf '%s\n' "$body" | grep -q 'actions/deploy-pages@' || err "pages.yml: no actions/deploy-pages step"
    # Allow-list deploy (US-4): only named entries are copied, the guard lists what must
    # never be staged. The exact allow-list is tested in test-deploy-allowlist.sh.
    joined=$(printf '%s\n' "$body" | sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta')
    if printf '%s\n' "$joined" | grep -E '^[[:space:]]*(cp|rsync)[[:space:]]' | grep -Eq -- '[[:space:]]\./?([[:space:]]|$)'; then
      err "pages.yml: copies the repo root ('.' or './') into the artifact (no rsync ./ or cp -R .)"
    fi
    guard=$(printf '%s\n' "$body" | awk '
      function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
      { isb = 0
        if (inb) { if ($0 ~ /^[ \t]*$/) isb = 1; else if (ind($0) > n) isb = 1; else inb = 0 }
        if (!inb && $0 ~ /^[ \t]*- name:.*[Gg]uard/) { inb = 1; n = ind($0); isb = 1 }
        if (isb) print }')
    if [ -z "$guard" ]; then
      err "pages.yml: guard step missing (no step whose name contains 'guard')"
    else
      for x in README.md CHANGELOG.md SECURITY.md scripts .github 'index copy.html' '*.md_tbd'; do
        printf '%s\n' "$guard" | grep -qF -- "$x" || err "pages.yml: guard does not name '$x'"
      done
      printf '%s\n' "$guard" | grep -Eq -- '(^|[[:space:]])exit[[:space:]]+1' || err "pages.yml: guard does not exit 1"
    fi
    upaths=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*path:[[:space:]]*//p' | sed "s/[[:space:]]*\$//; s/^['\"]//; s/['\"]\$//")
    if [ -z "$upaths" ]; then
      err "pages.yml: upload-pages-artifact must state the staged folder in 'path:'"
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        _site) ;;
        . | ./ | *github.workspace* | *scripts*)
          err "pages.yml: upload path '$p' would include the repo root or scripts/" ;;
        *) err "pages.yml: upload path must be _site, found '$p'" ;;
      esac
    done <<< "$upaths"
  fi

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

pass_case() { echo "PASS  $1"; passed=$((passed + 1)); }
fail_case() {
  echo "FAIL  $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'
  failed=$((failed + 1))
}

# run_pos <name> <dir>: the check must pass.
run_pos() {
  local out rc
  out=$(check_site "$2" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass_case "$1 (exit 0)"; else fail_case "$1 (exit $rc, expected 0)" "$out"; fi
}

# run_neg <name> <expected text> <dir>: exit 1, text present, and text absent from baseline.
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

# run_self <name> <expected exit> <expected text> [args]: runs this script for usage errors.
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

# awk_edit <file> <awk args...>: rewrite the file; fails if the file is missing or unchanged,
# so a negative test never runs on a copy where the injection did not happen.
awk_edit() {
  local f=$1 t
  shift
  [ -f "$f" ] || return 1
  t="$f.us3-tmp"
  if ! awk "$@" "$f" > "$t"; then rm -f -- "$t"; return 1; fi
  if cmp -s -- "$f" "$t"; then rm -f -- "$t"; return 1; fi
  mv -- "$t" "$f"
}
setup_fail() { fail_case "$1 (setup: injection target not found - $2)"; }

# Helpers for robots.txt injections (case-insensitive User-agent match, CR tolerant).
AWK_UA='function ua(l,  v) { v = l; sub(/\r$/, "", v); if (tolower(v) !~ /^user-agent[ \t]*:/) return "";
  sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v); return tolower(v) }'

# T1 real site must pass
run_pos "T1 real site passes" "$site"

# T2 unchanged copy must pass (validates the copy procedure); its output is the baseline
d=$(make_copy) || exit 2
baseline_out=$(check_site "$d" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass_case "T2 unchanged copy passes (exit 0)"; else fail_case "T2 unchanged copy passes (exit $rc, expected 0)" "$baseline_out"; fi

# T3 robots.txt removed
d=$(make_copy) || exit 2
rm -f -- "$d/robots.txt"
run_neg "T3 missing robots.txt fails" "robots.txt: missing" "$d"

# T4 robots.txt is a symlink
d=$(make_copy) || exit 2
if [ -f "$d/robots.txt" ]; then
  mv -- "$d/robots.txt" "$d/robots-real.txt" && ln -s robots-real.txt "$d/robots.txt"
  run_neg "T4 symlinked robots.txt fails" "robots.txt: is a symlink" "$d"
else setup_fail "T4 symlinked robots.txt fails" "robots.txt"; fi

# T5 one path removed from one blocked group (GPTBot loses /de/tags/)
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" "$AWK_UA"'
    { l = $0; sub(/\r$/, "", l); a = ua(l); if (a != "") ing = (a == "gptbot") }
    ing && tolower(l) ~ /^disallow[ \t]*:[ \t]*\/de\/tags\/[ \t]*$/ { next }
    { print }'; then
  run_neg "T5 path missing in GPTBot group fails" "agent 'GPTBot': missing Disallow /de/tags/" "$d"
else setup_fail "T5 path missing in GPTBot group fails" "no 'Disallow: /de/tags/' in a GPTBot group"; fi

# T6 Googlebot added to a blocked group
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" "$AWK_UA"'
    { print; if (ua($0) == "gptbot") print "User-agent: Googlebot" }'; then
  run_neg "T6 Googlebot in a blocked group fails" "agent 'Googlebot': must not be disallowed" "$d"
else setup_fail "T6 Googlebot in a blocked group fails" "no 'User-agent: GPTBot' line"; fi

# T7 'Disallow: /posts/' added under '*'
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" "$AWK_UA"'
    { print; if (ua($0) == "*") print "Disallow: /posts/" }'; then
  run_neg "T7 Disallow under '*' fails" "agent '*': must not be disallowed (Disallow: /posts/)" "$d"
else setup_fail "T7 Disallow under '*' fails" "no 'User-agent: *' line"; fi

# T8 second group for a blocked agent
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ print } END { print ""; print "User-agent: ClaudeBot"; print "Disallow: /posts/" }'; then
  run_neg "T8 duplicate ClaudeBot group fails" "agent 'ClaudeBot': expected exactly one group, found 2" "$d"
else setup_fail "T8 duplicate ClaudeBot group fails" "robots.txt"; fi

# T9 AI search bot disallowed
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ print } END { print ""; print "User-agent: OAI-SearchBot"; print "Disallow: /de/posts/" }'; then
  run_neg "T9 OAI-SearchBot disallowed fails" "agent 'OAI-SearchBot': must not be disallowed" "$d"
else setup_fail "T9 OAI-SearchBot disallowed fails" "robots.txt"; fi

# T10 Allow line slipped into a blocked group (would reopen paths)
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" "$AWK_UA"'
    { print; if (ua($0) == "gptbot") print "Allow: /de/posts/" }'; then
  run_neg "T10 Allow in GPTBot group fails" "agent 'GPTBot': unexpected Allow" "$d"
else setup_fail "T10 Allow in GPTBot group fails" "no 'User-agent: GPTBot' line"; fi

# T11 Sitemap line duplicated
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ print } END { print "Sitemap: https://jonaskufner.com/sitemap.xml" }'; then
  run_neg "T11 duplicate Sitemap line fails" "robots.txt: Sitemap: expected exactly one line" "$d"
else setup_fail "T11 duplicate Sitemap line fails" "robots.txt"; fi

# T12 CNAME names another domain, Sitemap line no longer matches it
d=$(make_copy) || exit 2
printf 'example.org\n' > "$d/CNAME"
run_neg "T12 Sitemap domain differs from CNAME fails" "expected exactly one line 'Sitemap: https://example.org/sitemap.xml'" "$d"

# T13 invented path /nope/ (own group so only the path check can fire)
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ print } END { print ""; print "User-agent: ExampleBot"; print "Disallow: /nope/" }'; then
  run_neg "T13 invented path /nope/ fails" "Disallow /nope/: does not exist in the site" "$d"
else setup_fail "T13 invented path /nope/ fails" "robots.txt"; fi

# T14 /de/$ must map to de/index.html
d=$(make_copy) || exit 2
rm -f -- "$d/de/index.html"
run_neg "T14 /de/\$ without de/index.html fails" 'Disallow /de/$: de/index.html missing' "$d"

# T15 root blocked
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ print } END { print ""; print "User-agent: ExampleBot"; print "Disallow: /" }'; then
  run_neg "T15 Disallow: / fails" "must not block '/'" "$d"
else setup_fail "T15 Disallow: / fails" "robots.txt"; fi

# T16 CRLF line endings
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ sub(/\r$/, ""); printf "%s\r\n", $0 }'; then
  run_neg "T16 CRLF fails" "robots.txt: contains CR characters" "$d"
else setup_fail "T16 CRLF fails" "robots.txt"; fi

# T17 Disallow before any User-agent line
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" 'NR == 1 { print "Disallow: /tags/" } { print }'; then
  run_neg "T17 Disallow outside a group fails" "disallow outside a group" "$d"
else setup_fail "T17 Disallow outside a group fails" "robots.txt"; fi

# T18 stale 'index copy.html' present
d=$(make_copy) || exit 2
: > "$d/index copy.html"
run_neg "T18 index copy.html present fails" "index copy.html: must not exist" "$d"

# T19 deploy workflow missing
d=$(make_copy) || exit 2
rm -f -- "$d/.github/workflows/pages.yml"
run_neg "T19 missing pages.yml fails" ".github/workflows/pages.yml: missing" "$d"

# T20 guard no longer names scripts
d=$(make_copy) || exit 2
if awk_edit "$d/.github/workflows/pages.yml" '!/scripts/'; then
  run_neg "T20 pages.yml guard without scripts fails" "pages.yml: guard does not name 'scripts'" "$d"
else setup_fail "T20 pages.yml guard without scripts fails" "no line with 'scripts' in pages.yml"; fi

# T21 workflow uploads the repo root
d=$(make_copy) || exit 2
if awk_edit "$d/.github/workflows/pages.yml" '{ if ($0 ~ /^[ \t]*path:/) sub(/path:.*/, "path: ."); print }'; then
  run_neg "T21 pages.yml uploading the repo root fails" "pages.yml: upload path '.' would include" "$d"
else setup_fail "T21 pages.yml uploading the repo root fails" "no 'path:' line in pages.yml"; fi

# T24 workflow copies the repo root (rsync ./) in addition to the allow-list
d=$(make_copy) || exit 2
if awk_edit "$d/.github/workflows/pages.yml" '!done && /^[ \t]*(cp|rsync)[ \t]/ { match($0, /^[ \t]*/); printf "%srsync -a ./ _site/\n", substr($0, 1, RLENGTH); done = 1 } { print }'; then
  run_neg "T24 pages.yml with rsync ./ fails" "pages.yml: copies the repo root" "$d"
else setup_fail "T24 pages.yml with rsync ./ fails" "no cp/rsync line in pages.yml"; fi

# T25 guard no longer names 'index copy.html'
d=$(make_copy) || exit 2
if awk_edit "$d/.github/workflows/pages.yml" '!/index copy\.html/'; then
  run_neg "T25 pages.yml guard without index copy.html fails" "pages.yml: guard does not name 'index copy.html'" "$d"
else setup_fail "T25 pages.yml guard without index copy.html fails" "no line with 'index copy.html' in pages.yml"; fi

# T26 /en/$ must map to en/index.html
d=$(make_copy) || exit 2
rm -f -- "$d/en/index.html"
run_neg "T26 /en/\$ without en/index.html fails" 'Disallow /en/$: en/index.html missing' "$d"

# T27 PerplexityBot gets a group (even with an empty Disallow)
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" '{ print } END { print ""; print "User-agent: PerplexityBot"; print "Disallow:" }'; then
  run_neg "T27 PerplexityBot group fails" "agent 'PerplexityBot': must not have a group of its own" "$d"
else setup_fail "T27 PerplexityBot group fails" "robots.txt"; fi

# T28 'Disallow: /' added under '*'
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" "$AWK_UA"'
    { print; if (ua($0) == "*") print "Disallow: /" }'; then
  run_neg "T28 Disallow: / under '*' fails" "agent '*': must not be disallowed (Disallow: /)" "$d"
else setup_fail "T28 Disallow: / under '*' fails" "no 'User-agent: *' line"; fi

# T29 FacebookBot group missing (blocked agent without a group)
d=$(make_copy) || exit 2
if awk_edit "$d/robots.txt" "$AWK_UA"'
    { l = $0; sub(/\r$/, "", l); a = ua(l); if (a != "") skip = (a == "facebookbot"); if (!skip && l !~ /^Sitemap/) print; else if (l ~ /^Sitemap/) { skip = 0; print } }'; then
  run_neg "T29 FacebookBot group missing fails" "agent 'FacebookBot': expected exactly one group, found 0" "$d"
else setup_fail "T29 FacebookBot group missing fails" "no 'User-agent: FacebookBot' line"; fi

# T22/T23 usage errors
run_self "T22 no argument gives exit 2" 2 "usage"
run_self "T23 non-existent path gives exit 2" 2 "not a directory" "$work/does-not-exist"

echo "SUMMARY: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
