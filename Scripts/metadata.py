#!/usr/bin/env python3
"""App Store listing text as files in the repo, pushed with the ASC API.

    Scripts/metadata.py [diff]                 files vs App Store Connect (read-only)
    Scripts/metadata.py pull                   ASC -> AppStore/metadata/<locale>/*.txt
    Scripts/metadata.py push [--dry-run]       PATCH only the fields that differ
    Scripts/metadata.py push --create-version 1.1 [--dry-run]

One UTF-8 file per field under AppStore/metadata/<locale>/. A missing file means
"leave that field alone"; an empty file means "clear it". One trailing newline is
stripped on read and added on write, so editors that insist on one do no harm.

Which record is read and written: the editable version (and app info) if one
exists, otherwise the live one. Apple only lets most of the listing change on a
version that is being prepared or was rejected; on the live version only the
promotional text moves. See "Store listing" in docs/SHIPPING.md.

Needs `source .env.asc` first, like Scripts/asc.py.
"""
import argparse, difflib, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc

BUNDLE_ID = "dev.phux.zerofret"
PLATFORM = "IOS"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AppStore", "metadata")

# (file, API attribute, which resource owns it, character limit or None)
# "info" is appInfoLocalizations (per app), "version" is appStoreVersionLocalizations.
FIELDS = [
    ("name.txt",               "name",             "info",    30),
    ("subtitle.txt",           "subtitle",         "info",    30),
    ("privacy_policy_url.txt", "privacyPolicyUrl", "info",    None),
    ("description.txt",        "description",      "version", 4000),
    ("keywords.txt",           "keywords",         "version", 100),
    ("promotional_text.txt",   "promotionalText",  "version", 170),
    ("whats_new.txt",          "whatsNew",         "version", 4000),
    ("support_url.txt",        "supportUrl",       "version", None),
    ("marketing_url.txt",      "marketingUrl",     "version", None),
]

# States in which Apple accepts edits to the full listing. These are the lists
# fastlane's spaceship uses (get_edit_app_store_version / fetch_edit_app_info),
# which have tracked Apple's behaviour for years; Apple's own docs only say
# "when the status of the app version permits editing".
EDITABLE_VERSION = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                    "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY"}
EDITABLE_INFO = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                 "WAITING_FOR_REVIEW"}
LIVE = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}

# The only field Apple documents as changeable on a live version ("without
# requiring an updated submission"). The support and marketing URLs are not
# documented either way, so they are not attempted on a live version rather
# than guessed at against the real store.
LIVE_EDITABLE = {"promotionalText"}


def api(method, path, body=None):
    status, out = asc.call(method, path, body)
    if status >= 300:
        errors = out.get("errors") or [out]
        detail = "; ".join(e.get("detail") or e.get("title") or json.dumps(e) for e in errors)
        sys.exit(f"error: {method} {path} -> HTTP {status}: {detail}")
    return out


def get_all(path):
    out = api("GET", path)
    data = out["data"]
    while out.get("links", {}).get("next"):
        out = api("GET", out["links"]["next"])
        data += out["data"]
    return data


def version_state(v):
    # appStoreState is deprecated in favour of appVersionState; older records
    # may only carry the former.
    a = v["attributes"]
    return a.get("appVersionState") or a.get("appStoreState")


def info_state(i):
    a = i["attributes"]
    return a.get("state") or a.get("appStoreState")


def pick(records, state_of, editable):
    """Editable record if there is one, else the live one. Newest first wins."""
    for wanted in (editable, LIVE):
        for r in records:
            if state_of(r) in wanted:
                return r, wanted is editable
    sys.exit("error: no editable or live record found; states are "
             + ", ".join(state_of(r) for r in records))


class Remote:
    """The ASC side: chosen version and app info, and their localizations."""

    def __init__(self):
        apps = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
        if not apps:
            sys.exit(f"error: no app with bundle ID {BUNDLE_ID} on this account")
        self.app_id = apps[0]["id"]
        self.load()

    def load(self):
        versions = get_all(f"/v1/apps/{self.app_id}/appStoreVersions"
                           f"?filter[platform]={PLATFORM}&limit=200")
        versions.sort(key=lambda v: v["attributes"]["createdDate"], reverse=True)
        self.version_count = len(versions)
        self.has_editable_version = any(version_state(v) in EDITABLE_VERSION for v in versions)
        self.version, self.version_editable = pick(versions, version_state, EDITABLE_VERSION)
        infos = get_all(f"/v1/apps/{self.app_id}/appInfos")
        self.info, self.info_editable = pick(infos, info_state, EDITABLE_INFO)

        # locale -> {"version": loc record, "info": loc record}
        self.locs = {}
        for owner, path in (
            ("version", f"/v1/appStoreVersions/{self.version['id']}/appStoreVersionLocalizations?limit=200"),
            ("info", f"/v1/appInfos/{self.info['id']}/appInfoLocalizations?limit=200"),
        ):
            for loc in get_all(path):
                self.locs.setdefault(loc["attributes"]["locale"], {})[owner] = loc

    @property
    def first_version(self):
        # whatsNew is "not available for the first version of the app".
        return self.version_count == 1

    def editable(self, owner, attr):
        if owner == "info":
            return self.info_editable
        return self.version_editable or attr in LIVE_EDITABLE

    def value(self, locale, owner, attr):
        loc = self.locs.get(locale, {}).get(owner)
        return None if loc is None else loc["attributes"].get(attr)

    def describe(self):
        v, i = self.version, self.info
        return (f"version {v['attributes']['versionString']} ({version_state(v)}, "
                f"{'editable' if self.version_editable else 'live'}); "
                f"app info ({info_state(i)}, {'editable' if self.info_editable else 'live'})")


def read_file(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return text[:-1] if text.endswith("\n") else text


def local():
    """locale -> {file: text} for every field file that exists."""
    if not os.path.isdir(ROOT):
        sys.exit(f"error: {os.path.relpath(ROOT)} does not exist; run `Scripts/metadata.py pull` first")
    out = {}
    for locale in sorted(os.listdir(ROOT)):
        d = os.path.join(ROOT, locale)
        if not os.path.isdir(d):
            continue
        out[locale] = {f: read_file(os.path.join(d, f))
                       for f, _, _, _ in FIELDS if os.path.isfile(os.path.join(d, f))}
    return out


def validate(files):
    """Fail before sending anything: Apple rejects the whole PATCH otherwise."""
    problems = []
    for locale, fields in files.items():
        for f, attr, _, limit in FIELDS:
            text = fields.get(f)
            if text is None or limit is None:
                continue
            if len(text) > limit:
                problems.append(f"{locale}/{f}: {len(text)} characters, limit is {limit}")
            if "\n" in text and attr in ("name", "subtitle", "keywords", "promotionalText"):
                problems.append(f"{locale}/{f}: must be a single line")
        kw = fields.get("keywords.txt")
        if kw is not None and len(kw.encode()) > 100:
            # Apple's reference says "up to 100 bytes"; the form counts characters.
            # Only differs for non-ASCII keywords, so warn rather than refuse.
            print(f"warning: {locale}/keywords.txt is {len(kw.encode())} bytes "
                  f"(Apple's docs say 100 bytes)", file=sys.stderr)
    if problems:
        sys.exit("error: listing text fails Apple's limits:\n  " + "\n  ".join(problems))


def differences(remote, files):
    """[(locale, file, attr, owner, asc value, file value)] for fields that differ."""
    out = []
    for locale, fields in files.items():
        for f, attr, owner, _ in FIELDS:
            if f not in fields:
                continue
            have, want = remote.value(locale, owner, attr) or "", fields[f]
            if have != want:
                out.append((locale, f, attr, owner, have, want))
    return out


def cmd_pull(remote):
    for locale, owners in sorted(remote.locs.items()):
        d = os.path.join(ROOT, locale)
        os.makedirs(d, exist_ok=True)
        for f, attr, owner, _ in FIELDS:
            if owner not in owners:
                continue
            with open(os.path.join(d, f), "w", encoding="utf-8") as fh:
                fh.write((owners[owner]["attributes"].get(attr) or "") + "\n")
        print(f"wrote {os.path.relpath(d)}")


def cmd_diff(remote):
    files = local()
    validate(files)
    missing = sorted(set(files) - set(remote.locs))
    for locale in missing:
        print(f"{locale}: no such localization in App Store Connect (add it there first)")
    diffs = [d for d in differences(remote, files) if d[0] not in missing]
    for locale, f, _, _, have, want in diffs:
        sys.stdout.writelines(difflib.unified_diff(
            [l + "\n" for l in have.split("\n")], [l + "\n" for l in want.split("\n")],
            f"asc/{locale}/{f}", f"files/{locale}/{f}"))
    if not diffs and not missing:
        print("No differences.")
    return diffs


def create_version(remote, version_string, dry_run):
    if remote.has_editable_version:
        sys.exit(f"error: {remote.describe()} — an editable version already exists; "
                 f"push to it instead of creating another")
    body = {"data": {"type": "appStoreVersions",
                     "attributes": {"platform": PLATFORM, "versionString": version_string},
                     "relationships": {"app": {"data": {"type": "apps", "id": remote.app_id}}}}}
    print(f"POST /v1/appStoreVersions\n{json.dumps(body, indent=1)}")
    if dry_run:
        # Show the PATCHes as if the new version existed: same diff, every field
        # editable. The ids printed are the live records'; the real run uses the
        # new version's copies, which only exist after the POST.
        remote.version_editable = remote.info_editable = True
        remote.version_count += 1
        print(f"(dry run: as if {version_string} existed; ids below are the live records')")
        return
    api("POST", "/v1/appStoreVersions", body)
    # Apple copies the previous version's localizations into the new one and
    # opens an editable app info alongside it; re-read to pick both up.
    remote.load()
    print(f"created: {remote.describe()}")


def cmd_push(remote, dry_run, new_version):
    files = local()
    validate(files)
    if new_version:
        create_version(remote, new_version, dry_run)
    else:
        print(f"target: {remote.describe()}")

    patches, skipped = {}, []
    for locale, f, attr, owner, _, want in differences(remote, files):
        loc = remote.locs.get(locale, {}).get(owner)
        if loc is None:
            skipped.append(f"{locale}/{f}: no {locale} localization in App Store Connect")
        elif attr == "whatsNew" and remote.first_version:
            skipped.append(f"{locale}/{f}: Apple has no What's New for the first version")
        elif not remote.editable(owner, attr):
            skipped.append(f"{locale}/{f}: needs a new version "
                           f"(Scripts/metadata.py push --create-version X.Y)")
        else:
            key = (loc["type"], loc["id"])
            patches.setdefault(key, {})[attr] = want if want != "" else None

    for (kind, id_), attrs in patches.items():
        body = {"data": {"type": kind, "id": id_, "attributes": attrs}}
        print(f"PATCH /v1/{kind}/{id_}\n{json.dumps(body, indent=1, ensure_ascii=False)}")
        if not dry_run:
            api("PATCH", f"/v1/{kind}/{id_}", body)
    for s in skipped:
        print(f"skipped {s}")
    if not patches:
        print("Nothing to send.")
    elif dry_run:
        print("Dry run: nothing sent.")
    if skipped:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", nargs="?", default="diff", choices=["diff", "pull", "push"])
    p.add_argument("--dry-run", action="store_true", help="push: print the request bodies, send nothing")
    p.add_argument("--create-version", metavar="X.Y",
                   help="push: create this App Store version first, then push everything to it")
    args = p.parse_args()
    if args.action != "push" and (args.dry_run or args.create_version):
        p.error("--dry-run and --create-version only apply to push")

    remote = Remote()
    if args.action == "pull":
        print(f"source: {remote.describe()}")
        cmd_pull(remote)
    elif args.action == "diff":
        print(f"comparing against {remote.describe()}")
        cmd_diff(remote)
    else:
        cmd_push(remote, args.dry_run, args.create_version)


if __name__ == "__main__":
    main()
