#!/usr/bin/env python3
"""Drives the app "Emilli 원격" on an Android emulator and saves screenshots for the manual.

Used by .github/workflows/capture-android.yml on a GitHub runner only (it installs the app and
changes emulator settings). Steps, in the order a new user meets them: first launch, the
"Share screen" tab with this phone's ID, every prompt that starting the service raises
(the app's warning, notifications, display over other apps, the service notice, Android's
screen capture consent), the input control notice and Android's Accessibility screens, then
Settings, the server settings with the built-in server, and the login screen.

  python3 drive.py --apk app.apk --out shots/ --locale ko-KR

Each screenshot is <out>/android-NN-<step>-<lang>.png; <out>/ui/ keeps the UI dump of each step
so a missed tap can be traced. A step that cannot find what it needs is reported and skipped;
the script exits 1 if any step was skipped.
"""
import argparse
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "net.emillis.remote"


def adb(*args, binary=False, check=True, timeout=90):
    r = subprocess.run(["adb", *args], capture_output=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout if binary else r.stdout.decode("utf-8", errors="replace")


def sh(cmd, check=True):
    return adb("shell", cmd, check=check)


def wait_boot(seconds=600):
    end = time.time() + seconds
    while time.time() < end:
        try:
            if sh("getprop sys.boot_completed", check=False).strip() == "1" and "package:" in sh("pm path android", check=False):
                return True
        except Exception:
            pass
        time.sleep(3)
    return False


class Node:
    def __init__(self, e):
        self.text = e.get("text", "")
        self.desc = e.get("content-desc", "")
        self.rid = e.get("resource-id", "")
        self.cls = e.get("class", "")
        self.pkg = e.get("package", "")
        self.checkable = e.get("checkable") == "true"
        self.checked = e.get("checked") == "true"
        self.clickable = e.get("clickable") == "true"
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", e.get("bounds", "[0,0][0,0]"))
        self.x1, self.y1, self.x2, self.y2 = (int(v) for v in m.groups())

    @property
    def label(self):
        return f"{self.text} {self.desc}".strip()

    @property
    def area(self):
        return max(0, self.x2 - self.x1) * max(0, self.y2 - self.y1)

    def center(self):
        return (self.x1 + self.x2) // 2, (self.y1 + self.y2) // 2


class Driver:
    def __init__(self, out, lang):
        self.out = out
        self.lang = lang
        self.n = 0
        self.skipped = []
        self.last_xml = ""
        os.makedirs(os.path.join(out, "ui"), exist_ok=True)

    def dump(self):
        for _ in range(4):
            try:
                res = sh("uiautomator dump /sdcard/ui.xml", check=False)
                if "dumped" in res:
                    xml = adb("exec-out", "cat", "/sdcard/ui.xml")
                    if xml.strip().startswith("<?xml"):
                        self.last_xml = xml
                        return [Node(e) for e in ET.fromstring(xml).iter("node")]
            except Exception as e:
                print(f"ui dump failed: {e}")
            time.sleep(1.5)
        return []

    def find(self, pattern=None, rid=None, pkg=None, checkable=None, timeout=15):
        end = time.time() + timeout
        while True:
            nodes = self.dump()
            hits = []
            for n in nodes:
                if pattern and not re.search(pattern, n.label):
                    continue
                if rid and not n.rid.endswith(rid):
                    continue
                if pkg and n.pkg != pkg:
                    continue
                if checkable is not None and n.checkable != checkable:
                    continue
                if n.area == 0:
                    continue
                hits.append(n)
            if hits:
                return min(hits, key=lambda n: n.area)
            if time.time() >= end:
                return None
            time.sleep(1)

    def tap(self, node):
        x, y = node.center()
        sh(f"input tap {x} {y}")

    def swipe_up(self):
        m = re.search(r"(\d+)x(\d+)", sh("wm size"))
        w, h = int(m.group(1)), int(m.group(2))
        sh(f"input swipe {w // 2} {int(h * 0.75)} {w // 2} {int(h * 0.35)} 400")
        time.sleep(1.5)

    def find_scroll(self, tries=4, **kw):
        for _ in range(tries):
            node = self.find(**kw)
            if node:
                return node
            self.swipe_up()
        return None

    def tap_find(self, what, scroll=False, **kw):
        node = self.find_scroll(**kw) if scroll else self.find(**kw)
        if node is None:
            self.skip(f"not found: {what}")
            return False
        print(f"tap {what}: '{node.label[:60]}' at {node.center()}")
        self.tap(node)
        return True

    def skip(self, why):
        self.skipped.append(why)
        print(f"SKIPPED {why}")
        name = f"missed-{len(self.skipped):02d}-{self.lang}"
        with open(os.path.join(self.out, "ui", name + ".xml"), "w", encoding="utf-8") as f:
            f.write(self.last_xml)
        with open(os.path.join(self.out, "ui", name + ".png"), "wb") as f:
            f.write(adb("exec-out", "screencap", "-p", binary=True))

    def shot(self, step, settle=1.5):
        time.sleep(settle)
        self.n += 1
        name = f"android-{self.n:02d}-{step}-{self.lang}"
        png = adb("exec-out", "screencap", "-p", binary=True)
        with open(os.path.join(self.out, name + ".png"), "wb") as f:
            f.write(png)
        self.dump()
        with open(os.path.join(self.out, "ui", name + ".xml"), "w", encoding="utf-8") as f:
            f.write(self.last_xml)
        print(f"saved {name}.png ({len(png)} bytes)")

    def back(self):
        sh("input keyevent 4")
        time.sleep(1.5)


def set_locale(locale):
    now = sh("getprop persist.sys.locale", check=False).strip()
    print(f"locale before: '{now}'")
    if now == locale:
        return
    adb("root", check=False)
    time.sleep(3)
    adb("wait-for-device")
    sh(f"setprop persist.sys.locale {locale}")
    sh("setprop ctl.restart zygote")
    time.sleep(15)
    if not wait_boot(300):
        raise RuntimeError("the emulator did not come back after the locale change")
    time.sleep(10)
    print(f"locale after: '{sh('getprop persist.sys.locale', check=False).strip()}'")


def prepare_device():
    for key in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
        sh(f"settings put global {key} 0")
    sh("settings put global stay_on_while_plugged_in 7")
    sh("settings put system screen_off_timeout 1800000")
    sh("input keyevent 224")
    sh("wm dismiss-keyguard", check=False)
    # A tidy status bar for the manual: 9:00, full battery, full signal, no notification icons.
    sh("settings put global sysui_demo_allowed 1")
    demo = "am broadcast -a com.android.systemui.demo -e command"
    sh(f"{demo} enter", check=False)
    sh(f"{demo} clock -e hhmm 0900", check=False)
    sh(f"{demo} battery -e level 100 -e plugged false", check=False)
    sh(f"{demo} network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4", check=False)
    sh(f"{demo} notifications -e visible false", check=False)
    sh("input keyevent 3")
    time.sleep(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--locale", required=True, choices=["ko-KR", "en-US"])
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    lang = a.locale.split("-")[0]
    d = Driver(a.out, lang)

    if not wait_boot():
        raise RuntimeError("the emulator did not boot")
    set_locale(a.locale)
    print("Android", sh("getprop ro.build.version.release").strip(), "SDK", sh("getprop ro.build.version.sdk").strip(),
          "screen", sh("wm size").strip(), sh("wm density").strip())
    prepare_device()
    print(adb("install", "-r", a.apk).strip())

    # 1. First launch.
    sh(f"monkey -p {PKG} -c android.intent.category.LAUNCHER 1")
    time.sleep(20)
    d.shot("first-launch")

    # 2. The "Share screen" tab: this phone's ID and password, service not started.
    if d.tap_find("Share screen tab", pattern=r"화면 공유|Share screen"):
        d.shot("share-screen-id")

    # 3. Start service: the app's own warning first (its button unlocks after 12 seconds).
    if d.tap_find("Start service", pattern=r"^(서비스 시작|Start service)"):
        d.shot("start-warning")
        time.sleep(13)
        d.tap_find("I Agree", pattern=r"^(동의|I Agree)$", timeout=10)

    # 4. Android 13 and later: notifications.
    if d.find(rid="permission_allow_button", timeout=8):
        d.shot("permission-notifications")
        d.tap_find("Allow notifications", rid="permission_allow_button")

    # 5. Display over other apps (Android's settings page; the user turns it on and comes back).
    node = d.find(pkg="com.android.settings", checkable=True, timeout=8)
    if node:
        d.shot("permission-display-over-apps")
        d.tap(node)
        d.shot("permission-display-over-apps-on")
        d.back()

    # 6. The app's notice before the service starts.
    if d.find(pattern=r"^(확인|OK)$", pkg=PKG, timeout=10):
        d.shot("service-notice")
        d.tap_find("OK", pattern=r"^(확인|OK)$", pkg=PKG)

    # 7. Android's screen capture consent (Android 14 may first ask: one app or the entire screen).
    if d.find(pkg="com.android.systemui", timeout=10):
        d.shot("permission-screen-capture")
        spinner = d.find(rid="screen_share_mode_spinner", timeout=2)
        if spinner:
            d.tap(spinner)
            d.shot("permission-screen-capture-options")
            d.tap_find("Entire screen", pattern=r"전체 화면|[Ee]ntire screen", timeout=5)
        d.tap_find("Start now", rid="android:id/button1", timeout=5)
    else:
        d.skip("no screen capture consent appeared")
    time.sleep(4)
    d.shot("sharing-on-id", settle=3)

    # 8. Input control: the app's notice, then Android's Accessibility settings.
    if d.tap_find("Input Control", pattern=r"^(입력 제어|Input Control)"):
        d.shot("input-control-notice")
        if d.tap_find("Open System Setting", pattern=r"^(시스템 설정 열기|Open System Setting)"):
            d.shot("accessibility-list", settle=3)
            if d.tap_find("RustDesk Input in the list", scroll=True, pattern=r"RustDesk Input", pkg="com.android.settings", timeout=6):
                d.shot("accessibility-service")
                sw = d.find(pkg="com.android.settings", checkable=True, timeout=5)
                if sw:
                    d.tap(sw)
                    if d.find(pkg="com.android.settings", pattern=r"^(허용|Allow)$", timeout=5):
                        d.shot("accessibility-allow")
                        d.tap_find("Allow", pkg="com.android.settings", pattern=r"^(허용|Allow)$")
                    d.shot("accessibility-on")
                else:
                    d.skip("no switch on the RustDesk Input page")
            for _ in range(3):
                if PKG in sh("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'", check=False):
                    break
                d.back()
            sh(f"monkey -p {PKG} -c android.intent.category.LAUNCHER 1")
            d.shot("input-control-on", settle=3)

    # 9. Settings, the built-in server, and the login screen.
    if d.tap_find("Settings tab", pattern=r"^(설정|Settings)(\n|$)"):
        d.shot("settings")
        if d.tap_find("ID/Relay Server", scroll=True, pattern=r"^(ID/릴레이 서버|ID/Relay Server)", timeout=6):
            d.shot("server-settings")
            d.back()
        if d.tap_find("Login", scroll=True, pattern=r"^(로그인|Login)", timeout=6):
            d.shot("login")
            d.back()

    print(f"RESULT {d.n} screenshots, {len(d.skipped)} skipped: {d.skipped}")
    return 1 if d.skipped else 0


if __name__ == "__main__":
    sys.exit(main())
