# Shipping Zero Fret

The code is done and the Release configuration builds and links for `arm64`
device targets. What is left is signing and distribution, which needs your Apple
credentials — nothing in this repo carries them, by design.

---

## Signing

Signing runs off an **App Store Connect API key**, not an Apple ID signed into
Xcode. That is deliberate: it works headlessly, over SSH, and in CI, and it does
not expire the way an Xcode session does.

The credentials live in `.env.asc` at the repo root, which is **gitignored**:

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8"
```

`Scripts/device.sh` and `Scripts/archive.sh` source that file automatically, so
there is nothing to export by hand.

The private key itself lives outside the repo entirely, at
`~/.appstoreconnect/private_keys/`, mode `600`. Apple lets you download a `.p8`
exactly once — if it is ever lost, revoke the key and generate a new one.

### Setting this up on another machine

1. App Store Connect → **Users and Access** → **Integrations** → **Keys**
2. **+**, name it, access **App Manager**
3. Download the `.p8` (one download only)
4. ```sh
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
   chmod 600 ~/.appstoreconnect/private_keys/AuthKey_*.p8
   cp .env.asc.example .env.asc   # then fill in the two IDs
   ```

The Issuer ID is shown at the top of that same Keys page.

### The Xcode-account alternative

If you would rather use a signed-in Apple ID, Xcode → Settings → Accounts → **+**.
The scripts fall back to it automatically when no API key is set. It is fine
locally and useless in CI.

---

## Run it on the phone

```sh
Scripts/device.sh
```

Plug the iPhone in, unlock it, and trust the Mac. The script lists devices,
builds Debug for the one it finds, installs and launches.

If a registered device shows as `unavailable`, it just means it is not plugged
in or not reachable on the network.

Use a ProMotion iPhone if you have one, because it matters here: `CADisableMinimumFrameDurationOnPhone`
plus the display link's `CAFrameRateRange` is what unlocks 120 Hz, and both are
needed. Confirm with Xcode's Core Animation FPS gauge.

---

## TestFlight

### Already done once

The App ID `dev.phux.zerofret` is registered, the App Store Connect record
exists, and an `IOS_APP_STORE` provisioning profile named **Zero Fret App Store**
is bound to the existing distribution certificate. None of that needs repeating —
skip to "Archive, export, upload".

### Two things that will waste an afternoon if you hit them cold

**Homebrew `rsync` breaks IPA packaging.** Xcode's packaging step shells out to
`rsync`, and Homebrew's 3.x rejects the flags it passes. What you see is a bare
`error: exportArchive Copy failed`; the real message,
`rsync error: syntax or usage error`, is inside a `.xcdistributionlogs` bundle
under `$TMPDIR`. `Scripts/archive.sh` pins `/usr/bin` first on PATH to avoid it.

**Cloud signing needs an Admin key.** `signingStyle=automatic` asks Apple to mint
a distribution certificate on demand, and an App Manager key gets
`Cloud signing permission error`. Since a distribution certificate already exists
locally, the script exports with `signingStyle=manual` against a named profile
instead. `EXPORT_PROFILE` and `EXPORT_CERT` live in `.env.asc` alongside the API
key — put them there rather than exporting them in a shell, or the next release
fails with `No profiles for 'dev.phux.zerofret' were found` and the reason is
gone with the session that set them. List the profiles you have with:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

**The private key is only downloadable once.** If `AuthKey_*.p8` is ever lost,
the key is dead — revoke it and generate a new one. There is no re-download.

### Creating the app record from scratch (only for a new app)

`POST /v1/apps` is not permitted by the API — `apps` allows only
`GET_COLLECTION`, `GET_INSTANCE` and `UPDATE`. App creation must be done in the
browser.

**Apps → + → New App**

| Field | Value |
|---|---|
| Platform | iOS |
| Name | `Zero Fret` |
| Primary language | English (U.S.) |
| Bundle ID | `dev.phux.zerofret` — pick it from the dropdown |
| SKU | `zerofret` (any unique string; never shown to users) |
| User access | Full Access |

If `dev.phux.zerofret` is not in the Bundle ID dropdown, it has not been
registered yet. Either build once with Option A or B above (which registers it),
or add it by hand at **Certificates, Identifiers & Profiles → Identifiers → +**.

### 2. Archive, export, upload

```sh
Scripts/archive.sh --upload
```

Or, to look at it first:

```sh
Scripts/archive.sh                    # archive + export to build/export
Scripts/archive.sh --upload --build 2 # bump the build number and ship it
```

The script writes `ExportOptions.plist` at run time from
`Config/Signing.xcconfig`, so no team ID is ever committed.

### 3. Answer the compliance question

`ITSAppUsesNonExemptEncryption` is already set to `false` in `Info.plist`, which
is correct — the app has no networking of any kind — so TestFlight will not stop
and ask.

### 4. Internal testing

TestFlight → Internal Testing → add yourself. Internal builds skip review and go
live as soon as processing finishes, usually a few minutes.

External testers need a Beta App Review, which wants a description and a contact
email. Suggested description:

> Zero Fret is a guitar and bass tuner. Point the phone at your instrument and
> pluck a string; the display shows a vibrating string whose wobble slows and
> stops as the note comes into tune. Nothing is recorded or transmitted, and the
> microphone runs only while the app is open.

---

## App Review notes, if you go past TestFlight

- **Microphone.** `NSMicrophoneUsageDescription` states the negative explicitly
  ("Audio never leaves your device and is never recorded"), which is what
  reviewers look for.
- **No background audio.** `UIBackgroundModes` is deliberately absent. This is
  the difference between a tuner and something that invites questions about why
  the orange indicator stays lit.
- **Idle timer.** Disabled only while a pitch is present, re-enabled after 45 s
  of silence. Permanently disabling it is a battery complaint and a review
  question.
- **Privacy nutrition label.** Data Not Collected. Nothing leaves the device.
- **Guideline 2.1 recording.** `Scripts/review-recording.sh` cold-launches the app
  and walks the typical flow into `AppStore/review/`. The phone has to be
  unlocked; a locked phone records black, and Apple asked for a physical device.
  The generated string is Debug-only. The reply to paste is
  `AppStore/review/REPLY.txt`.

---

## Store listing

The listing text lives in `AppStore/metadata/<locale>/`, one file per field
(`name.txt`, `subtitle.txt`, `description.txt`, `keywords.txt`,
`promotional_text.txt`, `whats_new.txt`, the three URLs). Edit the files, not
the App Store Connect website, so the text is reviewed and versioned like code.

```sh
source .env.asc
Scripts/metadata.py diff              # files vs ASC, read-only (the default)
Scripts/metadata.py push --dry-run    # the exact PATCH bodies, nothing sent
Scripts/metadata.py push              # send only the fields that differ
Scripts/metadata.py pull              # overwrite the files from ASC
```

A missing file leaves that field alone; an empty file clears it. Limits are
checked before anything is sent: name and subtitle 30 characters, keywords 100,
promotional text 170, description and What's New 4000.

**What a live version lets you change.** Only the promotional text — Apple
describes it as updatable "without requiring an updated submission". Everything
else (name, subtitle, description, keywords, What's New) needs a version in an
editable state: Prepare for Submission, or one that was rejected. `push` against
a live-only app sends the promotional text and lists the rest as skipped, exiting
non-zero. The support, marketing and privacy URLs are not documented either way,
so the script does not try them on a live version.

**When the rest needs to ship:**

```sh
Scripts/metadata.py push --create-version 1.1 --dry-run
Scripts/metadata.py push --create-version 1.1
```

That creates the 1.1 version record, then pushes every differing field to it.
Attaching a build and submitting is still `Scripts/archive.sh --upload` and the
website. What's New does not exist for the first version, so `whats_new.txt`
stays empty until 1.1.

---

## Version numbering

`MARKETING_VERSION` (1.1) and `CURRENT_PROJECT_VERSION` (1) live in the project.
Pass `--build N` to `Scripts/archive.sh` to override the build number for a given
upload; App Store Connect rejects a build number it has already seen for the same
version.
