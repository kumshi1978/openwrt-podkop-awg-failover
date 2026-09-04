# HOME NET — автообновление Podkop + AmneziaWG failover

## Назначение

Начиная с v1.4.0 компонент `openwrt-podkop-awg-failover` умеет проверять и применять только опубликованные stable GitHub Releases с тегами вида `vMAJOR.MINOR.PATCH`.

Updater не использует ветку `main` как канал автоматических обновлений, игнорирует draft/prerelease и не выполняет downgrade.

Начиная с v1.4.1 updater не требует `cksum` или дополнительных coreutils-пакетов и работает на протестированном Cudy / OpenWrt 24.10.4 с BusyBox ash.

## Что такое canary-router

**Canary-router** — это один заранее выбранный тестовый боевой Cudy, который получает новые опубликованные stable-обновления раньше остальных роутеров HOME NET.

Его задача — проверить новую версию на реальном оборудовании до массового rollout. Если в новой версии обнаружится проблема, она затронет только один заранее выбранный роутер, а остальные продолжат работать на уже проверенной версии.

Политика HOME NET:

- canary-router: `AUTO_UPDATE_MODE='apply'` — новая stable-версия может устанавливаться автоматически;
- остальные роутеры: `AUTO_UPDATE_MODE='check'` — только проверяют наличие новой версии и пишут результат в лог, но не устанавливают её автоматически;
- после успешной проверки на canary новую версию можно поэтапно разрешать для остальных роутеров;
- OpenWrt 24.x и 25.x считаются отдельными аппаратными группами и проверяются отдельно.

## Конфигурация

Файл:

```text
/etc/podkop-awg-update.conf
```

Значения по умолчанию:

```sh
AUTO_UPDATE_MODE='check'
AUTO_UPDATE_INTERVAL='86400'
AUTO_UPDATE_JITTER='21600'
AUTO_UPDATE_STARTUP_DELAY='300'
```

- `check` — только проверять новые stable releases и писать результат в лог;
- `apply` — автоматически применять новую stable-версию;
- `AUTO_UPDATE_INTERVAL` — период проверки в секундах;
- `AUTO_UPDATE_JITTER` — стабильная задержка для разведения обновлений между роутерами;
- `AUTO_UPDATE_STARTUP_DELAY` — задержка после загрузки перед запуском updater daemon.

## Ручная проверка

```sh
/usr/bin/podkop-awg-update check
```

Если обновлений нет:

```text
installed version X.Y.Z is the latest stable release
```

Если доступно обновление:

```text
stable update available: X.Y.Z -> A.B.C (vA.B.C)
```

## Ручное применение stable release

```sh
/usr/bin/podkop-awg-update apply
```

Updater:

1. получает metadata последнего stable GitHub Release;
2. проверяет tag/version;
3. запрещает downgrade;
4. скачивает `VERSION` и `install.sh` именно из release tag;
5. проверяет соответствие installer версии release;
6. выполняет `sh -n`;
7. создаёт pre-apply backup;
8. запускает installer с `UPDATE_SOURCE_REF` равным точному release tag.

## Canary auto-apply

Рекомендуется включать автоматическое применение сначала только на одном тестовом Cudy — canary-router.

### Включить canary

```sh
cp -p /etc/podkop-awg-update.conf \
  /root/podkop-awg-update.conf.before-canary-$(date +%Y%m%d-%H%M%S)

sed -i "s/^AUTO_UPDATE_MODE='[^']*'/AUTO_UPDATE_MODE='apply'/" \
  /etc/podkop-awg-update.conf

/etc/init.d/podkop-awg-update restart

printf '===== CONFIG =====\n'
cat /etc/podkop-awg-update.conf

printf '\n===== PROCESS =====\n'
pgrep -af '/usr/bin/podkop-awg-update'

printf '\n===== CURRENT VERSION =====\n'
grep '^INSTALLED_VERSION=' /etc/podkop-awg-failover.conf

printf '\n===== UPDATE CHECK =====\n'
/usr/bin/podkop-awg-update check

printf '\n===== LOG =====\n'
logread | grep 'podkop-update' | tail -30
```

Ожидается:

```text
AUTO_UPDATE_MODE='apply'
```

и запущенный процесс:

```text
/bin/sh /usr/bin/podkop-awg-update daemon
```

Updater daemon после старта ждёт `AUTO_UPDATE_STARTUP_DELAY`, затем индивидуальный `AUTO_UPDATE_JITTER`, поэтому автоматическая проверка не обязана происходить сразу после restart.

## Вернуть router в безопасный check-only режим

```sh
sed -i "s/^AUTO_UPDATE_MODE='[^']*'/AUTO_UPDATE_MODE='check'/" \
  /etc/podkop-awg-update.conf

/etc/init.d/podkop-awg-update restart

cat /etc/podkop-awg-update.conf
pgrep -af '/usr/bin/podkop-awg-update'
```

## Проверка состояния после обновления

```sh
printf '===== VERSION =====\n'
grep '^INSTALLED_VERSION=' /etc/podkop-awg-failover.conf

printf '\n===== PROCESSES =====\n'
pgrep -af '/usr/bin/podkop-awg-update'
pgrep -af '/usr/bin/podkop-awg-failover'
pgrep -af '/usr/bin/podkop-health'

printf '\n===== ACTIVE VPN =====\n'
uci -q get podkop.main.interface

printf '\n===== MONITORING =====\n'
cat /tmp/podkop-service-health/state 2>/dev/null

printf '\n===== RECENT LOG =====\n'
logread | grep -E 'podkop-update|podkop-awg|podkop-health|podkop-late' | tail -60
```

Для HOME NET нормальное состояние после обновления:

```text
STATUS=OK
ACTIVE_VPN=awg_main
PODKOP=RUNNING
SING_BOX=RUNNING
FAKEIP=OK
```

## Политика HOME NET

Рекомендуемая схема для нескольких Cudy:

1. один router — `AUTO_UPDATE_MODE='apply'` (canary);
2. остальные routers — `AUTO_UPDATE_MODE='check'`;
3. после аппаратного подтверждения новой версии на canary остальные routers обновляются вручную или переводятся в `apply` поэтапно;
4. OpenWrt 24.x и 25.x проверяются отдельно перед массовым rollout;
5. release должен быть published stable, не draft и не prerelease.
