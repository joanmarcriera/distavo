# Decisions

## 2026-06-29 - Keep the website static and self-contained

Decision: Host the public Distavo website as plain static files under
`ops/site`.

Alternatives considered: Introduce a framework such as Next.js or Astro, or
split the website into a separate repository.

Rationale: The current site needs product, privacy, support, and feedback pages
with no dynamic runtime. Static files match the existing nginx hosting surface
and minimize deployment risk.

Consequences: Changes are simple to review and deploy, but there is no content
CMS or app-side integration.

Revisit when: The site needs dynamic downloads, account-specific content,
localized pages, or a larger documentation system.

## 2026-06-29 - Use a Setapp-only Info.plist

Decision: Add `apple/Setapp-Info.plist` and point `Setapp.xcconfig` at it
instead of adding Setapp metadata to the generated shared plist.

Alternatives considered: Add `NSUpdateSecurityPolicy` to all editions, or try
to encode the nested dictionary through `INFOPLIST_KEY_*` build settings.

Rationale: `NSUpdateSecurityPolicy` is Setapp-specific and nested. A dedicated
plist keeps Direct and App Store metadata clean and is easier to inspect.

Consequences: Shared Info.plist keys must be kept in sync if the app adds new
required usage descriptions later.

Revisit when: XcodeGen gains a cleaner per-xcconfig plist merge path or the
Setapp target is split into a dedicated target/scheme.

## 2026-06-29 - Delay Setapp Framework linking until dashboard assets exist

Decision: Do not link `libSetapp.a` or add framework calls until the vendor
dashboard public key and SDK are available.

Alternatives considered: Stub the framework integration or add placeholder
paths to the project.

Rationale: Placeholder framework paths would break local and CI builds. The
current safe progress is metadata, packaging, and documentation.

Consequences: The Setapp build is closer to submission, but final framework
activation remains blocked on Marc's vendor account assets.

Revisit when: The Setapp SDK archive and app public key file are in the repo or
available in a local, documented path.
