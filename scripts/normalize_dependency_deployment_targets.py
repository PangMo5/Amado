# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only

"""Keep Tuist dependency projects inside the active SDK's deployment range.

Tuist 4.195 copies package minimum versions even when Xcode no longer supports
them. Remove this generation step when Tuist clamps dependency deployment targets
itself. Only generated dependency projects are changed; app minimums and package
versions stay in their manifests.
"""

import plistlib
import re
import subprocess
from pathlib import Path


def version(value):
    return tuple(int(component) for component in value.split("."))


def sdk_minimums():
    minimums = {}
    for sdk in ("iphoneos", "watchos", "macosx"):
        sdk_path = subprocess.check_output(
            ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True
        ).strip()
        with (Path(sdk_path) / "SDKSettings.plist").open("rb") as file:
            target = plistlib.load(file)["SupportedTargets"][sdk]
        minimums[target["DeploymentTargetSettingName"]] = target["MinimumDeploymentTarget"]
    return minimums


def normalize(source, minimums):
    pattern = re.compile(
        r"\b(IPHONEOS_DEPLOYMENT_TARGET|WATCHOS_DEPLOYMENT_TARGET|MACOSX_DEPLOYMENT_TARGET)"
        r" = ([0-9]+(?:\.[0-9]+)*);"
    )

    def replace(match):
        key, current = match.groups()
        minimum = minimums[key]
        return f"{key} = {minimum};" if version(current) < version(minimum) else match.group()

    return pattern.sub(replace, source)


def main():
    projects = Path(__file__).resolve().parents[1] / "Tuist/.build/tuist-derived/Projects"
    paths = sorted(projects.glob("*/*.xcodeproj/project.pbxproj"))
    if not paths:
        raise SystemExit("No generated dependency projects. Run tuist generate first.")
    minimums = sdk_minimums()
    changed = 0
    for path in paths:
        source = path.read_text()
        updated = normalize(source, minimums)
        if updated != source:
            path.write_text(updated)
            changed += 1
    print(f"Updated deployment targets in {changed} generated dependency projects: {minimums}")


if __name__ == "__main__":
    main()
