"""Add the game to Steam as a non-Steam game, for Big Picture and the Steam Deck: an entry in every Steam user's
config/shortcuts.vdf (Steam's binary key-value format), the one Steam's own "Add a Non-Steam Game" writes. An entry with
the same executable is replaced, not doubled. Steam reads the file when it starts, so a running Steam shows the game
after a restart. The start screen's Tools page runs it (ui/launcher/launcher_tools.cpp).

The format, from Steam's files themselves: a map is 0x00 <name> NUL <entries> 0x08, a string 0x01 <name> NUL <value>
NUL, a 32-bit integer 0x02 <name> NUL <4 bytes LE>, a 64-bit one 0x07 <name> NUL <8 bytes LE>. The appid Steam derives
for a shortcut is crc32(exe + name) with the top bit set.

Steam's Gaming Mode (a Steam Deck, Bazzite) shows a non-Steam game by its library images, a grey tile without them, and
its icon from the "icon" field, which Steam cannot take from a Linux executable (the AppImage). So each user's
config/grid/ gets the port's own images, drawn by tools/build/icon.py (the chequered flag on a blue rounded square, no
art of the game) on the start screen's dark tones: the portrait capsule <appid>p.png (600x900), the wide one
<appid>.png (920x430), the hero <appid>_hero.png (1920x620), the logo <appid>_logo.png and the icon <appid>_icon.png,
which "icon" names. An image already there (the player's own, SteamGridDB's) is kept.

Prints one line for the start screen: "done <users> <running 0|1>", or "error <code> <detail>" (code: nosteam, io).

Usage: python tools/prepare/steam.py add --name "Mario Kart World" --exe <program> --dir <its folder>
"""

import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "build"))
import icon  # noqa: E402  (tools/build/icon.py: the port's logo)

TOP, BOTTOM = (30, 35, 46), (15, 17, 24)  # the start screen's dark blue-grey, lighter at the top
LOGO = 320  # pixels of the logo drawn once and placed on every image


def steam_dir() -> Path | None:
    if os.name == "nt":
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
                return Path(winreg.QueryValueEx(k, "SteamPath")[0])
        except OSError:
            return None
    home = Path.home()
    for d in (
        home / ".steam/steam",
        home / ".local/share/Steam",
        home / ".var/app/com.valvesoftware.Steam/.local/share/Steam",
    ):
        if (d / "userdata").is_dir():
            return d
    return None


def steam_running(steam: Path) -> bool:
    if os.name == "nt":
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam\ActiveProcess") as k:
                return bool(winreg.QueryValueEx(k, "pid")[0])
        except OSError:
            return False
    pid = steam.parent / "steam.pid" if steam.name == "steam" else Path.home() / ".steam/steam.pid"
    try:
        os.kill(int(pid.read_text().strip()), 0)
        return True
    except OSError, ValueError:
        return False


def read_map(b: bytes, i: int) -> tuple[dict, int]:
    out: dict = {}
    while b[i] != 0x08:
        t, i = b[i], i + 1
        end = b.index(0, i)
        key, i = b[i:end].decode("utf-8", "replace"), end + 1
        if t == 0x00:
            out[key], i = read_map(b, i)
        elif t == 0x01:
            end = b.index(0, i)
            out[key], i = b[i:end].decode("utf-8", "replace"), end + 1
        elif t == 0x02:
            out[key], i = struct.unpack_from("<i", b, i)[0], i + 4
        elif t == 0x07:
            out[key], i = ("u64", struct.unpack_from("<Q", b, i)[0]), i + 8
        else:
            raise ValueError(f"unknown type {t} at {i}")
    return out, i + 1


def write_map(m: dict) -> bytes:
    out = bytearray()
    for k, v in m.items():
        name = k.encode() + b"\0"
        if isinstance(v, dict):
            out += b"\x00" + name + write_map(v)
        elif isinstance(v, tuple):
            out += b"\x07" + name + struct.pack("<Q", v[1])
        elif isinstance(v, int):
            out += b"\x02" + name + struct.pack("<i", v)
        else:
            out += b"\x01" + name + str(v).encode() + b"\0"
    return bytes(out + b"\x08")


def png(w: int, h: int, rows: bytes, alpha: bool) -> bytes:
    """A PNG of rows that each start with filter byte 0, RGB or RGBA."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    head = struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def tile(w: int, h: int, logo: bytes | None) -> bytes:
    """An opaque w x h image: the dark gradient, the logo (icon.render rows, LOGO wide) blended in at the centre."""
    out = bytearray()
    x0, y0 = (w - LOGO) // 2, (h - LOGO) // 2
    for y in range(h):
        t = y / max(h - 1, 1)
        row = bytearray(bytes(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) * w)
        ly = y - y0
        if logo and 0 <= ly < LOGO:
            src = logo[ly * (LOGO * 4 + 1) + 1 : (ly + 1) * (LOGO * 4 + 1)]
            for x in range(LOGO):
                r, g, b, a = src[x * 4 : x * 4 + 4]
                if a:
                    o = (x0 + x) * 3
                    row[o : o + 3] = bytes((c * a + d * (255 - a)) // 255 for c, d in zip((r, g, b), row[o : o + 3]))
        out += b"\0" + row
    return bytes(out)


def write_art(grid: Path, appid: int) -> Path:
    """The library images and the icon in grid/ for a shortcut's appid, each only when absent; the icon's path."""
    grid.mkdir(parents=True, exist_ok=True)
    files = {
        f"{appid}p.png": (600, 900, True),
        f"{appid}.png": (920, 430, True),
        f"{appid}_hero.png": (1920, 620, False),
    }
    logo = None
    for name, (w, h, with_logo) in files.items():
        if not (grid / name).exists():
            if with_logo and logo is None:
                logo = icon.render(LOGO, 2)
            write_new(grid / name, png(w, h, tile(w, h, logo if with_logo else None), False))
    for name in (f"{appid}_logo.png", f"{appid}_icon.png"):
        if not (grid / name).exists():
            logo = logo or icon.render(LOGO, 2)
            write_new(grid / name, png(LOGO, LOGO, logo, True))
    return grid / f"{appid}_icon.png"


def write_new(path: Path, data: bytes) -> None:
    tmp = path.with_suffix(".part")
    tmp.write_bytes(data)
    tmp.replace(path)


def add(vdf: Path, name: str, exe: str, start_dir: str, icon_path: str = "") -> None:
    root = read_map(vdf.read_bytes(), 0)[0] if vdf.is_file() and vdf.stat().st_size else {}
    rows = list(root.get("shortcuts", {}).values())
    quoted = f'"{exe}"'
    rows = [r for r in rows if r.get("Exe", r.get("exe")) != quoted]  # replaced, not doubled
    appid = zlib.crc32((quoted + name).encode()) | 0x80000000
    rows.append({
        "appid": struct.unpack("<i", struct.pack("<I", appid))[0], "AppName": name, "Exe": quoted,
        "StartDir": f'"{start_dir}"', "icon": icon_path or exe, "ShortcutPath": "", "LaunchOptions": "", "IsHidden": 0,
        "AllowDesktopConfig": 1, "AllowOverlay": 1, "OpenVR": 0, "Devkit": 0, "DevkitGameID": "",
        "DevkitOverrideAppID": 0, "LastPlayTime": 0, "FlatpakAppID": "", "tags": {},
    })  # fmt: skip
    data = b"\x00shortcuts\x00" + write_map({str(i): r for i, r in enumerate(rows)}) + b"\x08"
    tmp = vdf.with_suffix(".vdf.part")
    tmp.write_bytes(data)
    tmp.replace(vdf)  # never a half-written file Steam would drop every shortcut from


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("--name", required=True)
    a.add_argument("--exe", required=True)
    a.add_argument("--dir", required=True)
    args = ap.parse_args()
    steam = steam_dir()
    users = [u for u in (steam / "userdata").iterdir() if u.name.isdigit() and u.name != "0"] if steam else []
    if not users:
        print("error nosteam", flush=True)
        sys.exit(1)
    try:
        for u in users:
            (u / "config").mkdir(exist_ok=True)
            appid = zlib.crc32((f'"{args.exe}"' + args.name).encode()) | 0x80000000
            art = write_art(u / "config/grid", appid)
            add(u / "config/shortcuts.vdf", args.name, args.exe, args.dir, str(art))
    except (OSError, ValueError) as e:
        print("error io", e, flush=True)
        sys.exit(1)
    print("done", len(users), int(steam_running(steam)), flush=True)


if __name__ == "__main__":
    main()
