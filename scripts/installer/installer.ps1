# Установщик плагина «Управление задержкой» для OBS Studio.
#
# Без параметров показывает окно: папка установки (по умолчанию — папка
# плагинов OBS C:\ProgramData\obs-studio\plugins), кнопки «Обзор…» и
# «Установить». Подходит и папка самой OBS, например переносной: тогда файлы
# кладутся в её obs-plugins\64bit и data\obs-plugins.
# Права администратора запрашиваются, только если выбранная папка защищена.
#
#   installer.ps1                                — окно установки
#   installer.ps1 -Destination <папка> -NoDialog — установить без окна выбора
#   installer.ps1 -Uninstall -RegistryKey <ключ> — удалить (так вызывает «Приложения Windows»)
#   -Quiet — без окон сообщений (для проверки)
param(
	[switch]$Uninstall,
	[string]$Destination = '',
	[switch]$NoDialog,
	[switch]$Quiet,
	[string]$RegistryKey = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$version = '@VERSION@'
$pluginName = 'obs-dynamic-delay'
$title = "Управление задержкой для OBS $version"
$keyName = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\obs-dynamic-delay-ru'
$defaultPlugins = Join-Path $env:ProgramData 'obs-studio\plugins'

function Say([string]$text, [string]$kind = 'Information') {
	if ($Quiet) { Write-Output $text; return }
	[System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $kind) | Out-Null
}
function Ask([string]$text) {
	if ($Quiet) { return $true }
	return [System.Windows.Forms.MessageBox]::Show($text, $title, 'OKCancel', 'Warning') -eq 'OK'
}
function Test-Admin {
	([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Можно ли писать в папку (или в ближайшую существующую родительскую).
function Test-Writable([string]$path) {
	$dir = $path
	while ($dir -and -not (Test-Path $dir -PathType Container)) { $dir = Split-Path -Parent $dir }
	if (-not $dir) { return $false }
	$probe = Join-Path $dir ('.write-test-' + [guid]::NewGuid())
	try { [IO.File]::WriteAllText($probe, ''); Remove-Item -Force $probe; return $true } catch { return $false }
}

# Папка установленной OBS Studio (из реестра или стандартного места).
function Find-Obs {
	foreach ($key in 'HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio') {
		try {
			$dir = (Get-ItemProperty $key -ErrorAction Stop).'(default)'
			if ($dir -and (Test-Path (Join-Path $dir 'bin\64bit\obs64.exe'))) { return $dir }
		} catch {}
	}
	$dir = Join-Path $env:ProgramFiles 'obs-studio'
	if (Test-Path (Join-Path $dir 'bin\64bit\obs64.exe')) { return $dir }
	return $null
}

# Что и куда кладётся для выбранной папки.
function Get-Layout([string]$folder) {
	$folder = $folder.TrimEnd('\', '/')
	if (Test-Path (Join-Path $folder 'bin\64bit\obs64.exe')) {
		$data = Join-Path $folder "data\obs-plugins\$pluginName"
		return [pscustomobject]@{
			Mode = 'obs'; Root = $folder; DataDir = $data
			Dll = Join-Path $folder "obs-plugins\64bit\$pluginName.dll"
			Remove = @((Join-Path $folder "obs-plugins\64bit\$pluginName.dll"), (Join-Path $folder "obs-plugins\64bit\$pluginName.pdb"), $data)
			Uninstaller = Join-Path $data 'uninstall.ps1'
		}
	}
	$root = if ((Split-Path -Leaf $folder) -ieq $pluginName) { $folder } else { Join-Path $folder $pluginName }
	return [pscustomobject]@{
		Mode = 'plugins'; Root = $root; DataDir = Join-Path $root 'data'
		Dll = Join-Path $root "bin\64bit\$pluginName.dll"
		Remove = @($root)
		Uninstaller = Join-Path $root 'uninstall.ps1'
	}
}

# Другие известные места, где мог остаться плагин (в том числе исходный
# англоязычный OBS Dynamic Delay): OBS загрузила бы обе копии сразу.
function Get-OtherCopies($layout) {
	$candidates = @(Join-Path $defaultPlugins $pluginName)
	$obs = Find-Obs
	if ($obs) {
		$candidates += Join-Path $obs "obs-plugins\64bit\$pluginName.dll"
		$candidates += Join-Path $obs "data\obs-plugins\$pluginName"
	}
	$mine = $layout.Remove | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
	$candidates | Where-Object { (Test-Path $_) -and ($mine -notcontains [IO.Path]::GetFullPath($_).TrimEnd('\')) }
}

function Remove-Paths([string[]]$paths) {
	foreach ($path in $paths) { if (Test-Path $path) { Remove-Item -Recurse -Force $path } }
}

function Wait-ObsClosed {
	while (Get-Process obs64 -ErrorAction SilentlyContinue) {
		if ($Quiet) { throw 'OBS Studio запущена — закройте её.' }
		if (-not (Ask "Закройте OBS Studio и нажмите «ОК».`n`n«Отмена» — прервать.")) { exit 1 }
	}
}

# Перезапуск этого же сценария с правами администратора (запрос UAC).
function Invoke-Elevated([string[]]$extra) {
	$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"") + $extra
	if ($Quiet) { $arguments += '-Quiet' }
	try {
		$process = Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
		exit $process.ExitCode
	} catch {
		Say 'Для этой папки нужны права администратора, а запрос был отклонён. Выберите другую папку или разрешите запрос.' 'Error'
		exit 1
	}
}

function Show-Dialog([string]$initial, $obs) {
	$form = New-Object System.Windows.Forms.Form
	$form.Text = $title
	$form.FormBorderStyle = 'FixedDialog'
	$form.MaximizeBox = $false
	$form.MinimizeBox = $false
	$form.StartPosition = 'CenterScreen'
	$form.AutoScaleMode = 'Dpi'
	$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
	$form.ClientSize = New-Object System.Drawing.Size(560, 230)

	$heading = New-Object System.Windows.Forms.Label
	$heading.Text = 'Плагин «Управление задержкой» для OBS Studio'
	$heading.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
	$heading.SetBounds(16, 14, 528, 24)
	$form.Controls.Add($heading)

	$status = New-Object System.Windows.Forms.Label
	$status.Text = if ($obs) { "Найдена OBS Studio: $obs" } else { 'OBS Studio на этом компьютере не найдена — укажите папку вручную.' }
	$status.SetBounds(16, 44, 528, 20)
	$form.Controls.Add($status)

	$label = New-Object System.Windows.Forms.Label
	$label.Text = 'Папка установки:'
	$label.SetBounds(16, 76, 528, 18)
	$form.Controls.Add($label)

	$box = New-Object System.Windows.Forms.TextBox
	$box.Text = $initial
	$box.SetBounds(16, 96, 432, 24)
	$form.Controls.Add($box)

	$browse = New-Object System.Windows.Forms.Button
	$browse.Text = 'Обзор…'
	$browse.SetBounds(456, 95, 88, 26)
	$browse.Add_Click({
			$picker = New-Object System.Windows.Forms.FolderBrowserDialog
			$picker.Description = 'Папка плагинов OBS или папка, куда установлена OBS'
			$picker.ShowNewFolderButton = $true
			if (Test-Path $box.Text) { $picker.SelectedPath = $box.Text }
			if ($picker.ShowDialog($form) -eq 'OK') { $box.Text = $picker.SelectedPath }
		})
	$form.Controls.Add($browse)

	$hint = New-Object System.Windows.Forms.Label
	$hint.Text = "По умолчанию — общая папка плагинов OBS: подходит для обычной установки OBS.`nДля переносной OBS выберите папку, где лежит сама OBS (с подпапкой bin)."
	$hint.ForeColor = [System.Drawing.SystemColors]::GrayText
	$hint.SetBounds(16, 128, 528, 40)
	$form.Controls.Add($hint)

	$install = New-Object System.Windows.Forms.Button
	$install.Text = 'Установить'
	$install.SetBounds(352, 184, 100, 30)
	$install.DialogResult = 'OK'
	$form.Controls.Add($install)
	$form.AcceptButton = $install

	$cancel = New-Object System.Windows.Forms.Button
	$cancel.Text = 'Отмена'
	$cancel.SetBounds(460, 184, 84, 30)
	$cancel.DialogResult = 'Cancel'
	$form.Controls.Add($cancel)
	$form.CancelButton = $cancel

	$form.Add_Shown({ $install.Focus() })
	if ($form.ShowDialog() -ne 'OK') { return $null }
	return $box.Text.Trim()
}

function Get-PluginSource {
	# Файлы плагина: рядом со сценарием (распакованный архив) или в payload.zip
	# (setup.exe распаковывает его вместе со сценарием во временную папку).
	$here = Split-Path -Parent $PSCommandPath
	$source = Join-Path $here $pluginName
	if (Test-Path (Join-Path $source "bin\64bit\$pluginName.dll")) { return @{ Path = $source; Temp = $null } }
	$payload = Join-Path $here 'payload.zip'
	if (-not (Test-Path $payload)) { throw "Рядом с установщиком нет файлов плагина ($here)." }
	$temp = Join-Path ([IO.Path]::GetTempPath()) ('obs-delay-' + [guid]::NewGuid())
	Expand-Archive -Path $payload -DestinationPath $temp
	return @{ Path = (Join-Path $temp $pluginName); Temp = $temp }
}

function Install-Plugin([string]$folder) {
	if (-not $folder) { throw 'Не указана папка установки.' }
	$layout = Get-Layout $folder
	$others = @(Get-OtherCopies $layout)

	# Права администратора — только если выбранная папка или старая копия защищены.
	$needed = @($layout.Remove) + @($layout.Dll) + $others
	$blocked = $needed | Where-Object { -not (Test-Writable (Split-Path -Parent $_)) -or ((Test-Path $_) -and -not (Test-Writable $_)) }
	if ($blocked -and -not (Test-Admin)) { Invoke-Elevated @('-Destination', "`"$folder`"", '-NoDialog') }

	Wait-ObsClosed
	$src = Get-PluginSource
	try {
		$updated = Test-Path $layout.Dll
		Remove-Paths $layout.Remove
		Remove-Paths $others
		if ($layout.Mode -eq 'plugins') {
			New-Item -ItemType Directory -Force $layout.Root | Out-Null
			Copy-Item -Recurse -Force (Join-Path $src.Path '*') $layout.Root
		} else {
			New-Item -ItemType Directory -Force (Split-Path -Parent $layout.Dll), $layout.DataDir | Out-Null
			Copy-Item -Force (Join-Path $src.Path "bin\64bit\$pluginName.dll") $layout.Dll
			Copy-Item -Recurse -Force (Join-Path $src.Path 'data\*') $layout.DataDir
			Get-ChildItem $src.Path -File | Copy-Item -Destination $layout.DataDir -Force
		}
	} finally {
		if ($src.Temp) { Remove-Item -Recurse -Force $src.Temp -ErrorAction SilentlyContinue }
	}

	# Запись для удаления через «Параметры → Приложения».
	Copy-Item -Force $PSCommandPath $layout.Uninstaller
	$hive = if (Test-Admin) { 'HKLM:' } else { 'HKCU:' }
	$key = if ($RegistryKey) { $RegistryKey } else { "$hive\$keyName" }
	foreach ($old in "HKLM:\$keyName", "HKCU:\$keyName") {
		if ($old -ne $key -and (Test-Path $old)) { try { Remove-Item -Recurse -Force $old } catch {} }
	}
	if (-not (Test-Path $key)) { New-Item -Force $key | Out-Null }
	$values = [ordered]@{
		DisplayName = 'Управление задержкой для OBS'
		DisplayVersion = $version
		Publisher = 'brudtek (на основе OBS Dynamic Delay, автор Aritz)'
		InstallLocation = $layout.Root
		InstallMode = $layout.Mode
		DisplayIcon = "$env:SystemRoot\System32\imageres.dll,-1023"
		UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($layout.Uninstaller)`" -Uninstall -RegistryKey `"$key`""
		URLInfoAbout = 'https://github.com/brudtek/obs-dynamic-delay-ru-'
	}
	foreach ($name in $values.Keys) { Set-ItemProperty -Path $key -Name $name -Value $values[$name] }
	Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
	Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord

	$verb = if ($updated) { 'обновлён' } else { 'установлен' }
	$removedNote = if ($others) { "`n`nСтарая копия плагина удалена:`n" + ($others -join "`n") } else { '' }
	Say ("Плагин $verb в папку:`n$($layout.Root)$removedNote`n`n" +
		"Запустите OBS и откройте меню «Док-панели» → «Управление задержкой».`n`n" +
		"Перед эфиром: выключите встроенную задержку OBS (Настройки → Расширенные) и поставьте интервал ключевых кадров 1–2 секунды (Настройки → Вывод).")
}

function Uninstall-Plugin {
	$key = if ($RegistryKey) { $RegistryKey } elseif (Test-Path "HKLM:\$keyName") { "HKLM:\$keyName" } else { "HKCU:\$keyName" }
	$paths = @()
	if (Test-Path $key) {
		$paths = (Get-Layout (Get-ItemProperty $key).InstallLocation).Remove
	} else {
		# Записи нет (ставили вручную): ищем в стандартных местах.
		$paths = @(Join-Path $defaultPlugins $pluginName)
		$obs = Find-Obs
		if ($obs) { $paths += (Get-Layout $obs).Remove }
		$paths = $paths | Where-Object { Test-Path $_ }
	}
	$protected = @($paths) + @($key) | Where-Object { $_ -like 'HKLM:*' -or ((Test-Path $_) -and -not (Test-Writable $_)) -or ($_ -notlike 'HK*' -and -not (Test-Writable (Split-Path -Parent $_))) }
	if ($protected -and -not (Test-Admin)) {
		$extra = @('-Uninstall')
		if ($RegistryKey) { $extra += @('-RegistryKey', "`"$RegistryKey`"") }
		Invoke-Elevated $extra
	}
	Wait-ObsClosed
	if (-not $paths -and -not (Test-Path $key)) { Say 'Плагин не найден — удалять нечего.'; return }
	Remove-Paths $paths
	if (Test-Path $key) { Remove-Item -Recurse -Force $key }
	Say "Плагин удалён.`n`nНастройки остались в папке:`n$env:APPDATA\obs-studio\plugin_config\$pluginName`nЕё можно удалить вручную."
}

try {
	if ($Uninstall) { Uninstall-Plugin; exit 0 }
	$folder = $Destination
	if (-not $NoDialog) {
		$folder = Show-Dialog $(if ($Destination) { $Destination } else { $defaultPlugins }) (Find-Obs)
		if (-not $folder) { exit 1 }
	}
	Install-Plugin $folder
	exit 0
} catch {
	Say ('Не удалось: ' + $_.Exception.Message) 'Error'
	exit 1
}
