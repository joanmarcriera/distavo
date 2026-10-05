# Import from URL (Vikunja #2955)

**Direct edition only.** Menu bar -> **Import from URL...**

> Downloads the file from the address you paste; nothing is uploaded.

This is the one place Distavo fetches from the internet, and only for an address you typed and a button you
pressed. Paste an `https` address of an audio/video file, or of a podcast RSS/Atom feed (you then pick one of the
newest 15 episodes). The file is downloaded into a private temp folder, handed to the normal queue (which copies it
into your recordings folder under a sanitised name) and the temp folder is removed.

## Safety rules (`ImportURL.swift`, tested)

**Destination (SSRF).** An import is a request to a stranger's server, never to this Mac or your network.
- One validator is applied to the pasted URL, every feed enclosure URL and every redirect `Location`: `https` only,
  no user name/password, and the host must be a normal DNS name. IP literals in any notation (dotted, decimal, hex,
  octal, IPv6), `localhost`, single-label names and `.local` / `.localhost` / `.internal` / `.lan` / `.home.arpa`
  names are refused.
- One destination check at every hop (start and each redirect): the name is resolved once and **every** returned
  address must be public. Loopback, private, link-local (incl. cloud metadata), CGNAT, ULA, multicast, unspecified,
  reserved/documentation, NAT64, 6to4, Teredo and IPv4-mapped/compatible forms of those are refused. A name with one
  public and one private address is refused. Unresolvable fails closed.
- There is **no** "allow a server on my network" option and no plain http. Local files: use Finder or the Transcribe File shortcut.
- **Residual risk.** The connection is made by URLSession, which resolves the name again, so a DNS answer that changes
  between our check and the connection is not pinned. https keeps the host name, so TLS must present a certificate valid
  for it, which a local plain-http service (Ollama, the MCP server, a router page) cannot. The system proxy, if you have
  one, is honoured: an import is ordinary internet traffic.

**Content.**
- Size cap **2 GB**, enforced on the decoded bytes actually received (not Content-Length); `Accept-Encoding: identity`
  is sent, and anything a server compresses anyway is capped after decoding, so a compression bomb hits the same limit.
- The type is decided from the **magic bytes** (WAV, MP3/AAC, MP4/M4A/MOV/3GP, Ogg, FLAC, WebM/MKV), not from the URL
  extension or Content-Type, which are only an early filter. An `.exe` or HTML page named `.mp3` is refused.
- At most 5 redirects. Ephemeral session: no cookies, cache or stored credentials; password challenges are cancelled.
  30 s idle / 2 h overall timeout, Cancel button.
- The temp file is created with `O_EXCL | O_NOFOLLOW` inside a fresh 0700 folder, deleted on every failure path.
  The name comes from the URL path through the shared sanitiser, never from `Content-Disposition`.
- Feeds: 5 MB cap, 200 items, depth 64; **any DOCTYPE / ENTITY declaration is refused** (no XXE, no entity
  expansion), NUL bytes refused (no UTF-16 tricks), external entities off. Titles are neutralised for display.

## Not built: YouTube / yt-dlp

Removed on purpose. It would launch a third-party process on a pasted URL whose output and behaviour we do not control,
and it needs its own argument-injection, timeout and output-validation work to be safe. Paste a direct media URL or a feed.

## Not verified without launching

A real download over TLS, a real feed, cancel mid-download, and that URLSession really presents the redirect chain to the
delegate as designed. See `docs/manual-checks-2955.md`.
