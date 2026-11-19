# Changelog

## 2026-11-18 - Security review: size rejections waived (draft)

### Changed
- The security review rejections of `index.html` and `index copy.html` with the reason "File is too
  large for one review; split it into smaller components" were waived by the developer. They were a
  review-tool limit, not a security finding.
- The registry listed each file twice. These were duplicate registry entries, not separate reviews.
- Both files stay draft and are pending the automatic security re-review at the end of the run.
  Neither file is marked approved.
- No file content was changed and no file was split.
- `index copy.html` is excluded from deployment by the allow-list in `.github/workflows/pages.yml`:
  the staging step on lines 52-53 and the guard step on line 60. The developer will delete it after
  the pages.yml pull request is merged.

## 2026-11-18 - US-4: Resolve open security findings (in progress)

### Changed
- `.github/workflows/pages.yml`: the deploy copies only an allow-list into `_site/` and uploads
  `path: _site`. Files: `index.html`, `404.html`, `CNAME`, `.nojekyll`, `robots.txt`,
  `sitemap.xml`, `landing-sitemap.xml`, `index.xml`, `index.json`. Folders: `about/`, `assets/`,
  `categories/`, `contact/`, `css/`, `datenschutz/`, `de/`, `en/`, `impressum/`, `js/`,
  `landing/`, `posts/`, `tags/`, `ueber-mich/`, with `*.md_tbd` excluded.
- `.github/workflows/pages.yml`: the guard also requires `landing-sitemap.xml` in `_site/`.
- `scripts/check-phone.sh`: a `find` error during the file scan now exits 2 ("error: find
  failed") instead of being ignored.
- `README.md`, `CHANGELOG.md`, `SECURITY.md`, `scripts/`, `.github/`, `.git/`,
  `index copy.html` and `*.md_tbd` are never published. The job fails if `_site/` holds any of them.
- `README.md` and `SECURITY.md`: publish setup, hand-over and deployment notes describe the
  allow-list and `_site/`.
- `pages.yml`: least-privilege permissions. Top level is `contents: read` only; only the deploy
  job has `pages: write` and `id-token: write`.

### Added
- `scripts/test-deploy-allowlist.sh`: tests that the deploy publishes only the allow-list.

### Not done
- Not verified by an agent; see Hand-over in `README.md`.

## 2026-11-18 - US-3: Forbid autonomous agents from crawling blog posts (in progress)

### Added
- One root `robots.txt` (crawlers ignore per-post files). It blocks 18 AI training crawlers and
  content-copying agents: GPTBot, ClaudeBot, anthropic-ai, Google-Extended, CCBot, Bytespider,
  Applebot-Extended, Meta-ExternalAgent, Amazonbot, ChatGPT-User, Claude-User, Perplexity-User,
  Meta-ExternalFetcher, Diffbot, ImagesiftBot, Omgilibot, cohere-ai, FacebookBot.
  The tokens of the last five come from common blocklists, not from vendor pages.
- Each agent has its own group with the same 21 Disallow paths: `/posts/`, `/de/posts/`,
  `/en/posts/`, plus listings, pages, tags, categories, search, `index.xml` and `index.json`
  under `/`, `/de/` and `/en/`.
- Googlebot, Bingbot and all other search spiders stay allowed through the `*` group, which holds
  only `Allow: /`. OAI-SearchBot, Claude-SearchBot, PerplexityBot and `facebookexternalhit` stay
  allowed (no group names them).
- `scripts/test-robots.sh`: test cases for the `robots.txt` rules and the deploy workflow. The
  deploy allow-list is tested by `scripts/test-deploy-allowlist.sh` (US-4).
- `.github/workflows/pages.yml`: deploys the site through GitHub Actions from branch `main`
  (confirmed). There is no build command. The workflow copies only an allow-list into `_site/`
  and uploads that folder (see US-4).

### Changed
- `robots.txt`: PerplexityBot moved from blocked to allowed (Perplexity documents it as a search
  bot). The old claim of 14 blocked agents is replaced by 18.
- `robots.txt`: the old empty `Disallow:` under `*` is replaced by `Allow: /`.
- `scripts/check-phone.sh` and `scripts/test-check-phone.sh` (US-1): the references to
  `index copy.html` are removed (file list entry, test T4 and test T12). No other US-1 change.

### Removed
- `index copy.html` is to be deleted by hand (see "Hand-over" in `README.md`).

### Known limits
- `robots.txt` is voluntary. There is no CDN or WAF, so non-compliant scrapers and the
  user-triggered fetchers (ChatGPT-User, Perplexity-User, Meta-ExternalFetcher, possibly
  Claude-User) can still read the posts.
- US-2 stays planned and out of scope.

### Not done
- Not verified by an agent; see Hand-over in `README.md`.
