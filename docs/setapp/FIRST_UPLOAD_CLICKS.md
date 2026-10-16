# Setapp: first upload, the exact clicks

For the day MacPaw opens the vendor account. Edition: Single App Distribution,
USD 29 one-off (`DECISIONS.md` 2026-09-16). Longer background in
`MARC_RUNBOOK.md`; check list of what is already done in `BLOCKERS.md`.

## 0. Chase MacPaw now (KYC sent 2026-09-17, no reply)

Send to the BD contact (Anya) and cc developers@setapp.com. Draft:

> Subject: Distavo - vendor account status
>
> Hi Anya,
>
> I sent the KYC form on 17 September for Distavo (Single App Distribution,
> USD 29). I have not heard back and I don't have access to
> developer.setapp.com yet.
>
> Could you tell me where it is, and whether you need anything else from me?
> The build is ready and I can upload as soon as the account is open.
>
> Thanks,
> Marc

## 1. Log in and create the app record

1. Open https://developer.setapp.com and sign in with the account MacPaw invited.
2. Create a new app. Name `Distavo`, bundle id `uk.co.riera.distavo-setapp`,
   category Productivity.
3. Choose Single App Distribution if it asks. Do not pick Membership.
4. Banking/tax forms if shown (Wise details; see the Banking section of
   `MARC_RUNBOOK.md`).

## 2. Get the SDK and the public key

In the app's settings/credentials area:
1. Generate the app public key and download it.
2. Download the Setapp Framework (SDK) archive.
3. Ask MacPaw (or read the page) whether Single App Distribution needs the
   Framework in the binary. If it says no, tell the agent and skip step 3.

## 3. Save the files (do not commit them yet)

```
apple/vendor/setapp/SetappPublicKey.pem
apple/vendor/setapp/libSetapp.a        (or Setapp.xcframework/)
apple/vendor/setapp/Setapp.h           (only if the archive has one)
```

Do not paste the key or any dashboard token into chat.

## 4. The one command for an agent

Tell Claude: "Setapp SDK is in apple/vendor/setapp, apply
docs/setapp/FRAMEWORK_INTEGRATION.md and build the Setapp edition". It will
link the framework, add the key to the Setapp target, run `xcodegen generate`,
build `-scheme Distavo-Setapp` and check bundle id, `NSUpdateSecurityPolicy`,
no Sparkle and no donate link.

You then run the notarised build yourself (needs your notary profile):

```bash
cd apple && TEAM_ID=<team id> NOTARY_PROFILE=distavo-notary ./scripts/build-and-notarize.sh setapp
```

Output: `apple/build/release-setapp/Distavo-setapp.zip` (app + AppIcon.png, no `__MACOSX`).

## 5. First upload (Web UI only, the API cannot do the first one)

1. Dashboard, Distavo, Edit listing. Paste fields from `LISTING_DRAFT.md`
   (field table at the bottom). Icon: `apple/metadata/setapp/AppIcon-setapp.png`.
   Screenshots: `apple/metadata/screenshots/*.png` (check `ASSETS_CHECKLIST.md`).
2. Comments for Review Team: paste the block from `REVIEW_TEAM_NOTES.md`.
3. Edit Version, drag in `Distavo-setapp.zip`, paste release notes, submit for review.
4. Review takes about 2 to 5 business days. Reply to anything they ask in the
   dashboard.

After approval later versions can go through the Setapp API.
