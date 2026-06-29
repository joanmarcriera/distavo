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
