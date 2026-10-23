# Distavo website

Static source for `https://distavo.com`.

The live service is the `distavo` nginx container in the Hetzner `sites`
compose project at `/opt/stacks/core/sites.yml`, serving
`/opt/stacks/core/distavo`.

Routes:

- `/` is `ops/site/index.html`.
- `/privacy/` is `ops/site/privacy/index.html`.
- `/support/` is `ops/site/support/index.html`.
- `/feedback/` is copied from `ops/helper-program/feedback.html` because it is
  coupled to the n8n helper-credit workflow documented in
  `ops/helper-program/n8n-and-espocrm.md`.

## Publishing

A push to `main` does **not** deploy this site. Only `appcast.xml` is published automatically
(`ops/publish-appcast.sh`). Changing the pages means copying `ops/site/` to `/opt/stacks/core/distavo`
on the Hetzner host by hand, which is a gated, human step (Codex release review, task 4071).
