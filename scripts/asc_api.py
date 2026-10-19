#!/usr/bin/env python3
"""App Store Connect helpers for Kool Edit. Never prints the API key or JWT."""

import argparse
import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.trilsoft.kooledit"
APP_NAME = "Kool Edit"
SKU = "kool-edit-ios"
GROUP_NAME = "Family"


def log(message):
    print(message, file=sys.stderr)


def redact(text):
    return re.sub(
        r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
        "[redacted]",
        text,
    )


def jwt(key_id, issuer_id):
    proc = subprocess.run(
        [
            "xcrun",
            "altool",
            "--generate-jwt",
            "--api-key",
            key_id,
            "--api-issuer",
            issuer_id,
        ],
        capture_output=True,
        text=True,
    )
    match = re.search(
        r"(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)",
        proc.stderr + "\n" + proc.stdout,
    )
    if not match:
        log("Could not mint an App Store Connect JWT. Check ASC_KEY_ID, ASC_ISSUER_ID, and the key file.")
        detail = redact((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()
        if detail:
            log(detail[-800:])
        sys.exit(1)
    return match.group(1)


def request(token, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw.decode(errors="replace")[:800]}
        return exc.code, payload


def api_error(payload):
    errors = payload.get("errors") if isinstance(payload, dict) else None
    if not errors:
        return json.dumps(payload)[:800]
    parts = []
    for error in errors:
        parts.append(
            f"{error.get('status')} {error.get('code')} {error.get('title')}: {error.get('detail')}"
        )
    return "; ".join(parts)


def find_bundle(token):
    status, payload = request(
        token,
        "GET",
        f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}&limit=5",
    )
    if status != 200:
        log(f"List bundle IDs failed: {api_error(payload)}")
        sys.exit(1)
    for item in payload.get("data", []):
        if item.get("attributes", {}).get("identifier") == BUNDLE_ID:
            return item
    return None


def ensure_bundle(token):
    existing = find_bundle(token)
    if existing:
        log(f"Bundle ID already registered: {BUNDLE_ID} ({existing['id']})")
        return existing
    status, payload = request(
        token,
        "POST",
        "/v1/bundleIds",
        {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": BUNDLE_ID,
                    "name": APP_NAME,
                    "platform": "IOS",
                },
            }
        },
    )
    if status not in (200, 201):
        log(f"Create bundle ID failed: {api_error(payload)}")
        sys.exit(1)
    log(f"Registered bundle ID {BUNDLE_ID} ({payload['data']['id']})")
    return payload["data"]


def find_app(token):
    status, payload = request(
        token,
        "GET",
        f"/v1/apps?filter[bundleId]={BUNDLE_ID}&limit=5",
    )
    if status != 200:
        log(f"List apps failed: {api_error(payload)}")
        sys.exit(1)
    for item in payload.get("data", []):
        if item.get("attributes", {}).get("bundleId") == BUNDLE_ID:
            return item
    status, payload = request(token, "GET", f"/v1/apps?filter[sku]={SKU}&limit=5")
    if status == 200:
        for item in payload.get("data", []):
            if item.get("attributes", {}).get("sku") == SKU:
                return item
    return None


def require_app(token):
    existing = find_app(token)
    if existing:
        attrs = existing.get("attributes", {})
        log(f"App record exists: {attrs.get('name')} ({existing['id']})")
        return existing
    log(f"App Store Connect has no app record for {BUNDLE_ID}.")
    log(
        "Create it in App Store Connect before uploading: platform iOS, "
        f"name {APP_NAME}, bundle ID {BUNDLE_ID}, SKU {SKU}."
    )
    log("This API key cannot create app records (POST /v1/apps is forbidden).")
    sys.exit(2)


def distribution_identity():
    proc = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
    )
    for line in proc.stdout.splitlines():
        if "Apple Distribution" in line or "iPhone Distribution" in line:
            return line.strip()
    return None


def find_distribution_certificate(token):
    """Return the existing Apple Distribution certificate. Never creates or revokes one."""
    status, payload = request(
        token,
        "GET",
        "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=20",
    )
    if status != 200:
        log(f"List distribution certificates failed: {api_error(payload)}")
        sys.exit(1)
    certificates = payload.get("data", [])
    for item in certificates:
        if item.get("id") == "T3J35W46XN":
            return item
    return certificates[0] if certificates else None


def install_profile(content_b64):
    raw = base64.b64decode(content_b64)
    plist_start = raw.find(b"<?xml")
    plist_end = raw.find(b"</plist>")
    profile = plistlib.loads(raw[plist_start : plist_end + len(b"</plist>")])
    uuid = profile["UUID"]
    dest_dir = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, f"{uuid}.mobileprovision")
    with open(dest, "wb") as handle:
        handle.write(raw)
    xcode_dir = os.path.expanduser(
        "~/Library/Developer/Xcode/UserData/Provisioning Profiles"
    )
    os.makedirs(xcode_dir, exist_ok=True)
    with open(os.path.join(xcode_dir, f"{uuid}.mobileprovision"), "wb") as handle:
        handle.write(raw)
    log(f"Installed provisioning profile {profile.get('Name')} ({uuid}).")
    return profile


def ensure_profile(token, bundle, certificate):
    profile_name = "Kool Edit App Store"
    status, payload = request(token, "GET", "/v1/profiles?limit=100")
    if status != 200:
        log(f"List provisioning profiles failed: {api_error(payload)}")
        return None
    for item in payload.get("data", []):
        attrs = item.get("attributes", {})
        if attrs.get("name") == profile_name and attrs.get("profileState") == "ACTIVE":
            detail_status, detail = request(token, "GET", f"/v1/profiles/{item['id']}")
            content = detail.get("data", {}).get("attributes", {}).get("profileContent")
            if detail_status == 200 and content:
                install_profile(content)
                return item
    status, payload = request(
        token,
        "POST",
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": profile_name,
                    "profileType": "IOS_APP_STORE",
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                    "certificates": {
                        "data": [{"type": "certificates", "id": certificate["id"]}]
                    },
                },
            }
        },
    )
    if status not in (200, 201):
        log(f"Create provisioning profile failed: {api_error(payload)}")
        return None
    install_profile(payload["data"]["attributes"]["profileContent"])
    return payload["data"]


def next_build_number(token, app_id):
    status, payload = request(
        token,
        "GET",
        f"/v1/builds?filter[app]={app_id}&limit=200&sort=-uploadedDate",
    )
    if status != 200:
        log(f"Could not list builds ({api_error(payload)}). Using build number 1.")
        return 1
    numbers = []
    for item in payload.get("data", []):
        version = item.get("attributes", {}).get("version")
        if version and str(version).isdigit():
            numbers.append(int(version))
    return (max(numbers) + 1) if numbers else 1


def ensure_beta_group(token, app):
    app_id = app["id"]
    status, payload = request(token, "GET", f"/v1/apps/{app_id}/betaGroups?limit=50")
    if status != 200:
        log(f"Could not list TestFlight groups: {api_error(payload)}")
        return None
    group = None
    for item in payload.get("data", []):
        if item.get("attributes", {}).get("name") == GROUP_NAME:
            group = item
            break
    if group is None:
        status, payload = request(
            token,
            "POST",
            "/v1/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {
                        "name": GROUP_NAME,
                        "isInternalGroup": True,
                        "hasAccessToAllBuilds": True,
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}}
                    },
                }
            },
        )
        if status not in (200, 201):
            log(f"Could not create the {GROUP_NAME} internal group: {api_error(payload)}")
            return None
        group = payload["data"]
        log(f"Created internal group {GROUP_NAME} ({group['id']}).")
    else:
        log(f"Internal group {GROUP_NAME} already exists ({group['id']}).")

    attrs = group.get("attributes", {})
    if attrs.get("hasAccessToAllBuilds") is not True:
        status, payload = request(
            token,
            "PATCH",
            f"/v1/betaGroups/{group['id']}",
            {
                "data": {
                    "type": "betaGroups",
                    "id": group["id"],
                    "attributes": {"hasAccessToAllBuilds": True},
                }
            },
        )
        if status != 200:
            log(f"Could not enable access to all builds on {GROUP_NAME}: {api_error(payload)}")
        else:
            group = payload["data"]
            log(f"{GROUP_NAME} now has access to all builds.")

    status, testers = request(token, "GET", f"/v1/betaGroups/{group['id']}/betaTesters?limit=20")
    if status == 200:
        count = len(testers.get("data", []))
        log(f"{GROUP_NAME} has {count} tester(s).")
        if count == 0:
            log(
                "No testers were added. This API key cannot add the account holder to groups; "
                "add internal testers in App Store Connect."
            )
    else:
        log(f"Could not list {GROUP_NAME} testers: {api_error(testers)}")
    return group


def prepare(args):
    token = jwt(args.key_id, args.issuer_id)
    bundle = ensure_bundle(token)
    identity = distribution_identity()
    if not identity:
        log("No Apple Distribution identity is in the login keychain. Refusing to create or revoke certificates.")
        sys.exit(1)
    log(f"Distribution certificate already in the keychain: {identity}")
    certificate = find_distribution_certificate(token)
    if certificate is None:
        log("The API did not list an Apple Distribution certificate. Refusing to create one.")
        sys.exit(1)
    log(f"Using existing distribution certificate {certificate['id']}.")
    profile = ensure_profile(token, bundle, certificate)
    profile_name = None if profile is None else profile.get("attributes", {}).get("name")
    if profile is None:
        log("No App Store provisioning profile is available. Automatic cloud signing is also unavailable to this API key.")
    app = require_app(token)
    group = ensure_beta_group(token, app)
    build_number = next_build_number(token, app["id"])
    if build_number < 1:
        build_number = 1
    result = {
        "bundleId": BUNDLE_ID,
        "bundleResourceId": bundle["id"],
        "appName": app.get("attributes", {}).get("name"),
        "appleAppId": app["id"],
        "sku": app.get("attributes", {}).get("sku"),
        "buildNumber": build_number,
        "betaGroupId": None if group is None else group["id"],
        "betaGroupHasAccessToAllBuilds": None
        if group is None
        else group.get("attributes", {}).get("hasAccessToAllBuilds"),
        "profileName": profile_name,
        "certificateId": certificate["id"],
    }
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


def build_status(args):
    token = jwt(args.key_id, args.issuer_id)
    status, payload = request(
        token,
        "GET",
        f"/v1/builds?filter[app]={args.app_id}&limit=10&sort=-uploadedDate",
    )
    if status != 200:
        log(f"Build status lookup failed: {api_error(payload)}")
        sys.exit(1)
    builds = []
    for item in payload.get("data", []):
        attrs = item.get("attributes", {})
        builds.append(
            {
                "id": item.get("id"),
                "version": attrs.get("version"),
                "processingState": attrs.get("processingState"),
                "uploadedDate": attrs.get("uploadedDate"),
            }
        )
    json.dump({"builds": builds}, sys.stdout)
    sys.stdout.write("\n")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--key-id", required=True)
    prepare_parser.add_argument("--issuer-id", required=True)
    prepare_parser.set_defaults(func=prepare)
    status_parser = sub.add_parser("build-status")
    status_parser.add_argument("--key-id", required=True)
    status_parser.add_argument("--issuer-id", required=True)
    status_parser.add_argument("--app-id", required=True)
    status_parser.set_defaults(func=build_status)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
