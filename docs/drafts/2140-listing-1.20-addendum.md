# DRAFT — #2140 addendum: 1.20 additions to the ca/es/en listing

**Status:** draft for Marc's voice pass, written by the 2026-10-21 drive. Nothing pasted into App Store
Connect, nothing written to `apple/metadata/listing.json`, no website change. It extends
`docs/drafts/2140-store-listing-ca-es-en.md` (1.14 refresh), which still holds the base copy.

Limits: promo text 170. Counts below were computed with `len()`.

## Promotional text (replaces the 1.14 one if used)

| Lang | Text | Chars |
|---|---|---|
| en | Catalan, Spanish, Galician and Basque transcribed entirely on your Mac. All notes in one window, ask them questions locally, merge meetings into one cited note. | 160 |
| ca | Català, castellà, gallec i basc transcrits del tot al teu Mac. Totes les notes en una finestra, preguntes a les teves notes en local i una nota de projecte amb cites. | 166 |
| es | Catalán, castellano, gallego y euskera transcritos en tu Mac. Todas las notas en una ventana, preguntas a tus notas en local y una nota de proyecto con citas. | 158 |

(Counts computed with Python len(); all three are within 170.)

## Description block to add (all three languages), under "A TIDY PIPELINE"

**en**
```
NOTES WINDOW
• Every note in one list, newest meeting first, with search and the actions that apply to the selected note
• Ask your notes: questions answered from your own notes, by a model on your Mac or network only
• Summarise Together: pick two to ten notes and get one project note where every bullet cites its meeting
```
**ca**
```
FINESTRA DE NOTES
• Totes les notes en una llista, la reunió més recent primer, amb cerca i les accions de la nota seleccionada
• Pregunta a les teves notes: respostes a partir de les teves notes, amb un model al teu Mac o a la teva xarxa
• Resumeix-les juntes: tria entre dues i deu notes i obtén una nota de projecte on cada punt cita la reunió d'origen
```
**es**
```
VENTANA DE NOTAS
• Todas las notas en una lista, la reunión más reciente primero, con búsqueda y las acciones de la nota seleccionada
• Pregunta a tus notas: respuestas a partir de tus notas, con un modelo en tu Mac o en tu red
• Resumir juntas: elige de dos a diez notas y obtén una nota de proyecto donde cada punto cita su reunión
```

## Screenshots (per edition) — NOT produced tonight
The drive could not launch an edition build (disk + build lock, no GUI session). Shot list for Marc:
1. Notes window with 5+ notes (use `docs/screenshots/1.18-notes-window/` as the layout reference)
2. Summarise Together sheet and the resulting cited note
3. Ask window answering from notes (local-only badge)
4. Recorder question sheet with suggested values (needs #3943 build)
Build per edition with `-scheme Distavo-AppStore` / `Distavo-Setapp` / `Distavo`; never reuse one edition's
screenshots for another (memory: editions are not interchangeable).

## [VERIFY] before use
- "Ask" is local-only by construction (`docs/ask-local-only.md`); do not say "private cloud" anywhere.
- Catalan wording is mine, not native-reviewed.
