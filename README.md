# OpenWrt Podkop + AmneziaWG failover

Автоматическое резервирование двух AmneziaWG-туннелей для Podkop на OpenWrt.

Подходит для роутеров, где интернет приходит через:

- LTE/5G (`wwand`, QMI/MBIM и т.п.);
- обычный Ethernet WAN/DHCP/PPPoE;
- Wi‑Fi uplink;
- любой другой uplink, который создаёт рабочий IPv4 default route.

Скрипт **не привязан к имени WAN/LTE-интерфейса**. Он ждёт рабочий default route и внешний DNS, затем восстанавливает Podkop/sing-box и запускает AWG failover.

## Что должно быть настроено заранее

1. OpenWrt работает и имеет интернет.
2. Podkop установлен и настроен.
3. Созданы два независимых интерфейса AmneziaWG в `Network → Interfaces`.
4. Оба AWG должны работать отдельно.
5. У AWG peer обычно: `Allowed IPs = 0.0.0.0/0` (и при необходимости `::/0`), но **Route Allowed IPs выключено**, чтобы они не перехватывали default route OpenWrt.
6. `curl`, `nslookup`, `uci`, `ubus` доступны.

Пример имён:

- основной: `awg_main`
- резервный: `AWG_backup`
- секция Podkop: `main`

Проверка:

```sh
uci show network | grep -i -E 'awg|amnezia'
uci show podkop
awg show
curl -4 --interface awg_main --max-time 15 https://ifconfig.me/ip
curl -4 --interface AWG_backup --max-time 15 https://ifconfig.me/ip
```

## Установка

Скопируйте `install.sh` на роутер, затем:

```sh
chmod +x install.sh
MAIN_AWG='awg_main' BACKUP_AWG='AWG_backup' PODKOP_SECTION='main' ./install.sh
```

Если имена именно такие, достаточно:

```sh
./install.sh
```

Настраиваемые переменные:

```text
MAIN_AWG=awg_main
BACKUP_AWG=AWG_backup
PODKOP_SECTION=main
CHECK_HOST=ifconfig.me
CHECK_INTERVAL=20
FAIL_LIMIT=3
RECOVER_LIMIT=3
STARTUP_GRACE=15
UPLINK_WAIT=180
PODKOP_RETRIES=3
```

## Что устанавливается

- `/usr/bin/podkop-awg-failover` — watchdog двух AWG;
- `/etc/init.d/podkop-awg-failover` — procd-сервис watchdog;
- `/usr/bin/podkop-late-start` — исправляет ранний старт Podkop после reboot;
- `/etc/init.d/podkop-late-start` — однократный late-start;
- `/etc/podkop-awg-failover.conf` — параметры.

`podkop-awg-failover` **не включается напрямую в автозапуск**. Его запускает `podkop-late-start` только после готовности uplink и Podkop/sing-box.

## Логика загрузки

```text
OpenWrt boot
   ↓
ждём IPv4 default route
   ↓
проверяем внешний DNS напрямую через 1.1.1.1
   ↓
restart Podkop
   ↓
проверяем sing-box + локальный DNS/FakeIP
   ↓
restart NTP
   ↓
запускаем AWG watchdog
```

Это устраняет распространённую гонку загрузки, когда Podkop/sing-box стартует раньше LTE или кабельного WAN и падает с ошибками вроде `missing default interface` / `no route to internet`.

## Логика failover

Watchdog проверяет **не handshake**, а реальный HTTPS через конкретный AWG-интерфейс.

Норма:

```text
Podkop → awg_main
```

После 3 последовательных ошибок основного, если backup проходит проверку:

```text
Podkop → AWG_backup
```

Когда основной снова проходит 3 последовательные проверки:

```text
Podkop → awg_main
```

Временное переключение выполняется `uci set` **без `uci commit`**, чтобы не писать flash при каждом failover. Постоянным интерфейсом после установки остаётся основной.

## Проверка после reboot

Подождите 2–3 минуты:

```sh
logread | grep -E 'podkop-late|podkop-awg' | tail -40
ubus call service list '{"name":"sing-box"}'
ubus call service list '{"name":"podkop-awg-failover"}'
uci get podkop.main.interface
nslookup google.com 127.0.0.1
awg show | grep -E 'interface:|latest handshake|transfer:'
```

Ожидаемый лог:

```text
podkop-late: default route is ready
podkop-late: external DNS is available
podkop-late: restarting Podkop, attempt 1/3
podkop-late: Podkop and sing-box are ready
podkop-late: NTP restarted
podkop-late: AWG failover watchdog started
podkop-late: late-start completed successfully
podkop-awg: watchdog started: main=... backup=... active=main
podkop-awg: startup grace: waiting 15 seconds
podkop-awg: startup grace finished, monitoring started
```

## Тест реального failover

```sh
ifdown awg_main
```

Примерно через 60–90 секунд:

```sh
logread | grep podkop-awg | tail -20
uci get podkop.main.interface
```

Должно переключиться на backup.

Вернуть основной:

```sh
ifup awg_main
```

После трёх успешных recovery-check Podkop должен вернуться на основной.

## LTE и кабельный WAN

Отдельные версии скрипта не нужны.

Для LTE скрипт ждёт появления обычного IPv4 default route после регистрации модема.

Для кабельного WAN ждёт default route, полученный DHCP/PPPoE/static-конфигурацией.

Главное — uplink должен существовать **вне AWG**, а endpoint-адреса обоих AWG должны маршрутизироваться через реальный WAN/LTE.

## Резервная копия

При каждой установке существующие файлы скрипта сохраняются в:

```text
/root/podkop-awg-backup-YYYYMMDD-HHMMSS/
```

Также сохраняется `uci export podkop`.

## Удаление

```sh
chmod +x uninstall.sh
./uninstall.sh
```

Удаление не трогает сами AWG-интерфейсы и конфигурацию Podkop, кроме остановки созданных сервисов.

## Безопасность

Никогда не коммитьте в Git:

- AmneziaWG private keys;
- preshared keys;
- полные `/etc/config/network` с ключами;
- SIM IMSI/ICCID;
- пароли/APN credentials;
- экспорт конфигурации роутера без очистки секретов.

`.gitignore` закрывает типичные локальные файлы секретов, но это не заменяет проверку перед commit.
