#!/usr/bin/env python3
"""Stage and verify a Chef update; keep the running app alive."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import sys
from contextlib import contextmanager

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "outputs"
WORK = ROOT / "work"
LEGACY_NAME = "Jarvis"  # Keep the existing installed bundle URL and executable for macOS identity.
APP = OUT / (LEGACY_NAME + ".app")
LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
SOURCES = ["Chef.swift", "ChefModel.swift", "Voice.swift", "Dashboard.swift", "AgentSystem.swift", "Updates.swift", "PersonalAssistant.swift", "Usage.swift", "FishVoice.swift", "CodexLink.swift", "NeuralSpace.swift", "OrchestrationCore.swift", "OrchestrationEngine.swift", "OrchestrationAdapters.swift", "OrchestrationTests.swift", "OrchestrationDashboard.swift", "ImmersiveHUD.swift", "VoiceInteraction.swift", "LiveInformation.swift", "HolographicPortrait.swift", "AgentWorkflows.swift", "AgentGroups.swift", "BriefingRunner.swift", "InstalledApps.swift", "YouTubePlayback.swift", "DesktopControl.swift", "DesktopAgent.swift", "DesktopDashboard.swift", "PlanningWorkspace.swift", "PocketSync.swift", "AgentOffice.swift", "ParticleDissolve.swift", "OrbHologram.swift", "OrbWorkspace.swift", "ChefCompatibility.swift"]


def run(args):
    subprocess.run(args, cwd=ROOT, check=True, timeout=300)


def atomic_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".new")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def unregister_temporary_bundle(path):
    """Best-effort unregister of a temporary staged/backup app by exact URL."""
    if not path.exists() or not LSREGISTER.is_file():
        return
    try:
        subprocess.run([str(LSREGISTER), "-u", str(path)], cwd=ROOT, check=False,
                       timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


@contextmanager
def staged_apps(work_dir, unregister=unregister_temporary_bundle):
    """Own both temporary app copies and always remove them after unregistering."""
    with tempfile.TemporaryDirectory(prefix="chef-stage-", dir=work_dir) as temporary:
        root = Path(temporary)
        staged = root / "Chef.app"
        backup = root / "previous.app"
        try:
            yield root, staged, backup
        finally:
            # Never pass APP here: only the two exact temporary bundle paths.
            unregister(staged)
            unregister(backup)


def cleanup_self_test():
    """Prove TemporaryDirectory cleanup on both success and failure paths."""
    with tempfile.TemporaryDirectory(prefix="chef-cleanup-test-") as test_dir:
        work_dir = Path(test_dir)
        for should_fail in (False, True):
            calls = []
            root = staged = backup = None
            try:
                with staged_apps(work_dir, unregister=calls.append) as (root, staged, backup):
                    staged.mkdir()
                    backup.mkdir()
                    if should_fail:
                        raise RuntimeError("synthetic build failure")
            except RuntimeError as error:
                if not should_fail or str(error) != "synthetic build failure":
                    raise
            if should_fail and root is not None and root.exists():
                raise AssertionError("Temporary stage survived a failure.")
            if not should_fail and root is not None and root.exists():
                raise AssertionError("Temporary stage survived success.")
            if calls != [staged, backup]:
                raise AssertionError("Temporary bundles were not both unregistered before cleanup.")


def build_and_install(stage_root, staged, backup):
    shutil.copytree(APP, staged)
    shutil.copytree(APP, backup)
    info = staged / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    build = str(int(metadata["CFBundleVersion"]) + 1)
    metadata["CFBundleVersion"] = build
    metadata["CFBundleName"] = "Chef"
    metadata["CFBundleDisplayName"] = "Chef"
    for key, value in list(metadata.items()):
        if key.startswith("NS") and key.endswith("UsageDescription") and isinstance(value, str):
            metadata[key] = value.replace(LEGACY_NAME, "Chef")
    metadata["CFBundleShortVersionString"] = "0.6.0"
    metadata["NSCalendarsFullAccessUsageDescription"] = "Chef reads your calendar agenda only when you ask, after you choose Connect Calendar."
    metadata["NSRemindersFullAccessUsageDescription"] = "Chef adds the reminders you request after you choose Connect Reminders."
    info.write_bytes(plistlib.dumps(metadata))
    resource = staged / f"Contents/Resources/{LEGACY_NAME}Head.png"
    resource.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(OUT / f"Assets/{LEGACY_NAME}Head.png", resource)
    executable = staged / f"Contents/MacOS/{LEGACY_NAME}"
    run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos26.0",
         *[str(OUT / source) for source in SOURCES], "-o", str(executable),
         "-module-cache-path", str(WORK / "module-cache"),
         "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "AVFoundation",
         "-framework", "Speech", "-framework", "FoundationModels", "-framework", "EventKit", "-framework", "Security", "-framework", "SceneKit", "-framework", "WebKit", "-framework", "ScreenCaptureKit", "-framework", "ApplicationServices"])
    run(["codesign", "--force", "--sign", "-", str(staged)])
    run([str(executable), "--self-test"])
    run([str(executable), "--orchestration-self-test"])
    run(["codesign", "--verify", "--deep", "--strict", str(staged)])
    relative = [f"Contents/MacOS/{LEGACY_NAME}", "Contents/Info.plist", f"Contents/Resources/{LEGACY_NAME}Head.png", "Contents/_CodeSignature/CodeResources"]
    try:
        for part in relative:
            source, target = staged / part, APP / part
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".new")
            shutil.copy2(source, temporary)
            os.replace(temporary, target)
        run(["codesign", "--verify", "--deep", "--strict", str(APP)])
    except Exception:
        for part in relative:
            source, target = backup / part, APP / part
            if not source.exists():
                target.unlink(missing_ok=True)
                continue
            temporary = target.with_name(target.name + ".rollback")
            shutil.copy2(source, temporary)
            os.replace(temporary, target)
        raise
    run(["ditto", "-c", "-k", "--keepParent", str(APP), str(OUT / "Chef.zip")])
    record = {"buildVersion": build, "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "checks": "Compilation, self-tests, staged and installed signature verification passed."}
    atomic_bytes(WORK / (LEGACY_NAME.lower() + "-updates/latest-build.json"), json.dumps(record, indent=2).encode())
    print(json.dumps(record))
    print("The tested app is staged. The running process was not restarted.")


def main():
    WORK.mkdir(exist_ok=True)
    if sys.argv[1:] == ["--cleanup-self-test"]:
        cleanup_self_test()
        print("Temporary stage cleanup passed on success and failure.")
        return
    with staged_apps(WORK) as (stage_root, staged, backup):
        build_and_install(stage_root, staged, backup)


if __name__ == "__main__":
    main()