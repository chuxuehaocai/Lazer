#!/usr/bin/env python3
"""Prepare target-specific iOS profiles and sign only the packaged Payload.

The shell wrappers retain their native signers. This shared implementation also
reads binary plists on Windows and keeps signing inputs outside the final IPA.
"""

from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tempfile
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED


GROUPS = "com.apple.security.application-groups"
TEAM = "com.apple.developer.team-identifier"
IDENTIFIER = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*")


def load_profile(path: Path) -> dict:
    raw = path.read_bytes()
    try:
        profile = plistlib.loads(raw)
    except (ValueError, plistlib.InvalidFileException):
        # Apple's CMS profiles carry an XML plist as their signed content. Work
        # on bytes, since the surrounding DER signature is not UTF-8 text.
        start, end = raw.find(b"<?xml"), raw.rfind(b"</plist>")
        if start < 0 or end < start:
            raise ValueError(f"{path} contains no XML provisioning profile")
        profile = plistlib.loads(raw[start:end + len(b"</plist>")])
    if not isinstance(profile, dict) or not isinstance(profile.get("Entitlements"), dict):
        raise ValueError(f"{path} contains no Entitlements dictionary")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime):
        raise ValueError(f"{path} contains no valid ExpirationDate")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires <= datetime.now(timezone.utc):
        raise ValueError(f"{path} provisioning profile expired at {expires.isoformat()}")
    return profile


def matches(pattern: str, value: str) -> bool:
    return pattern == value or (
        pattern.endswith("*") and pattern.count("*") == 1
        and value.startswith(pattern[:-1])
    )


def target_entitlements(profile: dict, identifier: str) -> dict:
    entitlements = copy.deepcopy(profile["Entitlements"])
    application = entitlements.get("application-identifier")
    if not isinstance(application, str) or "." not in application:
        raise ValueError("profile grants no valid application-identifier")
    prefix, pattern = application.split(".", 1)
    if not matches(pattern, identifier):
        raise ValueError(f"profile installs {pattern!r}, not {identifier!r}")
    team = entitlements.get(TEAM)
    if not isinstance(team, str) or not team:
        raise ValueError("profile grants no team identifier")
    entitlements["application-identifier"] = prefix + "." + identifier
    keychains = entitlements.get("keychain-access-groups", [])
    if not isinstance(keychains, list) or any(not isinstance(value, str) for value in keychains):
        raise ValueError("profile has invalid keychain-access-groups")
    if keychains:
        resolved = []
        for value in keychains:
            if "*" in value:
                concrete = prefix + "." + identifier
                if not matches(value, concrete):
                    raise ValueError(f"profile keychain group {value!r} does not cover {identifier}")
                value = concrete
            resolved.append(value)
        entitlements["keychain-access-groups"] = resolved
    return entitlements


def extract_payload(ipa: Path, destination: Path) -> None:
    with ZipFile(ipa) as package:
        seen = set()
        for item in package.infolist():
            name = item.orig_filename
            path = PurePosixPath(name)
            if (name in seen or "\\" in name or path.is_absolute()
                    or ".." in path.parts or not path.parts or path.parts[0] != "Payload"
                    or path.as_posix() != name.rstrip("/")
                    or re.search(r'[<>:"|?*\x00-\x1f]', name)):
                raise ValueError(f"unsafe or non-Payload IPA entry: {name}")
            seen.add(name)
            if stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError(f"IPA symlink is unsupported: {item.filename}")
            package.extract(item, destination)
            target = destination.joinpath(*path.parts)
            if os.name != "nt" and target.is_file():
                target.chmod((item.external_attr >> 16) & 0o777 or 0o644)


def prepare_targets(app: Path, profile: Path, extension_profiles: dict[str, Path],
                    app_group: str | None, working: Path) -> list[dict]:
    bundles = [app, *sorted((app / "PlugIns").glob("*.appex"))]
    targets = []
    for bundle in bundles:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        identifier = info.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not IDENTIFIER.fullmatch(identifier):
            raise ValueError(f"invalid bundle identifier in {bundle}")
        selected = extension_profiles.get(identifier, profile) if bundle != app else profile
        entitlements = target_entitlements(load_profile(selected), identifier)
        targets.append({"bundle": bundle, "info": info, "identifier": identifier,
                        "profile": selected, "entitlements": entitlements})
    unused = set(extension_profiles) - {target["identifier"] for target in targets[1:]}
    if unused:
        raise ValueError("extension profile names unknown bundle(s): " + ", ".join(sorted(unused)))
    if len({target["entitlements"][TEAM] for target in targets}) != 1:
        raise ValueError("app and extension profiles must use the same signing team")
    granted = []
    for target in targets:
        groups = target["entitlements"].get(GROUPS, [])
        if not isinstance(groups, list) or any(not isinstance(group, str) for group in groups):
            raise ValueError("profile has invalid application groups")
        granted.append(set(groups))
    common = set.intersection(*granted)
    if app_group:
        if not re.fullmatch(r"group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", app_group):
            raise ValueError("app group must start with 'group.' and contain a valid identifier")
        if app_group not in common:
            raise ValueError(f"{app_group} is not in the profile of every app and extension")
    elif common:
        existing = targets[0]["info"].get("LazerAppGroupIdentifier")
        app_group = existing if existing in common else sorted(common)[0]
    for index, target in enumerate(targets):
        target["info"]["LazerAppGroupIdentifier"] = app_group or ""
        target["entitlements"].pop(GROUPS, None)
        if app_group:
            target["entitlements"][GROUPS] = [app_group]
        # Preserve binary plist support without any platform-specific plist tool.
        (target["bundle"] / "Info.plist").write_bytes(plistlib.dumps(target["info"]))
        shutil.copyfile(target["profile"], target["bundle"] / "embedded.mobileprovision")
        target["entitlement_file"] = working / f"entitlements-{index}.plist"
        target["entitlement_file"].write_bytes(plistlib.dumps(target["entitlements"]))
    print(f"shared application group: {app_group or 'not enabled by these profiles'}", flush=True)
    return targets


def package_payload(stage: Path, output: Path) -> None:
    payload = stage / "Payload"
    executables = set()
    for info_path in payload.rglob("Info.plist"):
        info = plistlib.loads(info_path.read_bytes())
        executable = info.get("CFBundleExecutable") if isinstance(info, dict) else None
        if isinstance(executable, str) and executable not in (".", "..") and "/" not in executable and "\\" not in executable:
            executables.add(info_path.parent / executable)
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w", ZIP_DEFLATED) as package:
        for path in sorted(payload.rglob("*")):
            if path.is_dir():
                continue
            item = ZipInfo.from_file(path, path.relative_to(stage).as_posix())
            item.create_system = 3
            mode = 0o755 if path in executables or path.suffix == ".dylib" else 0o644
            item.external_attr = (stat.S_IFREG | mode) << 16
            item.compress_type = ZIP_DEFLATED
            package.writestr(item, path.read_bytes())


def signed_entitlements(binary: Path) -> dict:
    """Read the XML entitlement blob from the signed arm64 Mach-O itself.

    A successful signer invocation or diagnostic printout does not establish
    that it applied the requested per-target entitlements.
    """
    data = binary.read_bytes()
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError(f"{binary} is not a thin arm64 Mach-O")
    if struct.unpack_from("<I", data, 4)[0] != 0x100000C:
        raise ValueError(f"{binary} is not an arm64 Mach-O")
    offset = 32
    try:
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            command, size = struct.unpack_from("<II", data, offset)
            if size < 8 or offset + size > len(data):
                break
            if command == 0x1D:
                start, length = struct.unpack_from("<II", data, offset + 8)
                signature = data[start:start + length]
                magic, total, count = struct.unpack_from(">III", signature)
                if magic != 0xFADE0CC0 or total != len(signature):
                    break
                for index in range(count):
                    slot, blob = struct.unpack_from(">II", signature, 12 + index * 8)
                    if slot == 5:
                        blob_magic, blob_size = struct.unpack_from(">II", signature, blob)
                        if blob_magic != 0xFADE7171 or blob + blob_size > total:
                            break
                        value = plistlib.loads(signature[blob + 8:blob + blob_size])
                        if isinstance(value, dict):
                            return value
            offset += size
    except (struct.error, ValueError, plistlib.InvalidFileException) as error:
        raise ValueError(f"invalid signature in {binary}: {error}") from error
    raise ValueError(f"{binary} carries no readable signed XML entitlements")


def resign(args) -> None:
    signer = shutil.which(args.backend)
    if not signer:
        raise ValueError(f"{args.backend} was not found on PATH")
    extension_profiles = {}
    for value in args.extension_profile:
        identifier, separator, path = value.partition("=")
        if not separator or identifier in extension_profiles:
            raise ValueError("extension-profile must be a unique BUNDLE_IDENTIFIER=FILE")
        extension_profiles[identifier] = Path(path).resolve()
    output = args.out.resolve() if args.out else args.ipa.resolve().with_name(args.ipa.stem + "-resigned.ipa")
    if output == args.ipa.resolve():
        raise ValueError("output must differ from the input IPA")
    with tempfile.TemporaryDirectory(prefix="lazer-resign-") as directory:
        stage = Path(directory)
        extract_payload(args.ipa, stage)
        app = stage / "Payload/Runner.app"
        subprocess.run([os.sys.executable, str(Path(__file__).with_name("verify-ios-bundle.py")),
                        "--app", str(app)], check=True)
        targets = prepare_targets(app, args.profile.resolve(), extension_profiles, args.app_group, stage)
        nested = [path for path in app.rglob("*")
                  if (path.is_dir() and path.suffix == ".framework")
                  or (path.is_file() and path.suffix == ".dylib")]
        by_bundle = {target["bundle"]: target for target in targets}
        signing_order = sorted([*nested, *by_bundle], key=lambda path: len(path.parts), reverse=True)
        for path in signing_order:
            target = by_bundle.get(path)
            if args.backend == "rcodesign":
                # rcodesign recursively signs by default. --shallow is required
                # so the final parent sign keeps each child's own entitlements.
                command = [signer, "sign", "--shallow", "--p12-file", str(args.p12.resolve()),
                           "--p12-password-file", str(args.password_file.resolve())]
                if target:
                    # A drive letter is parsed as a scope by rcodesign's scoped
                    # file option. Use a relative path from the private stage.
                    command += ["--entitlements-xml-file", target["entitlement_file"].name]
            else:
                command = [signer, "--force", "--sign", args.identity,
                           "--timestamp=none", "--generate-entitlement-der"]
                if target:
                    command += ["--entitlements", str(target["entitlement_file"])]
            subprocess.run([*command, str(path)], cwd=stage, check=True)
        for target in targets:
            binary = target["bundle"] / target["info"]["CFBundleExecutable"]
            if args.backend == "codesign":
                subprocess.run([signer, "--verify", "--deep", "--strict", str(target["bundle"])], check=True)
            actual = signed_entitlements(binary)
            if actual != target["entitlements"]:
                raise ValueError(f"{target['identifier']} signed entitlements differ from its profile-derived request")
        if args.backend == "rcodesign":
            # verify accepts a Mach-O path, not a bundle. It checks signature
            # hashes, but upstream documents incomplete Apple-policy coverage;
            # an actual installation still requires a device and valid identity.
            for path in signing_order:
                if path.is_dir():
                    info = plistlib.loads((path / "Info.plist").read_bytes())
                    executable = info.get("CFBundleExecutable")
                    if (not isinstance(executable, str) or not executable
                            or executable in (".", "..") or "/" in executable or "\\" in executable):
                        raise ValueError(f"invalid signing executable in {path}")
                    path = path / executable
                subprocess.run([signer, "verify", str(path)], check=True)
        # Build into the private stage and verify before replacing an existing
        # output. The stage's passwords, profiles and entitlements never ship.
        packaged = stage / "signed.ipa"
        package_payload(stage, packaged)
        subprocess.run([os.sys.executable, str(Path(__file__).with_name("verify-ios-bundle.py")),
                        "--ipa", str(packaged)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(packaged, output)
    print(f"wrote {output}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--extension-profile", action="append", default=[])
    parser.add_argument("--app-group")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--backend", choices=("codesign", "rcodesign"), required=True)
    parser.add_argument("--identity")
    parser.add_argument("--p12", type=Path)
    parser.add_argument("--password-file", type=Path)
    args = parser.parse_args()
    if args.backend == "codesign" and not args.identity:
        parser.error("codesign requires --identity")
    if args.backend == "rcodesign" and (not args.p12 or not args.password_file):
        parser.error("rcodesign requires --p12 and --password-file")
    try:
        resign(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"iOS re-signing failed: {error}") from error


if __name__ == "__main__":
    main()
