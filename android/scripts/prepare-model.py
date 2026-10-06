#!/usr/bin/env python3
"""Fetch the pinned official Vosk model and verify it before extracting."""
from pathlib import Path
import hashlib, subprocess, tempfile, zipfile
root=Path(__file__).resolve().parents[1]
url='https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip'
expected='30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498'
target=root/'app/src/main/assets/model-en-us'
with tempfile.TemporaryDirectory() as temp:
    archive=Path(temp)/'model.zip'
    subprocess.run(['curl','--fail','--location','--retry','2',url,'--output',str(archive)],check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=expected:raise SystemExit('Speech model checksum mismatch.')
    with zipfile.ZipFile(archive) as z:
        for entry in z.infolist():
            if entry.is_dir():continue
            parts=Path(entry.filename).parts
            if not parts or parts[0]!='vosk-model-small-en-us-0.15' or '..' in parts:raise SystemExit('Unexpected model archive path.')
            path=target.joinpath(*parts[1:]);path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(z.read(entry))
print('Verified offline model prepared.')
