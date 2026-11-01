"""Install the reviewed app into the owner's Applications and login agents."""
from pathlib import Path
import datetime
import os
import plistlib
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parent
source=root/'build/FrenchStudyTimeTracker.app'
target=Path.home()/'Applications/FrenchStudyTimeTracker.app'
agent=Path.home()/'Library/LaunchAgents/org.frenchstudytracker.app.plist'
if not (source/'Contents/MacOS/FrenchStudyTimeTracker').is_file():
    raise SystemExit('Build the app first')
target.parent.mkdir(parents=True,exist_ok=True)
agent.parent.mkdir(parents=True,exist_ok=True)
if target.exists():
    backup=target.with_name('FrenchStudyTimeTracker.backup-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.app')
    target.rename(backup)
shutil.copytree(source,target)
configuration={'Label':'org.frenchstudytracker.app','ProgramArguments':[str(target/'Contents/MacOS/FrenchStudyTimeTracker')],'RunAtLoad':True,'KeepAlive':False,'ProcessType':'Interactive'}
with agent.open('wb') as f:
    plistlib.dump(configuration,f)
os.chmod(agent,0o600)
if '--restart' in sys.argv:
    restart=[sys.executable,str(root/'restart.py')]
    if '--reset-timer' in sys.argv:
        restart.append('--reset-timer')
    subprocess.run(restart,check=True)
else:
    print('Installed app and login launch agent. Existing running timer has not been interrupted.')
