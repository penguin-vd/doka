#!/usr/bin/env python3
"""Starter looks: a dozen film stocks from the RawTherapee Film Simulation Collection
(CC BY-SA 4.0; Pat David, Pavlov Dmitry, Michael Ezra), turned from Hald CLUT PNGs into 33-point
.cube files in the looks folder. Personal use is fine; the licence asks for credit and the same
licence when sharing them, so they stay out of this repository and a credits file goes beside them.

    scripts/starter-looks.py [HaldCLUT.zip] [looks folder]

Without a zip it downloads the collection (420 MB) into ~/.cache/doka/. Needs the vips command.
"""
import os
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

URL = 'https://rawtherapee.com/shared/HaldCLUT.zip'
SIZE = 33

# Hald CLUT in the zip → the look's title (and file name).
LOOKS = {
    'Color/Kodak/Kodak Portra 400 2.png': 'Kodak Portra 400',
    'Color/Kodak/Kodak Portra 160 2.png': 'Kodak Portra 160',
    'Color/Kodak/Kodak Ektar 100.png': 'Kodak Ektar 100',
    'Color/Kodak/Kodak Kodachrome 64.png': 'Kodak Kodachrome 64',
    'Color/Fuji/Fuji Velvia 50.png': 'Fuji Velvia 50',
    'Color/Fuji/Fuji Provia 100F.png': 'Fuji Provia 100F',
    'Color/Fuji/Fuji Superia 400 2.png': 'Fuji Superia 400',
    'Color/Fuji/Fuji 400H 2.png': 'Fuji Pro 400H',
    'Color/Agfa/Agfa Vista 200.png': 'Agfa Vista 200',
    'Color/Polaroid/Polaroid 669 3.png': 'Polaroid 669',
    'Black-and-White/Ilford/Ilford HP5 2.png': 'Ilford HP5',
    'Black-and-White/Kodak/Kodak TRI-X 400 2.png': 'Kodak Tri-X 400',
}

CREDITS = """Starter looks: from the RawTherapee Film Simulation Collection, version 2015-09-20.
Licence: CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).
Authors: Pat David, Pavlov Dmitry, Michael Ezra.
Converted from Hald CLUT to 33-point .cube by doka's scripts/starter-looks.py.
The film names are trademarks of their owners, used only to say which stock each look approximates.
"""


def pixels(png):
    """The PNG's RGB bytes and its size, through the vips command."""
    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, 'clut.raw')
        subprocess.run(['vips', 'rawsave', png, raw], check=True, stderr=subprocess.DEVNULL)
        width = int(subprocess.run(['vipsheader', '-f', 'width', png], check=True, capture_output=True, text=True).stdout)
        bands = int(subprocess.run(['vipsheader', '-f', 'bands', png], check=True, capture_output=True, text=True).stdout)
        with open(raw, 'rb') as f:
            return f.read(), width, bands


def cube(png, title):
    data, width, bands = pixels(png)
    level = round(width ** (1 / 3))
    n = level * level
    if level ** 3 != width or len(data) != width * width * bands:
        raise ValueError(f'{png}: not a Hald CLUT ({width} px wide)')

    def at(r, g, b, k):
        # Black-and-white ones are a single grey channel.
        return data[(r + g * n + b * n * n) * bands + (k if bands >= 3 else 0)] / 255

    def sample(x, y, z):
        # Trilinear between the Hald lattice's points.
        fx, fy, fz = x * (n - 1), y * (n - 1), z * (n - 1)
        x0, y0, z0 = int(fx), int(fy), int(fz)
        x1, y1, z1 = min(x0 + 1, n - 1), min(y0 + 1, n - 1), min(z0 + 1, n - 1)
        dx, dy, dz = fx - x0, fy - y0, fz - z0
        out = []
        for k in range(3):
            c00 = at(x0, y0, z0, k) * (1 - dx) + at(x1, y0, z0, k) * dx
            c10 = at(x0, y1, z0, k) * (1 - dx) + at(x1, y1, z0, k) * dx
            c01 = at(x0, y0, z1, k) * (1 - dx) + at(x1, y0, z1, k) * dx
            c11 = at(x0, y1, z1, k) * (1 - dx) + at(x1, y1, z1, k) * dx
            out.append((c00 * (1 - dy) + c10 * dy) * (1 - dz) + (c01 * (1 - dy) + c11 * dy) * dz)
        return out

    lines = [f'TITLE "{title}"', '# RawTherapee Film Simulation Collection, CC BY-SA 4.0: Pat David, Pavlov Dmitry, Michael Ezra',
             f'LUT_3D_SIZE {SIZE}', 'DOMAIN_MIN 0 0 0', 'DOMAIN_MAX 1 1 1']
    for b in range(SIZE):
        for g in range(SIZE):
            for r in range(SIZE):
                v = sample(r / (SIZE - 1), g / (SIZE - 1), b / (SIZE - 1))
                lines.append(f'{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}')
    return '\n'.join(lines) + '\n'


def main():
    home = os.path.expanduser('~')
    config = os.environ.get('XDG_CONFIG_HOME') or os.path.join(home, '.config')
    zip_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(home, '.cache', 'doka', 'HaldCLUT.zip')
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(config, 'doka', 'looks')
    if not os.path.exists(zip_path):
        os.makedirs(os.path.dirname(zip_path), exist_ok=True)
        print(f'downloading {URL} (420 MB)')
        urllib.request.urlretrieve(URL, zip_path)
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z, tempfile.TemporaryDirectory() as tmp:
        for member, title in LOOKS.items():
            png = os.path.join(tmp, 'clut.png')
            with open(png, 'wb') as f:
                f.write(z.read('HaldCLUT/' + member))
            target = os.path.join(out, f'{title}.cube')
            with open(target, 'w') as f:
                f.write(cube(png, title))
            print(target)
    with open(os.path.join(out, 'CREDITS.txt'), 'w') as f:
        f.write(CREDITS)


if __name__ == '__main__':
    main()
