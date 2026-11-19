# Security

## robots.txt limits
- There is one root `robots.txt`, because crawlers ignore per-post files.
- `robots.txt` is voluntary. Compliant crawlers obey it. Hostile or non-compliant crawlers can
  ignore it, so it gives no protection against them. It is not an access control.
- No CDN or WAF is planned. This is the developer's decision, so there is no technical
  enforcement of the block. Non-compliant scrapers can still read the posts.
- `ChatGPT-User`, `Perplexity-User` and `Meta-ExternalFetcher` are triggered by a user and may
  ignore `robots.txt` (the vendors say so). `Claude-User` may too, as its page does not state it.
  Blocking them is best effort.
- Bytespider's behaviour (reports say it often ignores `robots.txt`) is not confirmed from
  primary sources.
- The tokens `Diffbot`, `ImagesiftBot`, `Omgilibot`, `cohere-ai` and `FacebookBot` come from
  common blocklists, not from vendor pages. `anthropic-ai` is not on Anthropic's current page.
- Bing's support for the `$` end anchor (used in `/de/$` and `/en/$`) is not confirmed from
  primary sources. Bing is not blocked, so this does not affect it. Only the blocked agents use `$`.
- A crawler that does not understand `$` reads `/de/$` as a literal path and does not block the
  listing page.
- Crawlers may cache `robots.txt` for about 24 hours. Changes do not apply at once.
- `robots.txt` lists the blocked paths publicly. They are public paths and reveal no secret path.

## Search bots
- Googlebot, Bingbot and all other search spiders stay allowed. OAI-SearchBot, Claude-SearchBot
  and PerplexityBot stay allowed because they send readers to the site. `facebookexternalhit`
  (link previews) stays allowed.
- The sitemaps list URLs that the blocked agents may not fetch. This is intended, because the
  blocked agents do not use the sitemap.

## Deployment
- Branch `main` is confirmed. There is no build command. The publish directory is `_site/`.
- `pages.yml` copies only an allow-list into `_site/` and uploads that folder. Anything not on
  the list is not published. The job fails if `_site/` holds a doc, tooling, `index copy.html`
  or an `*.md_tbd` file. The list is in "Publish setup" in `README.md`.
- Docs and tooling are not deployed: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `scripts/`,
  `.github/`, `.git/`, `index copy.html` and `*.md_tbd` stay out of the artifact.
- The whole repo root is public only until the Pages source is switched to "GitHub Actions".
  Until then GitHub serves every file on `main`, including the docs and tooling above. They hold
  no secrets.
- `.github/workflows/pages.yml` uses least-privilege permissions per job. The build job has only
  `contents: read`. Only the deploy job has `pages: write` and `id-token: write`. No secrets are
  used, and checkout uses `persist-credentials: false`.
- The action SHAs are not yet verified (see "Hand-over" in `README.md`).

## Secrets
- No password, token or key is used in this project.
