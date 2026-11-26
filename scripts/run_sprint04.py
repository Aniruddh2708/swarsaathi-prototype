"""Fixed development excerpts only; retain per-label diagnostics and print summaries."""
import hashlib, json, subprocess, sys, zipfile
from pathlib import Path
archive,binary,dest=map(Path,sys.argv[1:4])
dest.mkdir(parents=True,exist_ok=True)
def run(mode,*args):
    return json.loads(subprocess.check_output([str(binary),mode,*map(str,args)],text=True))
def write(name,obj):
    (dest/(name+".json")).write_text(json.dumps(obj,indent=2,sort_keys=True))
with zipfile.ZipFile(archive) as z:
    for track in range(1,7):
        stem=f"vocadito_{track}"
        wav=[n for n in z.namelist() if Path(n).name==stem+".wav"]
        csv=[n for n in z.namelist() if Path(n).name==stem+"_f0.csv"]
        if len(wav)!=1 or len(csv)!=1: raise ValueError(stem)
        a,b=dest/(stem+".wav"),dest/(stem+".csv")
        a.write_bytes(z.read(wav[0])); b.write_bytes(z.read(csv[0]))
        print("S04_FIXTURE",stem,hashlib.sha256(a.read_bytes()).hexdigest(),hashlib.sha256(b.read_bytes()).hexdigest(),flush=True)
        result=run("attribution",a,b)
        write(stem+"-attribution",result)
        del result["events"]
        print("S04_ATTRIBUTION",stem,json.dumps(result,separators=(",",":")),flush=True)
        if track in [3,5]:
            mixture=run("mixture",a,b)
            write(stem+"-mixture",mixture)
            print("S04_MIXTURE",stem,json.dumps(mixture,separators=(",",":")),flush=True)
        a.unlink(); b.unlink()
synthetic=run("synthetic")
write("synthetic-mixture",synthetic)
print("S04_MIXTURE synthetic",json.dumps(synthetic,separators=(",",":")),flush=True)
