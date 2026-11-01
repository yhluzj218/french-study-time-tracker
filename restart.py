"""Restart only the explicitly installed FrenchStudyTimeTracker processes."""
import os
from pathlib import Path
import signal
import sys
import subprocess
import time

allowed={str(Path.home()/'Applications/FrenchStudyTimeTracker.app/Contents/MacOS/FrenchStudyTimeTracker'),str(Path(__file__).resolve().parent/'build/FrenchStudyTimeTracker.app/Contents/MacOS/FrenchStudyTimeTracker')}
result=subprocess.run(['pgrep','-f','/FrenchStudyTimeTracker.app/Contents/MacOS/FrenchStudyTimeTracker'],capture_output=True,text=True)
stopped=[]
for raw in result.stdout.splitlines():
    pid=int(raw)
    command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
    if command in allowed:
        os.kill(pid,signal.SIGTERM)
        stopped.append(pid)
for _ in range(50):
    alive=[]
    for pid in stopped:
        try: os.kill(pid,0);alive.append(pid)
        except ProcessLookupError: pass
    if not alive: break
    time.sleep(0.1)
else:
    raise SystemExit('Timer is still stopping; installation is preserved, please retry restart.')
launch=['open','-a',str(Path.home()/'Applications/FrenchStudyTimeTracker.app')]
if '--reset-timer' in sys.argv:
    launch += ['--args','--reset-timer']
subprocess.run(launch,check=True)
print('Restarted installed French study timer with the existing saved ledger.')
