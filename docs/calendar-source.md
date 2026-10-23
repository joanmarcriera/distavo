# Calendar source for auto-record: EventKit or Google Calendar API? (Vikunja #4003)

Status: **decision recommended, one verification outstanding** (see "Not verified"). Spike note only; no code.

## Question
Where should Distavo read upcoming meetings from, for the auto-record series (shortcut, then
calendar-driven reminders or auto-start, with the stop decided by the call ending)?

## Recommendation: EventKit. Google API only if a verified gap appears.

| Need | EventKit | Google Calendar API |
|---|---|---|
| Already in the codebase | Yes: `apple/Sources/Distavo/Calendar/CalendarEventProvider.swift` (read-only, `predicateForEvents`, own/accepted/tentative/declined mapping from `EKParticipant.participantStatus`, `isCurrentUser`) | No |
| Account setup | Google account added once in System Settings > Internet Accounts; no OAuth client of ours | OAuth client, consent screen, tokens in Keychain |
| Permission | One EventKit prompt, already opt-in from Settings (`requestFullAccessToEvents`) | `calendar.events.readonly` is a sensitive scope: Google app verification before public use |
| Network | None from Distavo (Calendar.app syncs) | Calls to googleapis.com: against the local-first stance |
| Editions | Works in Direct, Setapp, App Store (sandbox entitlement `com.apple.security.personal-information.calendars`) | Needs network client entitlement and Keychain handling in all three |
| Other calendars (iCloud, Exchange, CalDAV) | Free | Google only |

## What auto-record needs from an event, and what EventKit exposes
- Start, end, title, all-day flag, attendees, my response status: **already used** by `CalendarEventProvider`.
- Recurring occurrences: `predicateForEvents(withStart:end:)` returns expanded occurrences, so a weekly meeting appears as separate events in the window. Detached exceptions are separate occurrences too.
- Meeting link (Meet / Teams / Zoom): `EKEvent.url`, `location` and `notes` can hold it. Google Calendar events synced through Internet Accounts usually carry the Meet link in the event URL or location/notes text. **The provider deliberately never reads these today** (privacy: "never notes, location, URL"), so using them for link detection means a new, narrow, local-only extractor that returns only the provider kind (meet/teams/zoom/none), never the URL or the text.
- Change latency: `EKEventStoreChangedNotification` fires when Calendar.app syncs; the sync delay itself is Apple's/Google's and **not measured here** (check 4 below). A meeting created a minute before it starts may produce a late or missing reminder.

## Design rules that follow (keep from #2946)
- Calendar content stays untrusted (`CalendarTrust`): only events the user owns or accepted trigger a reminder.
- Read-only; nothing writes to a calendar.
- Opt-in by use: no prompt until the user turns auto-record on.

## Not verified (could not be done unattended)
- **Marc's real calendar on this Mac**: reading it needs the Calendar TCC prompt on a signed build and a person at the screen, and the content is his private data. Checks to run when back, on a signed Direct build, with one test event per row:
  1. A Google Meet event: is the link in `url`, `location` or `notes`?
  2. A Teams and a Zoom invite.
  3. A recurring event and one edited occurrence.
  4. Create an event in Google Calendar on the web: seconds until Calendar.app and `EKEventStoreChanged` show it.
  5. A declined event and one with no attendees.
- If 1 shows the Meet link is missing from EventKit for Google accounts, that is the first real gap; only then does Auto-record 9 (Google API) become active.

## Decision
Build auto-record on EventKit. Add a link-kind extractor behind the existing provider seam, test it on synthetic strings, and run the five manual checks above before enabling anything by default.
