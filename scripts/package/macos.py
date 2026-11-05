#!/usr/bin/env python3
"""A Doka.app holding every Homebrew library the binary reaches, each pointing at the others inside.
   scripts/package/macos.py zig-out/bin/doka zig-out/dist/Doka.app"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HOMEBREW = Path("/opt/homebrew")
HERE = Path(__file__).resolve().parent
FRAMEWORK_REF = "@executable_path/../Frameworks/"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def references(path):
    lines = run("otool", "-L", path).splitlines()[1:]
    names = [line.strip().split(" (")[0] for line in lines]
    own = run("otool", "-D", path).splitlines()[1:]
    return [n for n in names if n not in own]


def rpaths(path):
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", run("otool", "-l", path))


def resolve(name, source, original):
    """The real file a load command names; None for the system's own. `original` is where the file was built to live."""
    if name.startswith(("/usr/lib/", "/System/")):
        return None
    folder = str(Path(original).resolve().parent)
    if name.startswith("@loader_path/"):
        candidates = [name.replace("@loader_path", folder, 1)]
    elif name.startswith("@rpath/"):
        candidates = [name.replace("@rpath", r.replace("@loader_path", folder), 1) for r in rpaths(source)]
    else:
        candidates = [name]
    for candidate in candidates:
        if os.path.exists(candidate):
            return os.path.realpath(candidate)
    raise SystemExit(f"{original}: can't find {name}")


def relink(path, original, frameworks, queue):
    """Points the file's load commands into Frameworks, and queues what they name."""
    os.chmod(path, 0o755)
    changes = []
    for name in references(path):
        real = resolve(name, path, original)
        if real is None:
            continue
        queue.append(real)
        changes += ["-change", name, FRAMEWORK_REF + os.path.basename(real)]
    for rpath in rpaths(path):
        changes += ["-delete_rpath", rpath]
    if changes:
        run("install_name_tool", *changes, path)


def minimum_macos(path):
    versions = re.findall(r"minos (\d+(?:\.\d+)*)", run("otool", "-l", path))
    return versions[0] if versions else "0"


def main():
    binary, app = Path(sys.argv[1]), Path(sys.argv[2])
    shutil.rmtree(app, ignore_errors=True)
    macos, frameworks = app / "Contents/MacOS", app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    loaders = resources / "lib/gdk-pixbuf/loaders"
    for folder in (macos, frameworks, loaders):
        folder.mkdir(parents=True)
    shutil.copy(HERE / "Info.plist", app / "Contents/Info.plist")
    shutil.copy(HERE / "doka.icns", resources)
    shutil.copy(HERE / "macos-launcher", macos / "doka")
    os.chmod(macos / "doka", 0o755)

    queue = []
    exe = macos / "doka-bin"
    shutil.copy(binary, exe)
    relink(str(exe), str(binary), frameworks, queue)

    # GTK draws symbolic icons through gdk-pixbuf's SVG loader; JPEG and PNG it reads itself.
    cache = (HOMEBREW / "lib/gdk-pixbuf-2.0/2.10.0/loaders.cache").read_text()
    block = next(b for b in cache.split("\n\n") if "pixbufloader_svg" in b)
    svg = re.match(r'"(.+?)"', block.strip()).group(1)
    copied_svg = loaders / os.path.basename(svg)
    shutil.copy(svg, copied_svg)
    relink(str(copied_svg), svg, frameworks, queue)
    (loaders.parent / "loaders.cache").write_text(block.strip().replace(os.path.dirname(svg) + "/", "") + "\n")

    done = set()
    while queue:
        real = queue.pop()
        if real in done:
            continue
        done.add(real)
        copy = frameworks / os.path.basename(real)
        shutil.copy(real, copy)
        relink(str(copy), real, frameworks, queue)
        run("install_name_tool", "-id", FRAMEWORK_REF + copy.name, str(copy))

    # Zig stamps this machine's exact macOS on the binary; the libraries' own minimum is what counts.
    oldest = max((minimum_macos(str(f)) for f in frameworks.iterdir()), key=lambda v: [int(n) for n in v.split(".")])
    run("vtool", "-set-build-version", "macos", oldest, oldest, "-replace", "-output", str(exe), str(exe))

    share = resources / "share"
    shutil.copytree(HERE.parent.parent / "zig-out/package/looks", share / "doka/looks")
    schemas = share / "glib-2.0/schemas"
    schemas.mkdir(parents=True)
    for schema in (HOMEBREW / "share/glib-2.0/schemas").glob("org.gtk.gtk4.*.gschema.xml"):
        shutil.copy(schema, schemas)
    run("glib-compile-schemas", str(schemas))
    # gdk-pixbuf tells an SVG by its MIME type, from this database.
    (share / "mime").mkdir()
    for entry in (HOMEBREW / "share/mime").resolve().iterdir():
        if entry.is_file():
            shutil.copy(entry, share / "mime")
    theme = share / "icons/Adwaita"
    source = (HOMEBREW / "share/icons/Adwaita").resolve()
    shutil.copytree(source / "symbolic", theme / "symbolic")
    shutil.copy(source / "index.theme", theme)

    # Ad hoc: Apple Silicon won't run a changed library unsigned. Not notarized, so the first launch is right-click, Open.
    for path in [*frameworks.iterdir(), *loaders.iterdir(), exe]:
        run("codesign", "--force", "--sign", "-", str(path))
    run("codesign", "--force", "--sign", "-", str(app))
    print(f"{app}: {len(done)} libraries, macOS {oldest} or newer")


main()
