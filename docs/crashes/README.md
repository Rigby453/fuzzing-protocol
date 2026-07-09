# Найденные крэши

## Crash 000 — Segmentation Fault (SIGSEGV)

**Файл:** crash_000_sigsegv.bin  
**Сигнал:** sig:11 (SIGSEGV)  
**Операция AFL:** flip1 (переворот 1 бита) на позиции 41  
**Воспроизводится:** да

### Как воспроизвести

```bash
~/Desktop/n2n/build_afl/supernode -p 7654 -f &
sleep 2
python3 scripts/replay_seed.py docs/crashes/crash_000_sigsegv.bin 127.0.0.1 7654
```

### Описание

Supernode падает с SIGSEGV при получении пакета с повреждённым битом на позиции 41.
Позиция 41 находится в payload после заголовка n2n_common_t (26 байт) — в поле регистрации edge.
Вероятная причина: разыменование невалидного указателя при парсинге пакета REGISTER_SUPER.
