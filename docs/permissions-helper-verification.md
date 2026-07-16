# Permissions helper + Local Network diagnosis — manual verification

The macOS **Local Network** privacy gate and the microphone / system-audio TCC
prompts can't be exercised in CI (they need a signed build and a human to click
the prompts), so this is the manual checklist — mirroring
`docs/meeting-capture-verification.md` and `docs/update-verification.md`.

Background: a public host name that resolves to a LAN address (e.g.
`ollama.lab.example.com → 192.168.0.5`) still needs Local Network permission.
`NetworkScope.isLocalOrResolvesLocal` now catches that via DNS resolution; the
DistavoCore unit tests (`NetworkScopeTests`) cover the classification with an
injected resolver, so only the UI + OS wiring needs a human here.

## Test Connections guidance (the auto-prompt)

1. Configure the Server Ollama URL to a LAN host that is **up** but for which
   Distavo has **no** Local Network permission (or toggle Distavo off in
   System Settings → Privacy & Security → Local Network first).
2. Settings → **Test connection**. Expect: the Server Ollama dot goes red **and**
   an inline orange warning appears naming the host, with a **Fix permissions…**
   button. Confirm it also fires when the URL is a *public FQDN that resolves to a
   LAN IP*, not just a literal `192.168.x` address.
3. Grant Local Network permission, relaunch, Test again → dot green, warning gone.

## Fresh-install presentation (the App Review 2.1(a) case, 1.8.1)

Apple rejected 1.8.0(9) testing on a Mac with no Ollama: both dots red with no
explanation, and Distavo absent from the Local Network pane the helper pointed
at. Verify the fix on a machine (or fresh user account) **without Ollama**,
config at defaults (both Ollama URLs loopback):

1. Settings → **Test connection**. Expect: Server/Local Ollama dots go **amber**
   (not red) and the inline info box explains Ollama isn't running on this Mac,
   that Distavo still records/transcribes, and how to install/point at a server.
2. **Check permissions…** → the Local Network row reads **"Not needed with your
   current settings"** and explains macOS will ask once a LAN server is set.
   No dead-end "toggle it on" instruction, no orange after-update note.
3. Set Server Ollama to a LAN URL (e.g. `http://192.168.0.5:11434`) → reopen the
   sheet → the row becomes actionable with **Request Access Now**. Click it:
   the macOS Local Network prompt appears (first time), and Distavo now shows in
   System Settings → Privacy & Security → Local Network.
   Reset between attempts: `tccutil reset All uk.co.riera.distavo` (or the
   edition's bundle id) — Apple's own tip from the rejection.
4. A failing **public** URL (e.g. `https://ollama.example.com`) shows a red dot
   plus the generic "check the server is running and the URL is correct" line —
   no Local Network claim.

## Permissions sheet

5. Settings → Connections → **Check permissions…** opens the sheet.
6. **Local Network** row (when a LAN endpoint is configured): "Request Access
   Now" triggers the prompt; "Open Local Network Settings" opens the correct
   pane; the orange note explains the after-update **off→on + relaunch** fix.
7. On macOS **14.4+** the **Microphone** and **System Audio Recording** rows show.
   - Microphone reflects real state: green "Granted" when allowed; "Request
     Access…" when undetermined (clicking prompts and the row updates); "Open
     Microphone Settings" when denied.
   - Audio row opens the System Audio Recording pane.
8. On macOS **< 14.4** only the Local Network row shows (capture unsupported).

## The real-world trigger this fixes

After a Sparkle auto-update replaced the app binary, the Local Network grant read
**ON** but was denied — every connection to the LAN host failed while `curl`
worked. Cure: toggle the entry **off→on** and relaunch. Multiple "Distavo"
entries can accumulate (one per code signature seen); enable them all.
