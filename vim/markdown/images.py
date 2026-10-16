#!/usr/bin/env python3
"""Copy clipboard/imported images beside a Markdown document without overwriting files."""

import argparse
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


MAX_IMAGE = 20 * 1024 * 1024


def image_type(data):
    if not data or len(data) > MAX_IMAGE:
        raise ValueError('image is empty or exceeds 20 MiB')
    if data.startswith(b'\x89PNG\r\n\x1a\n') and len(data) >= 33 and data[12:16] == b'IHDR':
        return '.png'
    if data.startswith(b'\xff\xd8\xff'):
        return '.jpg'
    if data[:6] in (b'GIF87a', b'GIF89a'):
        return '.gif'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return '.webp'
    raise ValueError('clipboard does not contain a supported PNG/JPEG/GIF/WebP image')


def save_image(data, directory, folder='imgs', name=''):
    extension = image_type(data)
    directory = Path(directory).resolve()
    folder_path = Path(folder)
    target = (directory / folder_path).resolve()
    if folder_path.is_absolute() or directory not in target.parents:
        raise ValueError('image folder must stay inside the document directory')
    if name and (Path(name).name != name or not re.fullmatch(r'[\w .-]+', name)):
        raise ValueError('image name must be a plain filename')
    stem = Path(name).stem if name else datetime.now().strftime('image-%Y%m%d-%H%M%S')
    if stem in {'', '.', '..'}:
        raise ValueError('invalid image filename')
    target.mkdir(parents=True, exist_ok=True)
    for index in range(10000):
        filename = stem + (f'-{index}' if index else '') + extension
        path = target / filename
        try:
            with path.open('xb') as stream:
                stream.write(data)
            return {'path': str(path), 'relative': path.relative_to(directory).as_posix(),
                    'name': filename}
        except FileExistsError:
            continue
    raise ValueError('too many images with the same name; choose another filename')


def clipboard_image(command=None):
    commands = []
    if command:
        commands.append((command, False))
    else:
        powershell = shutil.which('powershell.exe') or shutil.which('powershell')
        if powershell:
            script = ('Add-Type -AssemblyName System.Windows.Forms; '
                      '$image=[System.Windows.Forms.Clipboard]::GetImage(); '
                      'if ($null -eq $image) {exit 1}; '
                      '$buffer=New-Object System.IO.MemoryStream; '
                      '$image.Save($buffer,[System.Drawing.Imaging.ImageFormat]::Png); '
                      '[Console]::Write([Convert]::ToBase64String($buffer.ToArray())); '
                      '$image.Dispose(); $buffer.Dispose()')
            commands.append(([powershell, '-NoLogo', '-NoProfile', '-NonInteractive',
                              '-STA', '-Command', script], True))
        if os.environ.get('WAYLAND_DISPLAY') and shutil.which('wl-paste'):
            commands.append((['wl-paste', '--no-newline', '--type', 'image/png'], False))
        if os.environ.get('DISPLAY') and shutil.which('xclip'):
            commands.append((['xclip', '-selection', 'clipboard', '-t', 'image/png', '-o'], False))
        if shutil.which('pngpaste'):
            commands.append((['pngpaste', '-'], False))
    errors = []
    for arguments, encoded in commands:
        try:
            result = subprocess.run(arguments, capture_output=True, timeout=8, check=True)
            data = base64.b64decode(result.stdout, validate=True) if encoded else result.stdout
            image_type(data)
            return data
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            errors.append(str(error))
    raise ValueError('no clipboard image provider succeeded; use the preview paste button over SSH'
                     + (': ' + '; '.join(errors)[:200] if errors else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--folder', default='imgs')
    parser.add_argument('--name', default='')
    parser.add_argument('--file')
    parser.add_argument('--command-json')
    args = parser.parse_args()
    try:
        command = json.loads(args.command_json) if args.command_json else None
        if command is not None and (not isinstance(command, list) or not command
                                    or not all(isinstance(item, str) for item in command)):
            raise ValueError('clipboard command must be an argument array')
        data = Path(args.file).read_bytes() if args.file else clipboard_image(command)
        print(json.dumps(save_image(data, args.directory, args.folder, args.name), ensure_ascii=False))
    except (OSError, ValueError) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
