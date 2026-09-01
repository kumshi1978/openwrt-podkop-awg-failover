# OpenWrt Podkop + AmneziaWG failover

Автоматическое резервирование двух AmneziaWG-туннелей для Podkop на OpenWrt.

Текущая версия: **1.3.4**.

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
- настраивает резервный набор NTP-серверов и перезапускает `sysntpd`;
- определяет WAN IPv4, сообщает о CGNAT (`100.64.0.0/10`) и логирует публичный IP активного AWG;
- постоянно проверяет sing-box, локальный DNS и IPv4-маршрут, а при сбое восстанавливает sing-box, Podkop и AWG watchdog;
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

### v1.3.0

Добавлен отдельный procd-сервис `podkop-health`. Он запускается после успешного позднего старта Podkop, проверяет sing-box, локальный DNS и IPv4 default route, а после нескольких последовательных ошибок выполняет ограниченное восстановление и перезапускает AWG failover watchdog.

Установщик заменяет список NTP-серверов на российские pool/Stratum 2 с резервом Cloudflare и Google. Перед изменением сохраняется `uci export system` в каталоге backup.

В журнал добавлена диагностика WAN IPv4, диапазона CGNAT `100.64.0.0/10` и публичного IPv4 активного AWG-интерфейса. Реализация использует стандартные BusyBox, UCI, procd и сетевые функции OpenWrt и сохраняет совместимость с протестированными OpenWrt 24.10 и 25.12.

### v1.3.1

Исправлена гонка холодной загрузки, обнаруженная на Cudy с OpenWrt 25.12.5: поздний старт больше не ждёт внешний DNS до запуска Podkop. Готовность проверяется после запуска по фактическому состоянию sing-box, локального DNS на `127.0.0.1` и IPv4 default route.

`podkop-late-start` запускается как `S100`, после штатного `S99podkop`. `podkop-health` и `podkop-awg-failover` включаются как самостоятельные procd/rc.d-сервисы и поэтому не зависят от успешного завершения late-start. Вызовы Podkop restart получили BusyBox-совместимый bounded timeout, а health recovery — взаимное исключение и cooldown по uptime. NTP остаётся необязательным и не блокирует запуск.

### v1.3.2

Обновление явно удаляет устаревшие rc.d-ссылки `podkop-late-start` перед созданием актуальной `S100podkop-late-start`, включая оставшуюся от старых версий `S98podkop-late-start`. После предварительной остановки сервисов установщик использует `start` вместо избыточного `restart`, чтобы procd не печатал безвредное `Command failed: Not found` при попытке удалить уже отсутствующий экземпляр.

AWG egress check различает рабочий туннель, реальный сетевой отказ и недоступный DNS (`curl` exit 6). DNS-сбой не меняет fail/recovery counters и сам по себе не вызывает переключение AWG или переход в hold. Если активный AWG действительно недоступен, а состояние backup неизвестно из-за DNS, watchdog сохраняет последний выбранный VPN в fail-closed режиме; восстановлением sing-box и локального DNS по-прежнему занимается health watchdog.

### v1.3.3

Перед каждым AWG egress check выполняется отдельная ограниченная по времени проверка `CHECK_HOST` через системный resolver. Если имя не разрешается или resolver не отвечает, состояние туннеля считается `unknown`: fail/recovery counters не изменяются, переключение AWG и переход в hold не выполняются. `curl` exit 6 остаётся защитой от DNS-сбоя между предварительной проверкой и самим HTTP-запросом. Восстановлением sing-box и локального DNS по-прежнему занимается `podkop-health`.

### v1.3.4

Для Podkop 0.7.x добавлены безопасные DNS-значения по умолчанию. Глобальные `dns_type=udp`, `dns_server=8.8.8.8` и `bootstrap_dns_server=1.1.1.1`, а также `domain_resolver_dns_type=doh` и `domain_resolver_dns_server=8.8.8.8` управляемой VPN-секции задаются только при отсутствующем или пустом параметре. Существующие пользовательские DNS-значения сохраняются. `domain_resolver_enabled` для управляемой секции включается явно.

Логика failover, health, hold/fail-closed, late-start и cold boot не изменена.

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
PODKOP_RETRIES=5
HEALTH_INTERVAL=30
HEALTH_FAIL_LIMIT=3
HEALTH_STARTUP_GRACE=60
RECOVERY_COOLDOWN=300
COMMAND_TIMEOUT=45
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
5. устанавливается новая версия failover/late-start/health watchdog;
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
Podkop = VPN через main
   ↓
restart Podkop
   ↓
проверяем sing-box + локальный DNS/FakeIP
   ↓
необязательный restart NTP
   ↓
health и AWG watchdog уже независимо запущены через rc.d/procd
```

Скрипт не привязан к имени `wan`, `LTE`, `wwan0` и т.п. Late-start ждёт только IPv4 default route; DNS проверяется после запуска Podkop через локальный resolver.

## Что устанавливается

```text
/etc/podkop-awg-failover.conf
/usr/bin/podkop-awg-failover
/etc/init.d/podkop-awg-failover
/usr/bin/podkop-late-start
/etc/init.d/podkop-late-start
/usr/bin/podkop-health
/etc/init.d/podkop-health
```

`podkop-health` и `podkop-awg-failover` включаются напрямую в boot и используют startup grace. Поэтому сбой `podkop-late-start` не оставляет роутер без watchdog. `podkop-late-start` выполняется после штатного Podkop и делает только ограниченное boot-восстановление.

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

