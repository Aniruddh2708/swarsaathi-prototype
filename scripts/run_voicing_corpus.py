"""Evaluate fixed additional public development excerpts; no label editing."""
import json, re, subprocess, sys, zipfile
from pathlib import Path
archive, binary, dest = map(Path,sys.argv[1:4])
dest.mkdir(parents=True,exist_ok=True)
modes = ["baseline","level-aware","adaptive-gate","bounded-normalization"]
failed = []
with zipfile.ZipFile(archive) as z:
    names = z.namelist()
    for track in range(2,7):
        try:
            # Exact track names; require unique matches, never choose by result.
            stem = f"vocadito_{track}"
            wav = [n for n in names if Path(n).name == stem+".wav"]
            csv = [n for n in names if Path(n).name == stem+"_f0.csv"]
            if len(wav)!=1 or len(csv)!=1:
                raise ValueError(f"expected unique WAV/F0 CSV, got {wav}, {csv}")
            a,b=dest/(stem+".wav"),dest/(stem+".csv")
            a.write_bytes(z.read(wav[0])); b.write_bytes(z.read(csv[0]))
            import hashlib
            print("FIXTURE",stem,hashlib.sha256(a.read_bytes()).hexdigest(),hashlib.sha256(b.read_bytes()).hexdigest(),flush=True)
            for mode in modes:
                p=subprocess.run([str(binary),str(a),str(b),mode],text=True,capture_output=True)
                if p.returncode: raise RuntimeError(p.stderr.strip())
                result=json.loads(p.stdout)
                print("CORPUS_RESULT",stem,json.dumps(result,separators=(",",":")),flush=True)
        except Exception as e:
            failed.append(stem)
            print("CORPUS_BLOCKED",stem,str(e),flush=True)
print("CORPUS_COMPLETION",json.dumps({"requested":5,"complete":5-len(failed),"blocked":failed}),flush=True)
if failed: sys.exit(1)
