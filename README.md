# jonaskufner.com

Static website made of plain files (HTML, feeds and sitemaps). Hugo is no longer used, so the
built output is edited by hand. Domain: `jonaskufner.com` (see `CNAME`).

## What robots.txt does
There is one `robots.txt` at the site root. Crawlers read it only at the host root and ignore
per-post files, so one root file covers all posts. It blocks 18 AI training crawlers and
content-copying agents from the blog posts and the pages that repeat them. US-3 is still
in progress.

- **Blocked agents (one group each, 18):** GPTBot, ClaudeBot, anthropic-ai, Google-Extended,
  CCBot, Bytespider, Applebot-Extended, Meta-ExternalAgent, Amazonbot, ChatGPT-User, Claude-User,
  Perplexity-User, Meta-ExternalFetcher, Diffbot, ImagesiftBot, Omgilibot, cohere-ai,
  FacebookBot.
  - The tokens of the last five (Diffbot, ImagesiftBot, Omgilibot, cohere-ai, FacebookBot) come
    from common blocklists, not from vendor pages.
- **Allowed:** all search engines. The `*` group has only `Allow: /`, so Googlebot, Bingbot and
  all other search spiders keep full access. OAI-SearchBot, Claude-SearchBot and PerplexityBot
  (moved from blocked to allowed) are not named and stay allowed. `facebookexternalhit` (link
  previews) also stays allowed.
- **Covered paths (21 Disallow lines per group):** `/posts/`, `/de/posts/` and `/en/posts/`, plus
  the listing, pagination, tag, category, search, `index.xml` and `index.json` paths under `/`,
  `/de/` and `/en/`: `categories/`, `tags/`, `search/`, `page/`, `index.xml`, `index.json`.
  `/de/$` and `/en/$` block only the blog home pages. The landing page `/` is not blocked.
- **Limits:** it is voluntary. There is no CDN or WAF, so non-compliant scrapers can still read
  the posts. The user-triggered fetchers (ChatGPT-User, Perplexity-User, Meta-ExternalFetcher
  and possibly Claude-User) can read them too. Their groups are only a request. See `SECURITY.md`.

### Add an agent
1. Copy a whole group in `robots.txt`, with its `User-agent:` line and all 21 Disallow lines.
   The Disallow list must be identical in every blocked group.
2. Change the agent name. Keep exactly one group per agent.
3. Add the name to `BLOCKED_AGENTS` in `scripts/test-robots.sh`. The Disallow paths are in
   `EXPECTED_PATHS` in the same file. Change that list too if you add or remove a path.
4. Run both test suites.

## Tests
Run from the project folder:

```
bash scripts/test-robots.sh .
bash scripts/test-check-phone.sh .
bash scripts/test-deploy-allowlist.sh .
```

Exit codes: 0 pass, 1 fail, 2 usage error.

## Publish setup (GitHub Pages)
- **Branch:** `main` (confirmed).
- **Build command:** none (plain files, no build step).
- **Publish directory:** `_site/`, created by the allow-list copy step in `pages.yml`.
- **Deployment:** `pages.yml` copies only the allow-listed paths into `_site/` and uploads that
  folder. Anything not on the list is not published. The job fails if `_site/` holds a doc,
  tooling, `index copy.html` or an `*.md_tbd` file.
  - **Files:** `index.html`, `404.html`, `CNAME`, `.nojekyll`, `robots.txt`, `sitemap.xml`,
    `landing-sitemap.xml`, `index.xml`, `index.json`.
  - **Folders:** `about/`, `assets/`, `categories/`, `contact/`, `css/`, `datenschutz/`, `de/`,
    `en/`, `impressum/`, `js/`, `landing/`, `posts/`, `tags/`, `ueber-mich/`, with `*.md_tbd`
    excluded.
  - **Never published:** `README.md`, `CHANGELOG.md`, `SECURITY.md`, `scripts/`, `.github/`,
    `.git/`, `index copy.html`, `*.md_tbd`.
- The artifact contains `robots.txt` at its root.
- The Pages source in the repo settings must be "GitHub Actions".

## Hand-over
Status: US-3 and US-4 stay in progress until the shell checks pass and `index.html` passes its
automatic re-review at the end of the run. US-2 stays planned and out of scope. No agent had a
shell, so nothing was run and no pass is claimed.

### Open developer actions (in this order)
1. Merge the PR with `pages.yml`.
2. Switch Settings > Pages > Source to "GitHub Actions". Until then the whole repo root is
   served from `main`: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `scripts/`, `.github/`,
   `index copy.html`, `*.md_tbd`. Do this right after the merge.
3. Delete `index copy.html` from the repo.

### Shell checks and expected results
Each SHA pinned in `pages.yml` must match the commit of its tag. For annotated tags, use the
`^{}` value.

| Check | Expected result |
|---|---|
| `git ls-remote --tags https://github.com/actions/checkout v4.2.2` | `11bd71901bbe5b1630ceea73d27597364c9af683` |
| `git ls-remote --tags https://github.com/actions/upload-pages-artifact v3.0.1` | `56afc609e74202658d3ffba0e8f6dda462b719fa` |
| `git ls-remote --tags https://github.com/actions/deploy-pages v4.0.5` | `d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e` |
| `bash scripts/test-deploy-allowlist.sh .` | 11 passed, exit 0. |
| `bash scripts/test-check-phone.sh .` | 17 passed, exit 0. As root, T17 and T19 print SKIP and 15 pass, still exit 0. |
| `bash scripts/test-robots.sh .` | 29 cases. While `index copy.html` exists: 26 passed, 3 failed (T1, T2, T18), exit 1. After deletion: 29 passed, exit 0. |
| `bash scripts/check-phone.sh .` | Exit 0. |

### After deploy
| Check | Expected result |
|---|---|
| `curl -sI https://jonaskufner.com/README.md` | 404 |
| `curl -sI https://jonaskufner.com/scripts/check-phone.sh` | 404 |
| `curl -sI "https://jonaskufner.com/index%20copy.html"` | 404 |
| `curl -sI https://jonaskufner.com/robots.txt` | 200 and `text/plain` |
| A file under `https://jonaskufner.com/landing/assets/` | 200 |

### Optional hardening (not done)
- A test that asserts the permission split in `pages.yml`.

### Known limits
- `robots.txt` is voluntary (see above and `SECURITY.md`).
- The three action SHAs are unverified.
- US-2 stays planned and out of scope.
- The project configuration (API for the database, API documentation, integration with the
  customer's other projects) is a later item. This story does not touch it.
