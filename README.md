# OpenWrt Podkop + AmneziaWG failover

Автоматическое резервирование двух AmneziaWG-туннелей для Podkop на OpenWrt.

Подходит для роутеров, где интернет приходит через LTE/5G (`wwand`, QMI/MBIM), Ethernet WAN/DHCP/PPPoE, Wi‑Fi uplink или любой другой uplink с рабочим IPv4 default route.

## Что делает

- основной AmneziaWG: `awg_main`;
- резервный AmneziaWG: `AWG_backup`;
- после `FAIL_LIMIT=3` ошибок основного переключает Podkop на резервный;
- после `RECOVER_LIMIT=3` успешных проверок основного возвращает Podkop на основной;
- если **оба AWG недоступны**, переводит секцию Podkop в `connection_type=block`;
- в `block` режиме домены/подсети, назначенные этой секции Podkop, **REJECT'ятся, а не уходят напрямую через WAN**;
- после восстановления любого AWG автоматически снимает блокировку;
- исправляет ранний старт Podkop/sing-box после reboot;
- работает одинаково с LTE и кабельным WAN;
- повторный запуск `install.sh` является **обновлением**: сохраняет текущие параметры, делает backup и заменяет служебные скрипты актуальной версией.

## Требования

1. OpenWrt имеет рабочий интернет.
2. Podkop установлен и настроен.
3. Два AmneziaWG-интерфейса уже созданы и каждый работает отдельно.
4. У AWG peer обычно `Allowed IPs = 0.0.0.0/0` (при необходимости `::/0`), но `Route Allowed IPs` выключено.
5. Доступны `curl`, `nslookup`, `uci`, `ubus`, `ip`.
6. Для kill switch нужна версия Podkop с `connection_type=block`. Установщик проверит это автоматически.

## Имена интерфейсов и регистр

Рекомендуемые имена:

```text
awg_main
AWG_backup
```

OpenWrt/UCI сам по себе регистрозависим. Поэтому установщик делает разрешение имён **без учёта регистра**, а затем сохраняет реальное каноническое имя UCI.

Например, все эти варианты найдут один и тот же существующий интерфейс `AWG_backup`:

```text
AWG_backup
awg_backup
AwG_BaCkUp
```

Это относится и к `MAIN_AWG`, и к `BACKUP_AWG`, и к имени секции Podkop.

Если на роутере одновременно существуют два UCI-раздела, отличающиеся только регистром, установщик остановится с ошибкой как при неоднозначной конфигурации.

## Установка/обновление с GitHub одной командой

### Если репозиторий публичный

```sh
cd /tmp && \
wget -O podkop-awg-install.sh \
https://raw.githubusercontent.com/kumshi1978/openwrt-podkop-awg-failover/main/install.sh && \
sh podkop-awg-install.sh
```

Эта же команда используется для **обновления** уже установленной версии.

Безопаснее не использовать `wget ... | sh`: сначала файл скачивается, и только потом запускается.

### Если репозиторий private

`raw.githubusercontent.com` не отдаёт private-файл без авторизации. Не рекомендуется постоянно хранить GitHub PAT на роутере.

Для постоянной установки одной командой лучше сделать этот репозиторий public, так как в нём **нет ключей и секретов**. Конфигурации с private key/PSK в репозиторий не добавлять.

## Настройка имён

Если на конкретном роутере интерфейсы называются иначе:

```sh
MAIN_AWG='Home_Main' BACKUP_AWG='Home_Backup' sh /tmp/podkop-awg-install.sh
```

Регистр можно писать произвольно.

По умолчанию:

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
KILL_SWITCH=1
APPLY_NOW=1
```

## Обновления без потери настроек

При первом запуске создаётся:

```text
/etc/podkop-awg-failover.conf
```

При повторном запуске актуального `install.sh`:

1. читаются уже сохранённые параметры;
2. параметры из командной строки/environment имеют приоритет;
3. определяется фактический регистр имён UCI;
4. создаётся backup;
5. устанавливается новая версия watchdog/late-start;
6. конфигурация применяется сразу (`APPLY_NOW=1`).

Таким образом обычное обновление:

```sh
cd /tmp && \
wget -O podkop-awg-install.sh \
https://raw.githubusercontent.com/kumshi1978/openwrt-podkop-awg-failover/main/install.sh && \
sh podkop-awg-install.sh
```

не требует заново вводить `MAIN_AWG`, `BACKUP_AWG`, тайминги и kill switch.

Чтобы установить обновление, но применить только после следующей загрузки:

```sh
APPLY_NOW=0 sh /tmp/podkop-awg-install.sh
```

## Kill switch: оба AmneziaWG упали

Нормальный режим:

```text
Podkop selected traffic
        ↓
     awg_main
```

Основной упал:

```text
Podkop selected traffic
        ↓
    AWG_backup
```

Оба упали:

```text
Podkop selected traffic
        ↓
 connection_type=block
        ↓
      REJECT
```

То есть адреса, домены и подсети, которые Podkop относит к этой секции, **не должны пробовать выйти напрямую через обычный WAN/LTE**.

Watchdog продолжает проверять оба AWG даже в режиме блокировки:

- основной восстановился `RECOVER_LIMIT` раз → `vpn → awg_main`;
- резервный восстановился `RECOVER_LIMIT` раз раньше основного → `vpn → AWG_backup`;
- позже при восстановлении основного стандартная логика вернёт трафик на `awg_main`.

Runtime-переключения `vpn ↔ block` и `main ↔ backup` выполняются **без `uci commit`**, поэтому flash не пишется при каждом событии. В постоянной конфигурации сохраняется штатное состояние `vpn + main`.

Отключить kill switch можно только явно:

```sh
KILL_SWITCH=0 sh /tmp/podkop-awg-install.sh
```

## Логика загрузки

```text
OpenWrt boot
   ↓
ждём IPv4 default route
   ↓
проверяем внешний DNS напрямую через 1.1.1.1
   ↓
Podkop = VPN через main
   ↓
restart Podkop
   ↓
проверяем sing-box + локальный DNS/FakeIP
   ↓
restart NTP
   ↓
запускаем AWG watchdog
```

Скрипт не привязан к `wan`, `LTE`, `wwan0` и т.п. Он ждёт факт появления рабочего uplink.

## Что устанавливается

```text
/etc/podkop-awg-failover.conf
/usr/bin/podkop-awg-failover
/etc/init.d/podkop-awg-failover
/usr/bin/podkop-late-start
/etc/init.d/podkop-late-start
```

`podkop-awg-failover` не включается напрямую в boot. Его запускает `podkop-late-start` только после готовности uplink, DNS и Podkop.

## Проверка

```sh
cat /etc/podkop-awg-failover.conf
logread | grep -E 'podkop-late|podkop-awg' | tail -50
ubus call service list '{"name":"sing-box"}'
ubus call service list '{"name":"podkop-awg-failover"}'
uci get podkop.main.connection_type
uci get podkop.main.interface
```

При нормальной работе:

```text
connection_type = vpn
interface       = awg_main
```

## Тест failover

Отключить основной:

```sh
ifdown awg_main
```

После трёх неудачных проверок Podkop должен перейти на `AWG_backup`.

Затем отключить и резервный:

```sh
ifdown AWG_backup
```

В логе ожидается:

```text
both AWG unavailable: enabling Podkop block mode (kill switch)
```

Проверка:

```sh
uci get podkop.main.connection_type
```

Ожидается:

```text
block
```

Вернуть основной:

```sh
ifup awg_main
```

После трёх успешных recovery-check:

```text
connection_type = vpn
interface       = awg_main
```

## Backup

Каждая установка/обновление сохраняет предыдущие служебные файлы и Podkop UCI export:

```text
/root/podkop-awg-backup-YYYYMMDD-HHMMSS/
```

## Удаление

```sh
cd /tmp && \
wget -O podkop-awg-uninstall.sh \
https://raw.githubusercontent.com/kumshi1978/openwrt-podkop-awg-failover/main/uninstall.sh && \
sh podkop-awg-uninstall.sh
```

Удаление не удаляет сами AmneziaWG-интерфейсы.

## Безопасность

Никогда не добавлять в Git:

- AmneziaWG private keys;
- preshared keys;
- полный `/etc/config/network` без очистки;
- SIM IMSI/ICCID;
- пароли/APN credentials;
- backup-конфигурации роутера с секретами.
