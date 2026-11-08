#!/usr/bin/env python3
"""Gamepad-only walkthrough of a -D handheld -D pf_diag MBHaxe build.

Creates a virtual Xbox 360 identity pad through /dev/uinput (no keyboard or mouse device
exists in the run), starts the game, and drives it from the game's "[diag]" stdout lines:
main menu -> Help & Options -> Video Options -> Ok -> Back -> Single Player -> Beginner ->
Play (level start) -> Start (pause) -> Restart -> Start (pause) -> Main Menu -> Yes -> Quit. Every step is confirmed from the game's own state log,
and screenshots are requested through MBHAXE_SHOT_REQ. The quit must end the process with
exit status 0.

The pad mirrors the PocketForge A133 pad's application identity: "TRIMUI Player1", USB
045e:028e version 0x0110 (SDL GUID 030000005e0400008e02000010010000, mapped by SDL's stock
Xbox 360 entry), with no L3/R3, digital L2/R2 (ABS_Z/ABS_RZ at 0 or 255) and a hat d-pad.
Guide (BTN_MODE) is advertised, as on the device, but never pressed: the system owns it.

Needs write access to /dev/uinput (a logind seat ACL is enough; no root) and a display the
game can open (for example a private headless weston). Linux only.

usage: gamepad_walkthrough.py --game-dir DIR --shot-dir DIR [--log FILE] [--timeout S]
       [--env NAME=VALUE ...] [-- command ...]
The default command is ./marblegame in --game-dir.
"""
import argparse
import fcntl
import os
import queue
import re
import struct
import subprocess
import sys
import threading
import time

# linux/input-event-codes.h
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN = {"A": 0x130, "B": 0x131, "X": 0x133, "Y": 0x134, "LB": 0x136, "RB": 0x137,
       "BACK": 0x13A, "START": 0x13B, "GUIDE": 0x13C}
ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11
AXES = [(ABS_X, 0, 4095, 2048), (ABS_Y, 0, 4095, 2048), (ABS_Z, 0, 255, 0),
        (ABS_RX, 0, 4095, 2048), (ABS_RY, 0, 4095, 2048), (ABS_RZ, 0, 255, 0),
        (ABS_HAT0X, -1, 1, 0), (ABS_HAT0Y, -1, 1, 0)]

# linux/uinput.h
def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord("U") << 8) | nr
UI_DEV_CREATE = _ioc(0, 1, 0)
UI_DEV_DESTROY = _ioc(0, 2, 0)
UI_DEV_SETUP = _ioc(1, 3, 92)       # struct uinput_setup
UI_ABS_SETUP = _ioc(1, 4, 28)       # struct uinput_abs_setup
UI_SET_EVBIT = _ioc(1, 100, 4)
UI_SET_KEYBIT = _ioc(1, 101, 4)
UI_SET_ABSBIT = _ioc(1, 103, 4)

NAME, BUS_USB, VENDOR, PRODUCT, VERSION = b"TRIMUI Player1", 0x03, 0x045E, 0x028E, 0x0110


class UinputPad:
    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for ev in (EV_KEY, EV_ABS, EV_SYN):
            fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
        for code in BTN.values():
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        for code, lo, hi, val in AXES:
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
            fcntl.ioctl(self.fd, UI_ABS_SETUP, struct.pack("<HH6i", code, 0, val, lo, hi, 0, 0, 0))
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("<4H80sI", BUS_USB, VENDOR, PRODUCT, VERSION, NAME, 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def _emit(self, etype, code, value):
        t = time.time()
        os.write(self.fd, struct.pack("<qqHHi", int(t), int((t % 1) * 1e6), etype, code, value))

    def _sync(self):
        self._emit(EV_SYN, SYN_REPORT, 0)

    def press(self, name, hold=0.12):
        """Press and release a button, a trigger (LT/RT, digital) or a d-pad direction."""
        if name in BTN:
            self._emit(EV_KEY, BTN[name], 1); self._sync(); time.sleep(hold)
            self._emit(EV_KEY, BTN[name], 0); self._sync()
        elif name in ("LT", "RT"):
            code = ABS_Z if name == "LT" else ABS_RZ
            self._emit(EV_ABS, code, 255); self._sync(); time.sleep(hold)
            self._emit(EV_ABS, code, 0); self._sync()
        else:
            code, val = {"UP": (ABS_HAT0Y, -1), "DOWN": (ABS_HAT0Y, 1),
                         "LEFT": (ABS_HAT0X, -1), "RIGHT": (ABS_HAT0X, 1)}[name]
            self._emit(EV_ABS, code, val); self._sync(); time.sleep(hold)
            self._emit(EV_ABS, code, 0); self._sync()

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


class Game:
    def __init__(self, cmd, cwd, env, log_path, shot_dir):
        self.lines = queue.Queue()
        self.log = open(log_path, "w")
        self.shot_dir = shot_dir
        self.req = os.path.join(shot_dir, ".shot-request")
        env = dict(env, MBHAXE_SHOT_DIR=shot_dir, MBHAXE_SHOT_REQ=self.req)
        self.proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.log.write(line); self.log.flush()
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)

    def wait_for(self, *patterns, timeout):
        """Wait until every pattern has matched a line (in any order)."""
        pending = [re.compile(p) for p in patterns]
        end = time.time() + timeout
        while time.time() < end:
            try:
                line = self.lines.get(timeout=0.2)
            except queue.Empty:
                continue
            if line is None:
                raise RuntimeError(f"game exited (rc={self.proc.wait()}) while waiting for {[p.pattern for p in pending]}")
            pending = [p for p in pending if not p.search(line)]
            if not pending:
                return
        raise RuntimeError(f"timed out after {timeout}s waiting for {[p.pattern for p in pending]}")

    def shot(self, name, timeout=30):
        with open(self.req + ".tmp", "w") as f:
            f.write(name + "\n")
        os.rename(self.req + ".tmp", self.req)
        self.wait_for(r"\[diag\] screenshot .*/" + re.escape(name) + r"\.png", timeout=timeout)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game-dir", required=True)
    ap.add_argument("--shot-dir", required=True)
    ap.add_argument("--log", default=None)
    ap.add_argument("--timeout", type=float, default=120, help="per-step timeout, seconds")
    ap.add_argument("--env", action="append", default=[], help="NAME=VALUE for the game")
    ap.add_argument("cmd", nargs="*")
    a = ap.parse_args()
    os.makedirs(a.shot_dir, exist_ok=True)
    env = dict(os.environ)
    for kv in a.env:
        k, v = kv.split("=", 1)
        env[k] = v
    cmd = a.cmd or [os.path.join(os.path.abspath(a.game_dir), "marblegame")]
    log = a.log or os.path.join(a.shot_dir, "walkthrough-game.log")
    T = a.timeout

    def step(msg):
        print(f"[walk] {time.strftime('%H:%M:%S')} {msg}", flush=True)

    pad = UinputPad()
    step(f"virtual pad created: {NAME.decode()} {VENDOR:04x}:{PRODUCT:04x} v{VERSION:04x}")
    time.sleep(1.0)  # let udev publish the event node before SDL scans
    game = Game(cmd, a.game_dir, env, log, a.shot_dir)
    rc = None
    try:
        game.wait_for(r"\[diag\] gui gui\.MainMenuGui at", timeout=T)
        time.sleep(2.0)
        game.shot("01-main-menu"); step("main menu")
        for _ in range(3):                               # -> Help & Options
            pad.press("DOWN"); time.sleep(0.3)
        pad.press("A")
        game.wait_for(r"\[diag\] gui gui\.OptionsListGui at", timeout=T)
        time.sleep(1.0); game.shot("01a-options"); step("help & options")
        for _ in range(3):                               # -> Video Options
            pad.press("DOWN"); time.sleep(0.3)
        pad.press("A")
        game.wait_for(r"\[diag\] gui gui\.VideoOptionsGui at", timeout=T)
        time.sleep(1.0); game.shot("01b-video-options"); step("video options")
        pad.press("A")                                   # Ok (applies settings)
        game.wait_for(r"\[diag\] gui gui\.OptionsListGui at", timeout=T)
        time.sleep(0.5)
        pad.press("B")                                   # Back
        game.wait_for(r"\[diag\] gui gui\.MainMenuGui at", timeout=T)
        time.sleep(1.0)
        pad.press("A")                                   # Single Player Game (first entry)
        game.wait_for(r"\[diag\] gui gui\.DifficultySelectGui at", timeout=T)
        time.sleep(1.0); game.shot("02-difficulty"); step("difficulty select")
        pad.press("A")                                   # Beginner Levels
        game.wait_for(r"\[diag\] gui gui\.LevelSelectGui at", timeout=T)
        time.sleep(2.0); game.shot("03-level-select"); step("level select")
        pad.press("A")                                   # Play
        game.wait_for(r"\[diag\] world ready ", timeout=T)
        step("level started"); time.sleep(6.0); game.shot("04-level-start")
        pad.press("START")
        game.wait_for(r"\[diag\] world ready paused", r"\[diag\] gui .*ExitGameDlg", timeout=T)
        time.sleep(1.0); game.shot("05-paused"); step("paused")
        pad.press("DOWN"); time.sleep(0.4)               # Resume -> Restart
        pad.press("A")
        game.wait_for(r"\[diag\] world restarted", r"\[diag\] world ready (?!paused)", timeout=T)
        step("restarted"); time.sleep(1.5); game.shot("06-restarted")
        pad.press("START")
        game.wait_for(r"\[diag\] world ready paused", timeout=T)
        time.sleep(1.0)
        for _ in range(5):                               # Resume -> ... -> Main Menu (6th entry)
            pad.press("DOWN"); time.sleep(0.3)
        time.sleep(0.5); game.shot("07-pause-main-menu-selected")
        pad.press("A")
        game.wait_for(r"\[diag\] gui .*MessageBoxYesNoDlg", timeout=T)
        time.sleep(0.5); game.shot("08-confirm-exit")
        pad.press("A")                                   # Yes
        game.wait_for(r"\[diag\] world none", r"\[diag\] gui gui\.MainMenuGui at", timeout=T)
        step("back at main menu"); time.sleep(2.0)
        pad.press("UP"); time.sleep(0.5)                 # wraps from the first entry to the last: Quit
        game.shot("09-quit-selected")
        pad.press("A")
        rc = game.proc.wait(timeout=T)
        step(f"game exited rc={rc}")
    except Exception as e:
        step(f"FAIL: {e}")
        if game.proc.poll() is None:
            game.proc.terminate()
            try:
                game.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                game.proc.kill()
        return 1
    finally:
        pad.close()
    ok = rc == 0
    step("PASS" if ok else f"FAIL: exit status {rc}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
