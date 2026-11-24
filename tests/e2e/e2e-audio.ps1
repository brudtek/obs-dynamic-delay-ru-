param([string]$Obs, [int]$Delay = 10)
# Hold-scene audio scenario against the portable test OBS created by setup_test_obs.py.
# Needs rtmp-sink.mjs running. ASCII-only: Cyrillic names come from names.json.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$here = $PSScriptRoot
$N = Get-Content -Raw -Encoding UTF8 (Join-Path $here 'names.json') | ConvertFrom-Json
$uia = Join-Path $here 'uia.ps1'
$ws = Join-Path $here 'ws.mjs'

function Ws($type, $data) {
	if ($data) { $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Compress))); $out = node $ws $type $b64 }
	else { $out = node $ws $type }
	return ($out | ConvertFrom-Json)
}
$script:t0 = Get-Date
function OutTime { [math]::Round((Ws 'GetStreamStatus').data.outputDuration / 1000.0, 2) }
function Note($msg) { Write-Host ('{0,7:N2}s  output={1,7:N2}s  {2}' -f ((Get-Date) - $script:t0).TotalSeconds, (OutTime), $msg) }
function Head { ((& $uia -Action state -Name $N.dock) -split ' \| ')[1..2] -join ' / ' }
function Click($name) { & $uia -Action invoke -Name $name | Out-Null; Note "click: $name" }
function WaitFor($needle, $timeout) {
	$deadline = (Get-Date).AddSeconds($timeout); $last = ''
	while ((Get-Date) -lt $deadline) {
		$h = Head
		if ($h -ne $last) { Note "state: $h"; $last = $h }
		if ($h -like "$needle /*") { return }
		Start-Sleep -Milliseconds 300
	}
	throw "timeout waiting for $needle"
}
function Scene($name) { Ws 'SetCurrentProgramScene' @{ sceneName = $name } | Out-Null; Note "program scene -> $name" }

# Start OBS and show the dock.
if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {
	Start-Process -FilePath "$Obs\bin\64bit\obs64.exe" -WorkingDirectory "$Obs\bin\64bit" -ArgumentList '--portable', '--disable-updater', '--disable-shutdown-check', '--disable-missing-files-check' | Out-Null
	Start-Sleep 12
}
if ((& $uia -Action state -Name $N.dock) -like 'dock not found*') {
	& $uia -Action expand -Name $N.docksMenu | Out-Null
	& $uia -Action invoke -Name $N.dock | Out-Null
	Start-Sleep 1
}
& $uia -Action slider -Name $N.dock -Depth $Delay | Out-Null
Ws 'SetInputVolume' @{ inputName = $N.tone440; inputVolumeMul = 1.0 } | Out-Null
Ws 'SetInputMute' @{ inputName = $N.tone880; inputMuted = $false } | Out-Null
Scene $N.sceneLive
Ws 'StartStream' | Out-Null
Start-Sleep 3
Note 'stream started'

Note '--- A: hold scene not in Program'
Click $N.add
WaitFor $N.stateDelayed ($Delay + 30)
Start-Sleep 2
Click $N.remove
WaitFor $N.stateLive 20
Start-Sleep 3

Note '--- B: Program switched to the hold scene before and during delay'
Scene $N.sceneHold
Start-Sleep 3
Click $N.add
WaitFor $N.stateDelayed ($Delay + 30)
Start-Sleep 2
Scene $N.sceneLive
Start-Sleep 3
Scene $N.sceneHold
Start-Sleep 2
Scene $N.sceneLive
Start-Sleep 2
Click $N.remove
WaitFor $N.stateLive 20
Start-Sleep 3

Note '--- C: after manual switches; volume and mute during hold'
Click $N.add
Start-Sleep 3
Ws 'SetInputVolume' @{ inputName = $N.tone440; inputVolumeMul = 0.5 } | Out-Null
Note 'tone 440 volume 50%'
Start-Sleep 3
Ws 'SetInputMute' @{ inputName = $N.tone880; inputMuted = $true } | Out-Null
Note 'shared 880 muted'
Start-Sleep 2
Ws 'SetInputMute' @{ inputName = $N.tone880; inputMuted = $false } | Out-Null
Note 'shared 880 unmuted'
WaitFor $N.stateDelayed ($Delay + 30)
Start-Sleep 3
Click $N.remove
WaitFor $N.stateLive 20
Ws 'SetInputVolume' @{ inputName = $N.tone440; inputVolumeMul = 1.0 } | Out-Null
Start-Sleep 3

Note '--- D: one more cycle'
Click $N.add
WaitFor $N.stateDelayed ($Delay + 30)
Start-Sleep 2
Click $N.remove
WaitFor $N.stateLive 20
Start-Sleep 2
Ws 'StopStream' | Out-Null
Note 'stream stopped'
Start-Sleep 2
Note ('dock: ' + (Head))
