"""Creates an isolated portable OBS for end-to-end tests of the delay plugin.

usage: py -I setup_test_obs.py <installed-obs-dir> <target-dir> <plugin.dll> <ru-RU.ini>

Scenes:
  «Эфир»       — blue background + «Общий тон 880» (shared source)
  «Эфир 2»     — green background
  «Вложенная»  — «Тон 440» (exists only inside the hold scene)
  «Стоп кадры» — red background + nested scene «Вложенная» + «Общий тон 880» (hold scene)
Streaming goes to a local RTMP sink (rtmp-sink.mjs), obs-websocket listens on 127.0.0.1:4466.
"""
import json, math, os, shutil, struct, sys, uuid, wave

obs_dir, target, dll, locale = sys.argv[1:5]
if os.path.exists(target):
    shutil.rmtree(target)
shutil.copytree(obs_dir, target)
open(os.path.join(target, 'portable_mode.txt'), 'w').close()
# OBS derives the module name (and its data folder) from the DLL file name.
shutil.copy2(dll, os.path.join(target, 'obs-plugins', '64bit', 'obs-dynamic-delay.dll'))
locale_dir = os.path.join(target, 'data', 'obs-plugins', 'obs-dynamic-delay', 'locale')
os.makedirs(locale_dir, exist_ok=True)
shutil.copy2(locale, locale_dir)

media = os.path.join(target, 'media')
os.makedirs(media)
def tone(path, freq, amp):
    w = wave.open(path, 'wb')
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    frames = bytearray()
    for i in range(48000 * 2):  # exactly 880 and 440 whole cycles in 2 s: seamless loop
        v = int(amp * 32767 * math.sin(2 * math.pi * freq * i / 48000))
        frames += struct.pack('<hh', v, v)
    w.writeframes(bytes(frames)); w.close()
tone(os.path.join(media, 'tone440.wav'), 440, 0.30)
tone(os.path.join(media, 'tone880.wav'), 880, 0.20)

cfg = os.path.join(target, 'config', 'obs-studio')
def write(rel, text):
    path = os.path.join(cfg, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)

rec = os.path.join(target, 'rec').replace('\\', '\\\\')
os.makedirs(os.path.join(target, 'rec'))
write('global.ini', '[General]\nMaxLogs=20\nEnableAutoUpdates=false\nLastUpdateCheck=4102444800\nLastVersion=537001986\n\n[Video]\nRenderer=Direct3D 11\n')
write('user.ini', '[General]\nPre19Defaults=false\nPre21Defaults=false\nPre23Defaults=false\nPre24.1Defaults=false\nConfirmOnExit=false\nFirstRun=false\n\n[BasicWindow]\nSysTrayEnabled=false\n\n[Basic]\nProfile=Test\nProfileDir=Test\nSceneCollection=Test\nSceneCollectionFile=Test.json\nConfigOnNewProfile=false\n')
write('basic/profiles/Test/basic.ini', f'[General]\nName=Test\n\n[Video]\nBaseCX=1280\nBaseCY=720\nOutputCX=1280\nOutputCY=720\nFPSType=0\nFPSCommon=30\n\n[Output]\nMode=Advanced\n\n[AdvOut]\nEncoder=obs_x264\nApplyServiceSettings=false\nTrackIndex=1\nRecType=Standard\nRecEncoder=none\nRecFilePath={rec}\nRecFormat2=mkv\nRecTracks=1\nTrack1Bitrate=160\n\n[Audio]\nSampleRate=48000\nChannelSetup=Stereo\n')
write('basic/profiles/Test/streamEncoder.json', json.dumps({'bitrate': 2500, 'keyint_sec': 1, 'preset': 'veryfast', 'rate_control': 'CBR', 'profile': 'high'}))
write('basic/profiles/Test/service.json', json.dumps({'type': 'rtmp_custom', 'settings': {'server': 'rtmp://127.0.0.1:19350/live', 'key': 'test', 'use_auth': False, 'bwtest': False}}))
write('plugin_config/obs-websocket/config.json', json.dumps({'alerts_enabled': False, 'auth_required': False, 'first_load': False, 'server_enabled': True, 'server_password': '', 'server_port': 4466}))

ids = {}
def uid(name):
    ids.setdefault(name, str(uuid.uuid5(uuid.NAMESPACE_URL, 'obs-delay-test/' + name)))
    return ids[name]
def color(name, argb):
    return {'id': 'color_source_v3', 'versioned_id': 'color_source_v3', 'name': name, 'uuid': uid(name),
            'settings': {'color': argb, 'width': 1280, 'height': 720}}
def media_source(name, file):
    return {'id': 'ffmpeg_source', 'versioned_id': 'ffmpeg_source', 'name': name, 'uuid': uid(name),
            'settings': {'local_file': os.path.join(media, file), 'looping': True, 'restart_on_activate': False,
                         'close_when_inactive': False, 'is_local_file': True},
            'mixers': 255, 'volume': 1.0, 'muted': False, 'monitoring_type': 0}
def scene(name, children):
    items = [{'name': c, 'source_uuid': uid(c), 'visible': True, 'id': i + 1, 'pos': {'x': 0, 'y': 0},
              'scale': {'x': 1, 'y': 1}, 'align': 5, 'bounds_type': 0} for i, c in enumerate(children)]
    return {'id': 'scene', 'versioned_id': 'scene', 'name': name, 'uuid': uid(name),
            'settings': {'id_counter': len(children), 'custom_size': False, 'items': items}}

collection = {
    'name': 'Test', 'current_scene': 'Эфир', 'current_program_scene': 'Эфир', 'current_transition': 'Cut',
    'transition_duration': 300,
    'scene_order': [{'name': n} for n in ['Эфир', 'Эфир 2', 'Вложенная', 'Стоп кадры']],
    'sources': [
        color('Синий фон', 4294901760), color('Зелёный фон', 4278255360), color('Красный фон', 4278190335),
        media_source('Тон 440', 'tone440.wav'), media_source('Общий тон 880', 'tone880.wav'),
        scene('Эфир', ['Синий фон', 'Общий тон 880']),
        scene('Эфир 2', ['Зелёный фон']),
        scene('Вложенная', ['Тон 440']),
        scene('Стоп кадры', ['Красный фон', 'Вложенная', 'Общий тон 880']),
    ],
    'transitions': [],
}
write('basic/scenes/Test.json', json.dumps(collection, ensure_ascii=False, indent=2))
write('plugin_config/obs-dynamic-delay/settings.json',
      json.dumps({'delay_seconds': 10, 'hold_scene_uuid': uid('Стоп кадры'), 'hold_audio_mode': 0, 'preview_expanded': False}))
print('test OBS ready:', target)
