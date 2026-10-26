#!/usr/bin/env python3
"""Create a two-hour, ten-voice synthetic meeting using bounded memory."""
from pathlib import Path
import json
import subprocess
import wave

root = Path(__file__).resolve().parent.parent / '.local' / 'stress'
root.mkdir(parents=True, exist_ok=True)
voices = ['Alice (Italian (Italy))', 'Daniel', 'Samantha (English (US))', 'Fred', 'Albert', 'Eddy (English (US))', 'Flo (English (US))', 'Grandma (English (US))', 'Grandpa (English (US))', 'Rocko (English (US))']
turns = []
for index, voice in enumerate(voices):
    text = ('Abbiamo approvato il rilascio di venerdì. Il responsabile dei test deve verificare i risultati entro giovedì.' if index == 0 else f'This is participant number {index + 1}. We approved the release on Friday. The test owner will review the results on Thursday.')
    aiff = root / f'voice-{index}.aiff'
    wav = root / f'voice-{index}.wav'
    subprocess.run(['say', '-v', voice, '-r', '175', '-o', str(aiff), text], check=True)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(aiff), '-ar', '16000', '-ac', '1', '-af', 'apad=pad_dur=0.7', '-c:a', 'pcm_s16le', str(wav)], check=True)
    with wave.open(str(wav)) as source:
        samples = source.readframes(source.getnframes())
    turns.append((index, samples))
    print(f'Voice {index + 1}/10 ready', flush=True)
output = root / 'two-hour-ten-speakers.wav'
remaining = 7200 * 16000
position = 0
truth = []
with wave.open(str(output), 'wb') as destination:
    destination.setnchannels(1); destination.setsampwidth(2); destination.setframerate(16000)
    while remaining:
        for speaker, samples in turns:
            count = min(remaining, len(samples) // 2)
            destination.writeframesraw(samples[:count * 2])
            truth.append({'speaker': speaker, 'start': position / 16000, 'end': (position + max(0, count - 11200)) / 16000})
            remaining -= count; position += count
            if not remaining:
                break
(root / 'ground-truth.json').write_text(json.dumps(truth, indent=2))
print(output, flush=True)
