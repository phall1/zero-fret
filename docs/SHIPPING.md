# Shipping Zero Fret

The code is done and the Release configuration builds and links for `arm64`
device targets. What is left is signing and distribution, which needs your Apple
credentials — nothing in this repo carries them, by design.

---

## The one thing that is currently blocking

`xcodebuild` reports:

```
error: No Accounts: Add a new account in Accounts settings.
error: No profiles for 'dev.phux.zerofret' were found
```

Xcode has the certificates in the keychain (`Apple Development` and
`Apple Distribution`) but no Apple ID signed in, so it cannot register the new
App ID or mint a provisioning profile. Pick **one** of the two fixes below.

### Option A — sign into Xcode (30 seconds, GUI)

Xcode → Settings → Accounts → **+** → Apple ID → sign in.

Then everything below works, because `-allowProvisioningUpdates` can create the
App ID and the profile on demand.

### Option B — App Store Connect API key (headless, works over SSH)

1. App Store Connect → **Users and Access** → **Integrations** → **Keys**
2. **+**, name it something like `zero-fret-ci`, access **App Manager**
3. Download the `.p8` — Apple lets you download it exactly once
4. ```sh
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
   export ASC_KEY_ID=XXXXXXXXXX
   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
   ```

Option B is strictly better if you ever want this in CI. Option A is faster right
now.

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

### 1. Create the app record — once, in App Store Connect

This is the only step that has no CLI and must be done in the browser.

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

---

## Version numbering

`MARKETING_VERSION` (1.0) and `CURRENT_PROJECT_VERSION` (1) live in the project.
Pass `--build N` to `Scripts/archive.sh` to override the build number for a given
upload; App Store Connect rejects a build number it has already seen for the same
version.
