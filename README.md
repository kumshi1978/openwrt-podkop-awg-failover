# OpenWrt Podkop + AmneziaWG failover

Автоматическое резервирование двух AmneziaWG-туннелей для Podkop на OpenWrt.

Текущая версия: **1.2.3**.

Подходит для роутеров, где интернет приходит через LTE/5G (`wwand`, QMI/MBIM), Ethernet WAN/DHCP/PPPoE, Wi‑Fi uplink или любой другой uplink с рабочим IPv4 default route.

## Что делает

- основной AmneziaWG: `awg_main`;
- резервный AmneziaWG: `AWG_backup`;
- после `FAIL_LIMIT=3` ошибок основного переключает Podkop на резервный;
- после `RECOVER_LIMIT=3` успешных проверок основного возвращает Podkop на основной;
- если **оба AWG недоступны**, входит в `hold`-состояние: Podkop остаётся в `connection_type=vpn` и остаётся привязан к последнему выбранному AWG-интерфейсу;
- в `hold` Podkop и sing-box не перезапускаются, локальный FakeIP DNS продолжает работать, обычный WAN/LTE остаётся доступным, а выбранный Podkop-трафик остаётся fail-closed и не должен автоматически уходить напрямую через WAN;
- после восстановления любого AWG watchdog автоматически выходит из `hold`;
- исправляет ранний старт Podkop/sing-box после reboot;
- работает одинаково с LTE и кабельным WAN;
- повторный запуск `install.sh` является **обновлением**: сохраняет текущие параметры, делает backup и заменяет служебные скрипты актуальной версией.

## Почему v1.2.0 не использует `connection_type=block`

В v1.1.0 при отказе обоих AWG использовался `connection_type=block`. На реальном тестовом роутере Podkop в этом режиме не создавал outbound `main-out`, но remote rule-set'ы sing-box продолжали ссылаться на `download_detour: main-out`. В результате sing-box завершался с ошибкой `download detour not found: main-out`, а локальный DNS переставал отвечать.

В v1.2.0 этот механизм удалён. Вместо него используется `hold`: Podkop остаётся в обычном `vpn`-режиме и привязан к недоступному AWG. Проверка на тестовом роутере показала, что обычный интернет при этом продолжает работать через WAN/LTE, FakeIP DNS остаётся жив, а соединения выбранных Podkop-доменов завершаются ошибкой привязанного интерфейса (`no such network interface`) вместо fallback на WAN.

## Изменения после v1.2.0

### v1.2.1

Исправлено определение UCI-секций без учёта регистра на OpenWrt/BusyBox-сборках, где POSIX-классы символов для `tr` могут работать некорректно. Вместо `tr '[:upper:]' '[:lower:]'` используется совместимый ASCII-вариант `tr 'A-Z' 'a-z'`.

Это позволяет, например, при значении по умолчанию `AWG_backup` корректно найти реально существующую UCI-секцию `awg_backup`.

### v1.2.3

Boot-проверка готовности DNS больше не привязана к прямому запросу конкретного публичного DNS-сервера. `podkop-late-start` проверяет обычное системное разрешение имени:

```sh
nslookup openwrt.org
```

Это важно для сетей, где прямые DNS-запросы к `8.8.8.8`/`1.1.1.1` блокируются или перенаправляются, а DNS провайдера через штатный resolver OpenWrt работает нормально.

## Требования

1. OpenWrt имеет рабочий интернет.
2. Podkop установлен и настроен.
3. Два AmneziaWG-интерфейса уже созданы и каждый работает отдельно.
4. У AWG peer обычно `Allowed IPs = 0.0.0.0/0` (при необходимости `::/0`), но `Route Allowed IPs` выключено.
5. Доступны `curl`, `nslookup`, `uci`, `ubus`, `ip`.

## Протестированные платформы

Функциональные тесты выполнялись на реальных роутерах, включая переключение main → backup, отказ обоих AWG с `hold/fail-closed`, восстановление, сохранение конфигурации при обновлении и cold boot:

- **Cudy TR3000 256 MB — OpenWrt 25.12.5** (`r33051-f5dae5ece4`);
- **Cudy TR3000 v1 — OpenWrt 24.10.7** (`r29197-ab4c7d6af7`).

На OpenWrt 24.10.7 отдельно подтверждена совместимость case-insensitive поиска UCI-секций с BusyBox и корректная boot-проверка через системный DNS.

Это не означает, что пакет ограничен этими двумя версиями OpenWrt: они перечислены как фактически протестированные конфигурации.

## Имена интерфейсов и регистр

Рекомендуемые имена:

```text
awg_main
AWG_backup
```

OpenWrt/UCI регистрозависим. Установщик разрешает имена **без учёта регистра**, а затем сохраняет фактическое каноническое имя UCI.

Например, `AWG_backup`, `awg_backup` и `AwG_BaCkUp` найдут один существующий интерфейс `AWG_backup`. Это относится и к `MAIN_AWG`, и к `BACKUP_AWG`, и к имени секции Podkop.

Если одновременно существуют два UCI-раздела, отличающиеся только регистром, установщик остановится как при неоднозначной конфигурации.

## Установка/обновление с GitHub одной командой

```sh
cd /tmp && \
wget -O podkop-awg-install.sh \
https://raw.githubusercontent.com/kumshi1978/openwrt-podkop-awg-failover/main/install.sh && \
sh podkop-awg-install.sh
```

Эта же команда используется для обновления уже установленной версии. Сначала файл скачивается, затем запускается — без `wget ... | sh`.

В репозитории не должно быть private key, PSK и других секретов.

## Настройка имён

Если на конкретном роутере интерфейсы называются иначе:

```sh
MAIN_AWG='Home_Main' BACKUP_AWG='Home_Backup' sh /tmp/podkop-awg-install.sh
```

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

`KILL_SWITCH=1` означает использование `hold/fail-closed` режима. Параметр сохранён для совместимости с существующими конфигурациями v1.1.0.

## Обновления без потери настроек

При первом запуске создаётся:

```text
/etc/podkop-awg-failover.conf
```

При повторном запуске `install.sh`:

1. читаются сохранённые параметры;
2. явно переданные environment-параметры имеют приоритет;
3. определяется фактический регистр имён UCI;
4. создаётся backup;
5. устанавливается новая версия watchdog/late-start;
6. конфигурация применяется сразу (`APPLY_NOW=1`).

Чтобы установить обновление, но применить его только после следующей загрузки:

```sh
APPLY_NOW=0 sh /tmp/podkop-awg-install.sh
```

## Fail-closed / hold: оба AmneziaWG упали

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
Podkop остаётся connection_type=vpn
        ↓
последний AWG-интерфейс недоступен
        ↓
соединение не выходит через WAN
```

При этом сам обычный WAN/LTE не блокируется. Трафик, который не относится к выбранным правилам Podkop, продолжает работать как обычно.

Watchdog продолжает проверять оба AWG в `hold`:

- основной восстановился `RECOVER_LIMIT` раз → Podkop переключается на `awg_main`;
- резервный восстановился `RECOVER_LIMIT` раз раньше основного → Podkop остаётся/переключается на `AWG_backup`;
- после последующего устойчивого восстановления основного стандартная логика вернёт трафик на `awg_main`.

Runtime-переключения `main ↔ backup` выполняются без `uci commit`. В постоянной конфигурации сохраняется штатное состояние `vpn + main`.

## Логика загрузки

```text
OpenWrt boot
   ↓
ждём IPv4 default route
   ↓
проверяем системное DNS-разрешение через штатный resolver OpenWrt
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

Скрипт не привязан к имени `wan`, `LTE`, `wwan0` и т.п. Он ждёт факт появления рабочего uplink и доступности системного DNS.

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

Затем отключить резервный:

```sh
ifdown AWG_backup
```

В логе ожидается:

```text
both AWG unavailable: entering hold mode; Podkop stays vpn via AWG_backup (fail-closed)
```

Проверка должна показывать:

```text
connection_type = vpn
interface       = AWG_backup
sing-box        = running
local FakeIP DNS = works
```

Обычный прямой WAN/LTE должен продолжать работать, а выбранный Podkop-домен при попытке HTTPS не должен получить fallback на WAN.

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
