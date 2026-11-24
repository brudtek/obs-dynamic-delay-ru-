"""Writes a DockState (base64 from dockstate.exe) into the test OBS user.ini, so the plugin
dock opens as a floating window without clicking through the Docks menu.

usage: py -I make_dock_state.py <test-obs-dir> <base64-state>
"""
import os, re, sys

obs, encoded = sys.argv[1], sys.argv[2].strip()
ini = os.path.join(obs, 'config', 'obs-studio', 'user.ini')
text = open(ini, encoding='utf-8-sig').read()
text = re.sub(r'^DockState=.*\n?', '', text, flags=re.M)
text = text.replace('[BasicWindow]\n', '[BasicWindow]\nDockState=' + encoded + '\n', 1)
open(ini, 'w', encoding='utf-8').write(text)
print('dock state written')
