#!/usr/bin/env python3
"""Generate explicit synthetic meeting evidence without recording private audio."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent / '.local' / 'fixtures'
root.mkdir(parents=True, exist_ok=True)
turns = [
    ('Alice (Italian (Italy))', 'Buongiorno, sono Marta. Abbiamo deciso di rilasciare la nuova versione venerdì. Luca preparerà i test entro giovedì. Il budget approvato è di duemila euro.'),
    ('Daniel', 'I am Luca. I agree with the release on Friday. I will finish the tests by Thursday. The main open question is whether the customer has approved the new interface.'),
    ('Alice (Italian (Italy))', 'Perfetto Luca. Mi occupo io di chiedere la conferma al cliente domani. Non abbiamo ancora deciso se attivare la nuova funzionalità per tutti gli utenti.'),
    ('Daniel', 'The feature flag will remain disabled until the customer confirms. We should document the deployment procedure and review the error logs after launch.'),
]
files = []
for index, (voice, text) in enumerate(turns):
    aiff = root / f'turn-{index}.aiff'
    wav = root / f'turn-{index}.wav'
    subprocess.run(['say', '-v', voice, '-r', '170', '-o', str(aiff), text], check=True)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(aiff), '-ar', '16000', '-ac', '1', '-af', 'apad=pad_dur=1', str(wav)], check=True)
    files.append(wav)
manifest = root / 'concat.txt'
manifest.write_text(''.join(f"file '{file}'\n" for file in files))
output = root / 'bilingual-meeting.wav'
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(manifest), '-c:a', 'pcm_s16le', str(output)], check=True)
(root / 'ground-truth.txt').write_text('\n\n'.join(f'{voice}: {text}' for voice, text in turns))
print(output)
