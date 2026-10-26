#!/usr/bin/env python3
"""Build and sign a local native macOS application without extra project generators."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
parser.add_argument('--launch', action='store_true')
args = parser.parse_args()
subprocess.run(['swift', 'build', '-c', args.configuration, '--product', 'MeetingAssistant'], cwd=ROOT, check=True)
result = subprocess.check_output(['swift', 'build', '-c', args.configuration, '--show-bin-path'], cwd=ROOT, text=True)
binary_dir = Path(result.strip().splitlines()[-1])
app = ROOT / 'dist' / 'Meeting Assistant.app'
if app.exists():
    shutil.rmtree(app)
macos = app / 'Contents' / 'MacOS'
resources = app / 'Contents' / 'Resources'
macos.mkdir(parents=True)
resources.mkdir(parents=True)
shutil.copy2(binary_dir / 'MeetingAssistant', macos / 'MeetingAssistant')
for bundle in binary_dir.glob('*.bundle'):
    shutil.copytree(bundle, resources / bundle.name)
iconset = ROOT / '.build' / 'MeetingAssistant.iconset'
iconset.mkdir(parents=True, exist_ok=True)
png = ROOT / '.build' / 'icon-1024.png'
subprocess.run(['swift', str(ROOT / 'scripts' / 'CreateIcon.swift'), str(png)], check=True)
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        subprocess.run(['sips', '-z', str(size * scale), str(size * scale), str(png), '--out', str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
info = {
    'CFBundleName': 'Meeting Assistant', 'CFBundleDisplayName': 'Meeting Assistant',
    'CFBundleIdentifier': 'com.ottavio.meeting-assistant', 'CFBundleExecutable': 'MeetingAssistant',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1',
    'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '15.0',
    'LSApplicationCategoryType': 'public.app-category.productivity',
    'NSHighResolutionCapable': True,
    'NSMicrophoneUsageDescription': 'Meeting Assistant registra la tua voce e le riunioni in presenza per trascriverle sul Mac.',
    'NSAudioCaptureUsageDescription': 'Meeting Assistant registra l’audio della riunione selezionata per trascriverlo sul Mac.',
    'NSScreenCaptureUsageDescription': 'Meeting Assistant conserva screenshot e, se abilitato, video della sorgente che scegli.',
}
info['MeetingAssistantSourceRevision'] = subprocess.check_output(['git', 'describe', '--always', '--dirty'], cwd=ROOT, text=True).strip()
with (app / 'Contents' / 'Info.plist').open('wb') as file:
    plistlib.dump(info, file)
identity = os.environ.get('MEETING_CODESIGN_IDENTITY', '')
if not identity:
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    match = re.search(r'\b([0-9A-F]{40})\s+"Apple Development:', identities)
    identity = match.group(1) if match else '-'
subprocess.run(['codesign', '--force', '--sign', identity, '--entitlements', str(ROOT / 'scripts' / 'MeetingAssistant.entitlements'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
if args.launch:
    subprocess.run(['open', str(app)], check=True)
