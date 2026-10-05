# Import from URL (Vikunja #2955)

**Direct edition only.** Menu bar -> **Import from URL...**

> Downloads the file from the address you paste; nothing is uploaded.

This is the one place Distavo fetches from the internet, and only for an address you typed and a button you
pressed. Paste an `https` address of an audio/video file, or of a podcast RSS/Atom feed (you then pick one of the
newest 15 episodes). The file is downloaded into a private temp folder, handed to the normal queue (which copies it
into your recordings folder under a sanitised name) and the temp folder is removed.

## Safety rules (all in `ImportURL.swift`, tested)

- `https` only. `http` is accepted only for loopback / LAN **literals** (`localhost`, `*.local`, `127.x`, `10.x`,
  `172.16-31.x`, `192.168.x`, `169.254.x`, `::1`, `fc00::/7`, `fe80::/10`) and is flagged in the window.
  A name that merely resolves to a LAN address is not trusted. No user name / password in the address.
- Size cap **2 GB**, enforced on the bytes actually received (not on the Content-Length header).
- Only `audio/*`, `video/*` or generic binary with a supported extension, or an RSS/Atom content type.
- At most **5 redirects**; https -> http is refused; a public address redirecting into loopback/LAN is refused.
- Ephemeral session: no cookies, no cache, no stored credentials. 30 s idle / 2 h overall timeout, Cancel button.
- The file name comes from the URL path through the shared sanitiser, never from `Content-Disposition`.
- Feeds: 5 MB cap, 200 items, depth 64; **any DOCTYPE / ENTITY declaration is refused** (no XXE, no entity
  expansion), NUL bytes refused (no UTF-16 tricks), external entities off. Titles are neutralised for display.

## Not built: YouTube / yt-dlp

Leaving out the optional yt-dlp path (run an installed third-party tool on a pasted URL) was a deliberate scope
decision: it launches a process on a user-supplied URL and its output format is outside our control, so it was not
solid enough to ship in this branch. Pasting a direct media URL or a feed works.

## Not verified without launching

A real download over TLS, a real feed, plain-http LAN downloads (App Transport Security may block them: the
Info.plist was deliberately not changed), cancel mid-download. See `docs/manual-checks-2955.md`.
