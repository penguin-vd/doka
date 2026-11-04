#!/usr/bin/env python3
"""Click-a-subject's download: ONNX Runtime (MIT, Microsoft) and MobileSAM (Apache-2.0; ONNX export
by Acly, MIT) into ~/.config/doka/models/. About 56 MB. Optional: the app works without them, and
loads them only when a subject is first asked for. Every file is checked against its checksum.

    scripts/subject-model.py [models folder]
"""
import hashlib
import os
import sys
import tarfile
import tempfile
import urllib.request

ORT_VERSION = '1.31.1'
ORT_URL = f'https://github.com/microsoft/onnxruntime/releases/download/v{ORT_VERSION}/onnxruntime-linux-x64-{ORT_VERSION}.tgz'
ORT_SHA256 = 'c849e36a1ef3e22d4ff217b9d1ce4a3cf5b9467b975610913ae959ad5b16bdc9'
MODEL_URL = 'https://huggingface.co/Acly/MobileSAM/resolve/main/'
MODELS = {
    'mobile_sam_image_encoder.onnx': '580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749',
    'sam_mask_decoder_multi.onnx': '8976b90a87ba50a6a72217a5ff994f7d25ce16f2229fcc1ed259e1294c622ffe',
}
CREDITS = """ONNX Runtime: Copyright (c) Microsoft Corporation, MIT License.
MobileSAM: Chaoning Zhang et al., Apache License 2.0 (https://github.com/ChaoningZhang/MobileSAM).
Segment Anything's mask decoder: Meta Platforms, Apache License 2.0.
ONNX export: https://huggingface.co/Acly/MobileSAM, MIT License.
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, want, to):
    print(f'downloading {url}')
    partial = to + '.partial'
    urllib.request.urlretrieve(url, partial)
    got = sha256(partial)
    if got != want:
        os.remove(partial)
        sys.exit(f'{url}: checksum {got}, expected {want}; nothing installed')
    os.replace(partial, to)


def main():
    home = os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config')
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(home, 'doka', 'models')
    os.makedirs(folder, exist_ok=True)
    for name, want in MODELS.items():
        path = os.path.join(folder, name)
        if not (os.path.exists(path) and sha256(path) == want):
            fetch(MODEL_URL + name, want, path)
    library = os.path.join(folder, 'libonnxruntime.so')
    if not os.path.exists(library):
        with tempfile.TemporaryDirectory() as tmp:
            archive = os.path.join(tmp, 'ort.tgz')
            fetch(ORT_URL, ORT_SHA256, archive)
            member = f'onnxruntime-linux-x64-{ORT_VERSION}/lib/libonnxruntime.so.{ORT_VERSION}'
            with tarfile.open(archive) as tar, open(library + '.partial', 'wb') as out:
                out.write(tar.extractfile(member).read())
            os.chmod(library + '.partial', 0o755)
            os.replace(library + '.partial', library)
    with open(os.path.join(folder, 'CREDITS.txt'), 'w') as f:
        f.write(CREDITS)
    print(f'click-a-subject is ready: {folder}')


main()
