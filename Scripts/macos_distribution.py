#!/usr/bin/env python3
"""Sign and validate this project's exported macOS app without changing its rights."""

import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


BUNDLE_SUFFIXES = {".app", ".appex", ".xpc", ".framework"}
REQUIRED_ARCHS = {"arm64", "x86_64"}
MACH_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
}
REQUIRED_RIGHTS = (
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.device.audio-input",
    "com.apple.security.files.user-selected.read-write",
)


class DistributionError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise DistributionError(message)


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise DistributionError(f"{args[0]} failed for {args[-1]}:\n{detail}")
    return result


def app_path(value):
    path = Path(value).absolute()
    require(not path.is_symlink() and path.is_dir() and path.suffix == ".app",
            f"Expected a real .app directory: {path}")
    return path


def is_macho(stream):
    magic = stream.read(4)
    if magic in MACH_MAGICS:
        return True
    fat = {b"\xca\xfe\xba\xbe": ("big", 4), b"\xbe\xba\xfe\xca": ("little", 4),
           b"\xca\xfe\xba\xbf": ("big", 8), b"\xbf\xba\xfe\xca": ("little", 8)}
    if magic not in fat:
        return False
    endian, width = fat[magic]
    if not 0 < int.from_bytes(stream.read(4), endian) <= 128:
        return False
    stream.seek(16)
    stream.seek(int.from_bytes(stream.read(width), endian))
    return stream.read(4) in MACH_MAGICS


def code_items(app):
    """Inventory only real files and directories; never walk framework symlinks."""
    binaries, bundles = [], [app]
    for root, directories, files in os.walk(app, followlinks=False):
        directory = Path(root)
        directories[:] = [name for name in directories
                          if not (directory / name).is_symlink()]
        bundles.extend(directory / name for name in directories
                       if Path(name).suffix.lower() in BUNDLE_SUFFIXES)
        for name in files:
            path = directory / name
            if path.is_symlink() or not path.is_file():
                continue
            with path.open("rb") as stream:
                if is_macho(stream):
                    binaries.append(path)
    require(binaries, f"No Mach-O binaries found in {app}")
    return binaries, bundles


def signature(path, arch=None):
    options = ["--arch", arch] if arch else []
    result = run("/usr/bin/codesign", "--display", "--verbose=4", *options, path)
    return result.stdout + result.stderr


def check_identity(details, team, path):
    authorities = re.findall(r"^Authority=(.+)$", details, re.MULTILINE)
    require(authorities and authorities[0].startswith("Developer ID Application:"),
            f"Expected Developer ID Application signing: {path}")
    require(f"TeamIdentifier={team}" in details.splitlines(),
            f"Signing team must be {team}: {path}")


def leaf_certificate(path, arch=None):
    with tempfile.TemporaryDirectory(prefix="mumble-certificate-") as temporary:
        prefix = str(Path(temporary) / "cert-")
        options = ["--arch", arch] if arch else []
        run("/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", *options, path)
        certificate = Path(prefix + "0")
        require(certificate.is_file(), f"Missing leaf signing certificate: {path}")
        return certificate.read_bytes()


def entitlements(path, arch=None):
    options = ["--arch", arch] if arch else []
    result = run("/usr/bin/codesign", "--display", "--entitlements", ":-", *options, path)
    return plistlib.loads(result.stdout.encode()) if result.stdout.strip() else {}


def signing_identity(app, team):
    check_identity(signature(app), team, app)
    return hashlib.sha1(leaf_certificate(app)).hexdigest().upper()


def resign(app, identity):
    binaries, bundles = code_items(app)
    for path in sorted(binaries + bundles, key=lambda p: len(p.parts), reverse=True):
        run("/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime",
            "--timestamp", "--preserve-metadata=identifier,entitlements,requirements", path)


def authorized(value, patterns):
    return any(value == pattern or (pattern.endswith("*") and value.startswith(pattern[:-1]))
               for pattern in patterns if isinstance(pattern, str))


def verify_profile(bundle, rights, team, arch=None):
    groups = [group for group in rights.get("com.apple.security.application-groups", [])
              if isinstance(group, str) and group.startswith("group.")]
    if not groups:
        return
    profile_path = bundle / "Contents" / "embedded.provisionprofile"
    require(profile_path.is_file() and not profile_path.is_symlink(),
            f"App Groups require an embedded Developer ID provisioning profile: {bundle}")
    result = run("/usr/bin/security", "cms", "-D", "-i", profile_path)
    profile = plistlib.loads(result.stdout.encode())
    require(team in profile.get("TeamIdentifier", []), f"Wrong provisioning team: {bundle}")
    require(profile.get("ProvisionsAllDevices") is True,
            f"Profile must permit Developer ID distribution (ProvisionsAllDevices): {bundle}")
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, dt.datetime), f"Profile has no expiration date: {bundle}")
    require(expiration.replace(tzinfo=dt.timezone.utc) > dt.datetime.now(dt.timezone.utc),
            f"Provisioning profile has expired: {bundle}")
    allowed = profile.get("Entitlements", {})
    require(allowed.get("com.apple.developer.team-identifier") == team,
            f"Profile entitlements have the wrong team: {bundle}")
    app_id = rights.get("com.apple.application-identifier", "")
    info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
    bundle_id = info.get("CFBundleIdentifier")
    require(isinstance(bundle_id, str) and app_id == f"{team}.{bundle_id}",
            f"Signed application identifier does not match CFBundleIdentifier: {bundle}")
    require(isinstance(app_id, str) and authorized(
        app_id, [allowed.get("com.apple.application-identifier", "")]),
        f"Profile does not authorize the signed application identifier: {bundle}")
    for group in groups:
        require(authorized(group, allowed.get("com.apple.security.application-groups", [])),
                f"Profile does not authorize App Group {group}: {bundle}")
    require(leaf_certificate(bundle, arch) in profile.get("DeveloperCertificates", []),
            f"Profile does not authorize the Developer ID signing certificate: {bundle}")


def verify(app, team):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    binaries, bundles = code_items(app)
    for path in binaries:
        architectures = set(run("/usr/bin/lipo", "-archs", path).stdout.split())
        require(REQUIRED_ARCHS <= architectures,
                f"Universal arm64 + x86_64 required; found {sorted(architectures)}: {path}")
        for arch in architectures:
            details = signature(path, arch)
            check_identity(details, team, f"{path} ({arch})")
            require(re.search(r"^Timestamp=(?!none$|Not Set$).+$", details, re.MULTILINE),
                    f"Missing secure signing timestamp: {path} ({arch})")
            require(re.search(r"flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b", details),
                    f"Hardened Runtime is not enabled: {path} ({arch})")
            rights = entitlements(path, arch)
            require(str(rights.get("com.apple.security.get-task-allow", False)).lower()
                    not in {"true", "yes", "1"},
                    f"Debugging entitlement get-task-allow must be disabled: {path} ({arch})")
    for bundle in bundles:
        if bundle.suffix.lower() in {".app", ".appex", ".xpc"}:
            for arch in REQUIRED_ARCHS:
                rights = entitlements(bundle, arch)
                verify_profile(bundle, rights, team, arch)
                if bundle == app:
                    for key in REQUIRED_RIGHTS:
                        require(rights.get(key) is True,
                                f"Required entitlement {key} is missing: {app} ({arch})")
    print(f"Verified Developer ID signatures, Universal binaries and provisioning: {app}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("signing-identity", "verify", "resign"):
        command = subparsers.add_parser(name)
        command.add_argument("app", type=app_path)
        command.add_argument("identity" if name == "resign" else "team")
    args = parser.parse_args()
    if args.command == "signing-identity":
        print(signing_identity(args.app, args.team))
    elif args.command == "resign":
        resign(args.app, args.identity)
    else:
        verify(args.app, args.team)


if __name__ == "__main__":
    try:
        main()
    except (DistributionError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
