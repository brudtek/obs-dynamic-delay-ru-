# Тесты

Пять наборов модульных тестов не требуют OBS SDK. Они собираются вместе с
плагином, если включить `ENABLE_TESTS`:

```powershell
cmake --preset windows-x64 -DENABLE_TESTS=ON
cmake --build build_x64 --config RelWithDebInfo
ctest --test-dir build_x64 -C RelWithDebInfo --output-on-failure
```

| Набор | Что проверяет |
|---|---|
| `output_session_tests` | Рабочий код `src/output-session.cpp`: накопление, переход к задержанному видео, возврат в прямой эфир, метки времени, освобождение пакетов. Подменены только вызовы libobs и кодировщик сцены ожидания |
| `hold_pipeline_tests` | Общий кодировщик сцены ожидания: совместное использование, пауза, отписка, ошибки запуска |
| `preview_timing_tests` | Расчёт времени для предпросмотра; приоритет «Трансляция → Запись» при любом порядке выходов |
| `audio_spsc_fifo_tests` | Очередь звука сцены ожидания |
| `packet_delay_tests` | Независимая модель ядра задержки (в DLL не входит) |

Модульные тесты не проверяют реальные кодировщики, видеокарту и драйверы —
для этого нужна проверка в OBS, см. `docs/test-report.md`.

Необязательные интеграционные программы `preview_gpu_integration` и
`output_session_integration` собираются с `ENABLE_OBS_INTEGRATION_TESTS` и
работают с настоящей libobs. `verify-recording.mjs` проверяет запись, которую
создаёт `output_session_integration` (нужны Node.js и ffprobe).
