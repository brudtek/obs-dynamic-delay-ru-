# Сквозные проверки в OBS

Проверки идут в отдельной переносной копии OBS: ваша OBS и её настройки не
затрагиваются. Нужны установленная OBS 32.2.x, Python (`py`), Node.js 22+ и
собранный плагин (`build_x64\RelWithDebInfo\obs-dynamic-delay.dll`).

## Подготовка

```powershell
$t = "$env:TEMP\obs-delay-e2e"
tests\e2e\build-analyzer.bat "$t\analyzer"
tests\e2e\build-dockstate.bat "$t\dockstate"
py -I tests\e2e\setup_test_obs.py "C:\Program Files\obs-studio" "$t\obs" build_x64\RelWithDebInfo\obs-dynamic-delay.dll data\locale\ru-RU.ini
py -I tests\e2e\make_dock_state.py "$t\obs" (& "$t\dockstate\dockstate.exe" -platform minimal 100 60 400 900)
```

`setup_test_obs.py` создаёт сцены:

| Сцена | Содержимое |
|---|---|
| «Эфир» | синий фон + «Общий тон 880» |
| «Эфир 2» | зелёный фон |
| «Вложенная» | «Тон 440» |
| «Стоп кадры» (сцена ожидания) | красный фон + сцена «Вложенная» + «Общий тон 880» |

`make_dock_state.py` открывает панель плагина плавающим окном: так ею можно
управлять через UI Automation без меню и без вывода OBS на передний план.

## Прогон

```powershell
Start-Process node -ArgumentList 'tests\e2e\rtmp-sink.mjs', "$t\streams"
tests\e2e\e2e-audio.ps1 -Obs "$t\obs" -Delay 10
& "$t\analyzer\analyze.exe" (Get-ChildItem "$t\streams\*.flv" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
```

| Сценарий | Что проверяет |
|---|---|
| `e2e-audio.ps1` | звук заглушки с общим источником; сцена ожидания в эфире до и во время задержки; громкость и отключение звука во время накопления; повторные циклы |
| `e2e-visibility.ps1` | скрытие и показ вложенной сцены внутри заглушки во время накопления |

Анализатор печатает отрезки по цвету центра кадра (красный — заглушка, синий —
«Эфир») и по звуку: амплитуды тонов 440 Гц (только в заглушке) и 880 Гц (общий
источник), а также разрывы звука и откаты меток времени. Ожидаемо: в заглушке
«440+880» с той же амплитудой 880, что и в эфире (без удвоения), в эфире — «880».

`uia.ps1`, `shot.ps1` и сценарии должны оставаться только в ASCII: Windows
PowerShell 5.1 читает файлы без BOM как ANSI. Русские названия лежат в `names.json`.
