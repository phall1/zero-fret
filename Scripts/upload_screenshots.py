#!/usr/bin/env python3
"""Replace the App Store screenshots of the editable version with the repo's.

    Scripts/upload_screenshots.py [--dry-run]

For each display type below, the set on the editable version's en-US
localization is emptied and refilled from the framed PNGs Scripts/screenshots.sh
writes, in filename order. Sets for display types not listed here are deleted,
so an old size cannot keep showing stale screenshots on the devices it covers.

Apple copies the previous version's screenshots into a new version; this is what
replaces them. It refuses to run against a live version.

Needs `source .env.asc` first, like Scripts/asc.py.
"""
import glob, hashlib, json, os, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc
from metadata import Remote, api, get_all

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AppStore", "screenshots")
LOCALE = "en-US"
SETS = {
    "APP_IPHONE_67": "iphone",          # 6.9", required for iPhone
    "APP_IPAD_PRO_3GEN_129": "ipad",    # 13", required for iPad
}


def upload(set_id, path, dry_run):
    name, size = os.path.basename(path), os.path.getsize(path)
    print(f"  + {name} ({size // 1024} KB)")
    if dry_run:
        return None
    data = open(path, "rb").read()
    reserved = api("POST", "/v1/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": name, "fileSize": size},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
    }})["data"]
    for op in reserved["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for header in op.get("requestHeaders") or []:
            req.add_header(header["name"], header["value"])
        urllib.request.urlopen(req).read()
    api("PATCH", f"/v1/appScreenshots/{reserved['id']}", {"data": {
        "type": "appScreenshots", "id": reserved["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
    }})
    return reserved["id"]


def main():
    dry_run = "--dry-run" in sys.argv
    remote = Remote()
    if not remote.version_editable:
        sys.exit(f"error: {remote.describe()} — screenshots only change on an editable version")
    loc = remote.locs.get(LOCALE, {}).get("version")
    if loc is None:
        sys.exit(f"error: no {LOCALE} localization on {remote.describe()}")
    print(f"target: {remote.describe()}")

    existing = {s["attributes"]["screenshotDisplayType"]: s
                for s in get_all(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")}

    for display, folder in SETS.items():
        files = sorted(glob.glob(os.path.join(ROOT, folder, "[0-9][0-9]-*.png")))
        if not files:
            sys.exit(f"error: no screenshots in {os.path.relpath(os.path.join(ROOT, folder))}")
        print(f"{display}: {len(files)} from {folder}/")
        if display in existing:
            set_id = existing[display]["id"]
            for shot in get_all(f"/v1/appScreenshotSets/{set_id}/appScreenshots"):
                print(f"  - {shot['attributes']['fileName']}")
                if not dry_run:
                    api("DELETE", f"/v1/appScreenshots/{shot['id']}")
        elif dry_run:
            set_id = None
        else:
            set_id = api("POST", "/v1/appScreenshotSets", {"data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display},
                "relationships": {"appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}},
            }})["data"]["id"]
        ids = [upload(set_id, f, dry_run) for f in files]
        if not dry_run:
            api("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
                {"data": [{"type": "appScreenshots", "id": i} for i in ids]})

    for display, stale in existing.items():
        if display not in SETS:
            print(f"{display}: deleting the set (not produced by Scripts/screenshots.sh)")
            if not dry_run:
                api("DELETE", f"/v1/appScreenshotSets/{stale['id']}")
    print("Dry run: nothing sent." if dry_run else "Done.")


if __name__ == "__main__":
    main()
