# Permissions helper + LAN-permission diagnosis

Date: 2026-07-07
Status: approved

## Problem

When a WhisperX/Ollama endpoint is reachable from Terminal but fails Distavo's
**Test Connections**, the cause is almost always that the macOS **Local Network**
privacy grant for the app is missing or has gone *stale* (it silently resets when
the app binary is replaced — e.g. a Sparkle auto-update — even though the toggle
still reads ON). Cycling it **off→on** and relaunching fixes it.

Two gaps make this hard to self-diagnose:

1. `NetworkScope.isLocalNetworkHost` classifies by **hostname string**, so a public
   FQDN that resolves to a LAN IP (`ollama.lab.riera.co.uk` → `192.168.0.5`) is
   judged *public*. The app then neither warns about Local Network nor shows the
   correct error — it says "check the URL is correct" instead.
2. There is no in-app place that tells the user which OS permissions Distavo needs
   or walks them to the right System Settings pane.

## Part A — `NetworkScope` fix (DistavoCore)

- `isPrivateAddress(_ ip:) -> Bool` — **pure, fully unit-tested.** True for RFC-1918
  IPv4 (`10/8`, `172.16/12`, `192.168/16`), link-local (`169.254/16`, `fe80::/10`),
  IPv6 ULA (`fc00::/7`). **Loopback (`127/8`, `::1`) is NOT local-network** (loopback
  needs no Local Network permission).
- `isLocalNetworkHost(_ urlString:)` — **unchanged** pure string heuristic (keeps
  existing tests hermetic and fast).
- `HostResolver = (String) -> [String]`; `systemResolver` wraps `getaddrinfo`
  (returns numeric IPv4/IPv6 strings; `[]` on failure).
- `isLocalOrResolvesLocal(_ urlString:, resolver: = systemResolver) -> Bool` =
  string-local **or** any resolved address `isPrivateAddress`. Short-circuits on the
  string check so literal LAN IPs never hit DNS.
- `usesLocalNetwork` and `friendlyError` gain a defaulted `resolver:` param and use
  the resolve-aware check. The **resolver is injected in tests** (fake maps
  `*.lab.riera.co.uk → ["192.168.0.5"]`, `api.example.com → ["93.184.216.34"]`) so
  no test touches the network.

Tests: exhaustive `isPrivateAddress` table (private/loopback/link-local/public/IPv6),
FQDN-resolves-to-LAN via fake resolver, existing string + public-host cases retained.

## Part B — Permissions helper (app target)

`Settings/PermissionsView.swift` — a sheet listing the permissions Distavo actually
uses. Each row: name, one-line why, status glyph, action button.

| Permission | Detectable | Action |
| --- | --- | --- |
| **Local Network** | No (macOS hides it) | Open `?Privacy_LocalNetwork`; body explains the after-update **off→on + relaunch** fix and the multiple-*Distavo*-entries case |
| **Microphone** | Yes — `AVCaptureDevice.authorizationStatus(.audio)` | request if `.notDetermined`, else open `?Privacy_Microphone` |
| **System Audio Recording** (meeting capture) | No | Open `?Privacy_AudioCapture` |

Mic + Audio rows are gated to where the capture code is compiled; Local Network
always shows. Deep-link anchors follow the existing `com.apple.preference.security?…`
pattern already used in `MeetingCaptureController`.

Entry points:
- **Button** `Check permissions…` in Settings → Connections (always).
- **Auto-prompt:** after Test Connections, if any tested endpoint is unreachable AND
  `isLocalOrResolvesLocal` is true for it, show an inline warning naming the host
  plus a `Fix permissions…` button opening the same sheet.

Out of scope (YAGNI): Automation (Terminal helper) and Login Item rows.

## Verification

- `cd apple/DistavoCore && swift test` (Part A).
- `cd apple && xcodegen generate` + unsigned Direct build (app-target breakage).
- TCC/capture flows can't run in CI → manual checklist entry.
