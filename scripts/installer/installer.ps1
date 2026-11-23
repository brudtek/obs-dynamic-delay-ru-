# Установка и удаление плагина «Управление задержкой» для OBS Studio.
# Копирует плагин в C:\ProgramData\obs-studio\plugins\obs-dynamic-delay —
# туда, откуда OBS сама подгружает сторонние плагины.
#   installer.ps1              — установить (или обновить)
#   installer.ps1 -Uninstall   — удалить
# -Target, -RegistryKey и -Quiet нужны только для проверки без окон и без прав администратора.
param(
	[switch]$Uninstall,
	[string]$Target = '',
	[switch]$Quiet,
	[string]$RegistryKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\obs-dynamic-delay-ru'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$title = 'Управление задержкой для OBS'
$pluginName = 'obs-dynamic-delay'
$version = '@VERSION@'
$customTarget = [bool]$Target
if (-not $Target) { $Target = Join-Path $env:ProgramData "obs-studio\plugins\$pluginName" }

function Say([string]$text, [string]$kind = 'Information') {
	if ($Quiet) { Write-Output $text; return }
	[System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $kind) | Out-Null
}
function Ask([string]$text) {
	if ($Quiet) { return $true }
	return [System.Windows.Forms.MessageBox]::Show($text, $title, 'OKCancel', 'Warning') -eq 'OK'
}

# Для записи в ProgramData нужны права администратора: перезапускаемся с запросом UAC.
if (-not $customTarget) {
	$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	if (-not $admin) {
		$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
		if ($Uninstall) { $arguments += '-Uninstall' }
		try {
			$process = Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
			exit $process.ExitCode
		} catch {
			Say 'Без прав администратора установить плагин нельзя: Windows не даёт писать в папку плагинов OBS.' 'Error'
			exit 1
		}
	}
}

try {
	# OBS должна быть закрыта, иначе DLL занята и не заменится.
	while (Get-Process obs64 -ErrorAction SilentlyContinue) {
		if (-not (Ask "Закройте OBS Studio и нажмите «ОК».`n`n«Отмена» — прервать.")) { exit 1 }
		if ($Quiet) { throw 'OBS запущена.' }
	}

	if ($Uninstall) {
		if (Test-Path $RegistryKey) { Remove-Item -Recurse -Force $RegistryKey }
		if (Test-Path $Target) {
			Remove-Item -Recurse -Force $Target
			Say "Плагин удалён.`n`nНастройки остались в папке:`n$env:APPDATA\obs-studio\plugin_config\$pluginName`nЕё можно удалить вручную."
		} else {
			Say "Плагин не найден, удалять нечего:`n$Target"
		}
		exit 0
	}

	# Где лежат файлы плагина: рядом со сценарием (распакованный архив) или
	# в payload.zip (однофайловый установщик .exe распаковывает его во временную папку).
	$here = Split-Path -Parent $PSCommandPath
	$source = Join-Path $here $pluginName
	$temp = $null
	if (-not (Test-Path (Join-Path $source 'bin\64bit\obs-dynamic-delay.dll'))) {
		$payload = Join-Path $here 'payload.zip'
		if (-not (Test-Path $payload)) { throw "Не найдены файлы плагина рядом с установщиком ($here)." }
		$temp = Join-Path ([IO.Path]::GetTempPath()) ("obs-delay-" + [guid]::NewGuid())
		Expand-Archive -Path $payload -DestinationPath $temp
		$source = Join-Path $temp $pluginName
	}

	$obsInstalled = (Test-Path 'HKLM:\SOFTWARE\OBS Studio') -or (Test-Path "$env:ProgramFiles\obs-studio\bin\64bit\obs64.exe")
	if (-not $obsInstalled -and -not $customTarget) {
		if (-not (Ask "OBS Studio на этом компьютере не найдена.`nВсё равно установить плагин?")) { exit 1 }
	}

	# Старая копия (в том числе исходный англоязычный OBS Dynamic Delay) заменяется целиком.
	$updated = Test-Path $Target
	if ($updated) { Remove-Item -Recurse -Force $Target }
	New-Item -ItemType Directory -Force $Target | Out-Null
	Copy-Item -Recurse -Force (Join-Path $source '*') $Target
	if ($temp) { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }

	# Копия установщика в папке плагина — для удаления через «Параметры → Приложения».
	$uninstaller = Join-Path $Target 'uninstall.ps1'
	Copy-Item -Force $PSCommandPath $uninstaller
	if (-not (Test-Path $RegistryKey)) { New-Item -Force $RegistryKey | Out-Null }
	$uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstaller`" -Uninstall"
	if ($customTarget) { $uninstallCommand += " -Target `"$Target`" -RegistryKey `"$RegistryKey`"" }
	$entries = [ordered]@{
		DisplayName = 'Управление задержкой для OBS'
		DisplayVersion = $version
		Publisher = 'brudtek (на основе OBS Dynamic Delay, автор Aritz)'
		InstallLocation = $Target
		UninstallString = $uninstallCommand
		URLInfoAbout = 'https://github.com/brudtek/obs-dynamic-delay-ru-'
	}
	foreach ($name in $entries.Keys) { Set-ItemProperty -Path $RegistryKey -Name $name -Value $entries[$name] }
	Set-ItemProperty -Path $RegistryKey -Name NoModify -Value 1 -Type DWord
	Set-ItemProperty -Path $RegistryKey -Name NoRepair -Value 1 -Type DWord

	# Копия плагина в папке самой OBS конфликтовала бы с установленной.
	$stray = "$env:ProgramFiles\obs-studio\obs-plugins\64bit\obs-dynamic-delay.dll"
	$warning = ''
	if (-not $customTarget -and (Test-Path $stray)) {
		$warning = "`n`nВнимание: в папке OBS есть ещё одна копия плагина:`n$stray`nУдалите её, иначе OBS загрузит не ту версию."
	}

	$verb = if ($updated) { 'обновлён' } else { 'установлен' }
	Say ("Плагин $verb.`n`nЗапустите OBS и откройте меню «Док-панели» → «Управление задержкой».`n`n" +
		"Перед эфиром: выключите встроенную задержку OBS (Настройки → Расширенные) и поставьте интервал ключевых кадров 1–2 секунды (Настройки → Вывод)." + $warning)
	exit 0
} catch {
	Say ("Не удалось: " + $_.Exception.Message) 'Error'
	exit 1
}
