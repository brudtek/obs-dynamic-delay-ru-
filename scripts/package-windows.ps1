# Собирает комплект для установки, символы отладки и архив исходников из уже
# собранного build_x64\RelWithDebInfo. Запуск из корня репозитория:
#   powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$spec = Get-Content -Raw (Join-Path $root 'buildspec.json') | ConvertFrom-Json
$version = $spec.version
$dll = Join-Path $root 'build_x64\RelWithDebInfo\obs-dynamic-delay.dll'
$pdb = Join-Path $root 'build_x64\RelWithDebInfo\obs-dynamic-delay.pdb'
if (-not (Test-Path $dll)) { throw "Нет $dll — сначала соберите проект." }

$release = Join-Path $root 'release'
New-Item -ItemType Directory -Force $release | Out-Null

# Архив с прямыми косыми в путях: так его одинаково открывают Проводник, 7-Zip и другие.
function New-Zip([string]$Path, [object[]]$Entries) {
	if (Test-Path $Path) { Remove-Item -Force $Path }
	$archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
	try {
		foreach ($entry in $Entries) {
			[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $entry[0], $entry[1], [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
		}
	} finally { $archive.Dispose() }
}

# Комплект: распаковать папку obs-dynamic-delay в C:\ProgramData\obs-studio\plugins\
$plugin = @(
	, @($dll, 'obs-dynamic-delay/bin/64bit/obs-dynamic-delay.dll')
	, @((Join-Path $root 'data\locale\ru-RU.ini'), 'obs-dynamic-delay/data/locale/ru-RU.ini')
	, @((Join-Path $root 'LICENSE'), 'obs-dynamic-delay/LICENSE')
	, @((Join-Path $root 'README.md'), 'obs-dynamic-delay/README.md')
	, @((Join-Path $root 'docs\install.md'), 'obs-dynamic-delay/УСТАНОВКА.md')
)
foreach ($license in Get-ChildItem (Join-Path $root 'data\licenses') -File) {
	$plugin += , @($license.FullName, "obs-dynamic-delay/data/licenses/$($license.Name)")
}
New-Zip (Join-Path $release "obs-dynamic-delay-$version-ru-windows-x64.zip") $plugin

if (Test-Path $pdb) {
	New-Zip (Join-Path $release "obs-dynamic-delay-$version-ru-windows-x64-symbols.zip") @(, @($pdb, 'obs-dynamic-delay.pdb'))
}

# Исходники — все файлы рабочей копии, которые git отслеживает или не
# исключает через .gitignore (без build_x64, .deps и release).
$files = git -C $root -c core.quotepath=off ls-files --cached --others --exclude-standard |
	Where-Object { Test-Path (Join-Path $root $_) -PathType Leaf }
$source = @()
foreach ($file in $files) { $source += , @((Join-Path $root $file), "obs-dynamic-delay-$version-ru/$file") }
New-Zip (Join-Path $release "obs-dynamic-delay-$version-ru-source.zip") $source

Get-ChildItem $release -Filter '*.zip' | ForEach-Object {
	'{0}  {1}' -f (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower(), $_.Name
} | Set-Content -Encoding ascii (Join-Path $release 'SHA256SUMS.txt')
Get-Content (Join-Path $release 'SHA256SUMS.txt')
