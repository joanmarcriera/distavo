# DRAFT — #2140 App Store listing in Catalan, Spanish, English (1.14 refresh)

**Status:** draft for Marc's voice pass. Nothing pasted into App Store Connect. Do NOT write this into
`apple/metadata/listing.json` — `scripts/setup-appstore-listing.py` pushes that file to App Store Connect.
**Relation to `docs/marketing/store-listing-1.13.md`:** that draft is framed as "New in 1.13" and names only
Hebrew/Thai/Welsh. This one is the 1.14 refresh: adds Tamil + Norwegian, drops "New in", and is
shorter. Tone: lead with the on-device Catalan claim; Fast engine copy admits it trades some accuracy for speed
(bake-off: 12/14 vs 14/14 for Whisper turbo on the English call).

**Limits (Apple):** name 30 · subtitle 30 · promotional text 170 · description 4,000 · keywords 100
(comma-separated, no spaces). Counts below were computed, not estimated.

**Claims used (all from repo/memory):** Apple dictation/Apple Intelligence have no Catalan (verified 2026-09-10);
BSC models for ca/es/gl/eu; 16 GB for those; Fast = 25 European languages; Whisper = 99; packs he/th/ta/cy/no opt-in;
Ollama summaries, optional Apple Intelligence (macOS 26+, preview, not for Catalan); no cloud/accounts/telemetry.
No price stated (store shows local pricing). Nothing said about Setapp here (#222).

## English
| Field | Text | Chars |
|---|---|---|
| Name | Distavo: Meeting Notes | 22 |
| Subtitle | Catalan notes, on your Mac | 26 |
| Promo text | Catalan, Spanish, Galician and Basque transcribed entirely on your Mac - languages Apple's own dictation can't do. Now with Tamil and Norwegian packs. | 150 |
| Keywords | meeting,notes,transcribe,catalan,spanish,whisper,ollama,recorder,summary,markdown,private,welsh | 95 |
Description (1,162 chars):
```
Meeting notes in Catalan, entirely on your Mac.

Distavo turns a recording into a clean Markdown note: a speaker-labelled transcript, decisions, action points and a follow-up email draft. Record with one click, or drop any audio or video file into a watched folder.

CATALAN, SPANISH, GALICIAN AND BASQUE, ON-DEVICE
Built-in models from the Barcelona Supercomputing Center transcribe these four languages without a word leaving your Mac. Apple's dictation and Apple Intelligence do not support Catalan. Distavo does.

AND MANY MORE LANGUAGES
• Fast engine (NVIDIA Parakeet): 25 European languages, quicker in exchange for some accuracy
• Whisper: 99 languages
• Optional language packs in Settings: Hebrew, Thai, Tamil, Welsh and Norwegian

PRIVATE BY DESIGN
• Transcription runs on-device on Apple Silicon
• Summaries come from your own Ollama server (this Mac or your network), or optionally Apple Intelligence on macOS 26+ (preview, not available for Catalan)
• No cloud, no accounts, no telemetry

Requires macOS 14 or later and Apple Silicon. The Catalan, Spanish, Galician and Basque models need 16 GB of memory or more. One-time purchase, no subscription.
```

## Català
| Camp | Text | Caràcters |
|---|---|---|
| Nom | Distavo: notes de reunió | 24 |
| Subtítol | Reunions en català, al teu Mac | 30 |
| Text promocional | El català, l'espanyol, el gallec i el basc, transcrits al teu Mac, sense núvol: llengües que el dictat d'Apple no entén. Ara amb paquets de tàmil i noruec. | 155 |
| Paraules clau | reunions,notes,transcripció,català,espanyol,whisper,ollama,gravadora,resum,markdown,privat,gal·lès | 98 |
Descripció (1.263 caràcters):
```
Notes de reunió en català, directament al teu Mac.

Distavo converteix una gravació en una nota en Markdown ben ordenada: transcripció amb cada parlant identificat, decisions, tasques i un esborrany de correu de seguiment. Grava amb un clic, o deixa qualsevol àudio o vídeo en una carpeta vigilada, i ell fa la resta.

CATALÀ, ESPANYOL, GALLEC I BASC, SENSE SORTIR DEL MAC
Uns models del Barcelona Supercomputing Center transcriuen aquestes quatre llengües sense que ni una paraula surti de l'ordinador. El dictat d'Apple i Apple Intelligence no entenen el català. Distavo, sí.

I MOLTES ALTRES LLENGÜES
• Motor ràpid (NVIDIA Parakeet): 25 llengües europees, més veloç a canvi d'una mica de precisió
• Whisper: 99 llengües
• Paquets opcionals a Configuració: hebreu, tailandès, tàmil, gal·lès i noruec

PRIVAT PER DISSENY
• La transcripció es fa al dispositiu, amb Apple Silicon
• Els resums els escriu el teu servidor Ollama (aquest Mac o la teva xarxa) o, si vols, Apple Intelligence a partir de macOS 26 (en previsualització; no disponible en català)
• Sense núvol, sense comptes, sense telemetria

Requereix macOS 14 o posterior i Apple Silicon. Els models de català, espanyol, gallec i basc necessiten 16 GB de memòria o més. Compra única, sense subscripció.
```

## Español
| Campo | Texto | Caracteres |
|---|---|---|
| Nombre | Distavo: notas de reunión | 25 |
| Subtítulo | Catalán y español, en tu Mac | 28 |
| Texto promocional | Catalán, español, gallego y vasco, transcritos en tu Mac y sin nube: idiomas que el dictado de Apple no entiende. Ahora con paquetes de tamil y noruego. | 152 |
| Palabras clave | reuniones,notas,transcripción,catalán,español,whisper,ollama,grabadora,resumen,markdown,privado | 95 |
Descripción (1.273 caracteres):
```
Notas de reunión en catalán y español, directamente en tu Mac.

Distavo convierte una grabación en una nota en Markdown bien ordenada: transcripción con cada interlocutor identificado, decisiones, tareas y un borrador de correo de seguimiento. Graba con un clic, o suelta cualquier audio o vídeo en una carpeta vigilada, y él hace el resto.

CATALÁN, ESPAÑOL, GALLEGO Y VASCO, SIN SALIR DE TU MAC
Unos modelos del Barcelona Supercomputing Center transcriben estos cuatro idiomas sin que una sola palabra salga de tu ordenador. El dictado de Apple y Apple Intelligence no entienden el catalán. Distavo, sí.

Y MUCHOS IDIOMAS MÁS
• Motor rápido (NVIDIA Parakeet): 25 idiomas europeos, más veloz a cambio de algo de precisión
• Whisper: 99 idiomas
• Paquetes opcionales en Ajustes: hebreo, tailandés, tamil, galés y noruego

PRIVADO POR DISEÑO
• La transcripción se hace en el dispositivo, con Apple Silicon
• Los resúmenes los escribe tu propio servidor Ollama (este Mac o tu red) o, si quieres, Apple Intelligence desde macOS 26 (en vista previa; no disponible en catalán)
• Sin nube, sin cuentas, sin telemetría

Requiere macOS 14 o posterior y Apple Silicon. Los modelos de catalán, español, gallego y vasco necesitan 16 GB de memoria o más. Compra única, sin suscripción.
```
## Screenshot brief (per edition; App Store scheme build only)
Accepted Mac sizes: 1280x800, 1440x900, 2560x1600, 2880x1800 (`docs/distribution-checklist.md` 4.3). Current
`apple/metadata/screenshots/` holds 3 older PNGs. Editions are not interchangeable: capture the App Store build for
the App Store (no Sparkle, no donate link), the Setapp build for Setapp; never reuse Direct shots. Capture at 2x.
Use the scripted test meeting (`docs/testing/test-meeting-script.md`) or synthetic content, never a real meeting.
1. Hero: menu-bar menu mid-recording, caption "Catalan meeting notes, on your Mac".
2. A finished note (Markdown) beside the menu: decisions + actions table.
3. Settings, Transcription: Automatic engine, Catalan model, "Download now".
4. Settings, language packs: Hebrew/Thai/Tamil/Welsh/Norwegian switches (off by default).
5. Privacy shot: Activity log line showing local processing; caption "No cloud. No accounts. No telemetry."
Caption sets in ca/es/en. `[VERIFY]` whether the app UI is localised; if English-only, ca/es sets are captions on the same UI.
## Open / [VERIFY]
- Tamil and Norwegian write without punctuation (Norwegian lower-case only), per what's-new; deliberately not hyped here. `[VERIFY]` Marc's OK.
- "Whisper: 99 languages" is from the website note; `[VERIFY]` against the WhisperKit model card before publishing.
- Apple Intelligence line: summariser is opt-in preview behind a Settings toggle; keep only if that stays true at submission.
- ES subtitle "Reuniones en catalán, en tu Mac" would be 31 chars (too long), so it stays "Catalán y español". Marc's voice pass on all three.
