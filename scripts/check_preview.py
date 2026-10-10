import json, subprocess, time
from pathlib import Path

def run(*args):
    return subprocess.check_output(args, text=True)
devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))
iphones = [d for group in devices["devices"].values() for d in group if d["name"].startswith("iPhone")]
assert iphones, "No iPhone simulator installed"
device = iphones[0]["udid"]
if iphones[0]["state"] != "Booted":
    run("xcrun", "simctl", "boot", device)
run("xcrun", "simctl", "bootstatus", device, "-b")
app = "simulator-build/Build/Products/Debug-iphonesimulator/Teleprompter.app"
run("xcrun", "simctl", "install", device, app)
run("xcrun", "simctl", "launch", device, "online.independent.teleprompter.ios", "--preview-smoke")
time.sleep(5)
run("xcrun", "simctl", "io", device, "screenshot", "preview.png")
# Use Apple's image framework via Swift to verify visible white glyphs in the central screen area.
run("swift", "scripts/check_pixels.swift", "preview.png")
