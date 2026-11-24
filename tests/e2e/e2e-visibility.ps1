param([string]$Obs, [int]$Delay = 10)
# Hides and shows the nested scene inside the hold scene while the buffer fills.
# Expected hold audio: 440+880, then 880 only while hidden, then 440+880 again.
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
function Note($msg) { Write-Host ('output={0,7:N2}s  {1}' -f ((Ws 'GetStreamStatus').data.outputDuration / 1000.0), $msg) }
function Head { ((& $uia -Action state -Name $N.dock) -split ' \| ')[1..2] -join ' / ' }
function WaitFor($needle, $timeout) {
	$deadline = (Get-Date).AddSeconds($timeout)
	while ((Get-Date) -lt $deadline) { if ((Head) -like "$needle /*") { Note "state: $needle"; return }; Start-Sleep -Milliseconds 300 }
	throw "timeout waiting for $needle"
}
if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {
	Start-Process -FilePath "$Obs\bin\64bit\obs64.exe" -WorkingDirectory "$Obs\bin\64bit" -ArgumentList '--portable', '--disable-updater', '--disable-shutdown-check', '--disable-missing-files-check' | Out-Null
	Start-Sleep 12
}
$item = (Ws 'GetSceneItemId' @{ sceneName = $N.sceneHold; sourceName = $N.nestedScene }).data.sceneItemId
Ws 'SetCurrentProgramScene' @{ sceneName = $N.sceneLive } | Out-Null
Ws 'StartStream' | Out-Null
Start-Sleep 3
& $uia -Action invoke -Name $N.add | Out-Null
Note 'delay requested'
Start-Sleep 4
Ws 'SetSceneItemEnabled' @{ sceneName = $N.sceneHold; sceneItemId = $item; sceneItemEnabled = $false } | Out-Null
Note 'nested scene hidden in hold scene'
Start-Sleep 3
Ws 'SetSceneItemEnabled' @{ sceneName = $N.sceneHold; sceneItemId = $item; sceneItemEnabled = $true } | Out-Null
Note 'nested scene shown again'
WaitFor $N.stateDelayed ($Delay + 30)
Start-Sleep 2
& $uia -Action invoke -Name $N.remove | Out-Null
WaitFor $N.stateLive 20
Start-Sleep 2
Ws 'StopStream' | Out-Null
Note 'stream stopped'
