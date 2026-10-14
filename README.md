# Sing-Box WARP Project (Additional Proton out)
> Author remark:
>> вы спросите - нахуя такие сложности? А потому что нативный warp не поддерживает amneziaWG ключи для обфускации WireGuard. А ебаться в саму амнезию нет желания. К тому же sing-box сразу может поднять локальный сокс что упрощает просовывание этого варпа во всякого рода панели.
>
>> UPD: Теперь в рф захотели блокировать github и появилась проблема установки панелей. Данное решение покрывает проблемы со скачиванием любых репозиториев или иного self-host софта с github и попутно покрывает ряд других блокнутых ресурсов при включении TUN во время установки. TUN режим лучше использовать только на время установок софта.
>
>> UPD: Добавлена поддержка ProtonVPN конфигураций совместно с warp или отдельно.


Проект для запуска sing-box с WARP через systemd.

## Структура проекта

- `quick-install.sh` — установка и настройка systemd-сервиса
- `generate-config.sh` — генератор `config.json` из WireGuard AWG
- `warp.conf.example` — пример WARP-конфигурации
- `proton.conf.example` — пример второй (Proton) WireGuard-конфигурации

## Как это работает

1. При установке отдельно спрашивается добавление WARP и добавление Proton — каждый опционален
2. WARP-конфиг (AWG 3.0) → `/etc/sing-box-warp/warp.conf`, Proton-конфиг (обычный WireGuard или `wg://`) → `/etc/sing-box-warp/proton.conf`
3. `generate-config.sh` парсит доступные конфиги и пишет `/opt/sing-box-warp/config.json`
4. SOCKS5 WARP доступен на порту `2080`, Proton — на `3080` (создаётся только тот, что добавлен)
5. Опционально TUN для сплит-маршрутизации

### Схема маршрутизации

Скрипт работает в трёх режимах: **только WARP**, **только Proton** или **WARP + Proton**.
Нужно выбрать хотя бы один — если отказаться от обоих, установка завершается без действий.

- SOCKS-инпуты жёстко привязаны к своим выходам: `2080 → warp-out`, `3080 → proton-out`.
  Каждый инпут создаётся только если соответствующий конфиг добавлен.
- Всё остальное (TUN-трафик, списки маршрутизации `.srs`, сайты проверки IP, proxy-DNS) идёт в
  «дефолтный» выход.
  - Если добавлены **оба** — дефолт выбирается при установке: **WARP** или **Proton**.
  - Если добавлен **только один** — он и становится дефолтом автоматически, вопрос не задаётся.

## Установка

Сгенерируйте конфиг на https://warp-generation.github.io (https://t.me/warp_generator_bot) (AWG 2.0 - 3 вариант, если не заработает переустановите с 2 вариант), затем:

```none
curl -fsSL https://gitea.digitalforest.my/hesoyam/sing-warp-socks5/raw/branch/main/quick-install.sh | sudo bash
```

Скрипт последовательно спросит про WARP и про Proton — можно добавить оба, только один или,
если отказаться от обоих, установка завершится без изменений.

Сначала — WARP. Ответьте `y` и вставьте текстом содержимое AWG-конфига (Enter, затем Ctrl+D), либо `n`, чтобы пропустить.

```none
Add WARP configuration? (y/n)
```

Затем — Proton. Брать протон тут https://account.protonvpn.com/downloads (нужен аккаунт).
Ответьте `y` и вставьте WireGuard-конфиг (формат `[Interface]`/`[Peer]` как у Proton VPN, либо `wg://`, Ctrl+D для завершения), либо `n`, чтобы пропустить.

```none
Add Proton configuration? (y/n)
```

Далее спрашивается включение TUN. Включите, если с сервера недоступны заблокированные ресурсы (GitHub и т.п.). Без TUN — только SOCKS5.

```none
Enable TUN mode? (y/n)
```

Если добавлены **оба** конфига — скрипт спросит, куда направлять весь не-SOCKS трафик (дефолтный выход).
Если добавлен только один — он становится дефолтом автоматически, без вопроса.
SOCKS-инпуты при этом всегда остаются: `2080 → WARP`, `3080 → Proton`.

```none
=== Default route ===
  1) WARP   (warp-out)
  2) Proton (proton-out)
Select default route [1/2]
```

Повторный запуск инсталлера останавливает старый сервис, переустанавливает файлы и запускает заново.

## Формат warp.conf

```ini
[Interface]
PrivateKey = {privkey}
Address = 172.16.0.2, 2606:4700:110:890e:48c0:b073:6ebe:d347
DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
MTU = 1280
S1 = 0
S2 = 0
Jc = 4
Jmin = 40
Jmax = 70
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = {string}

[Peer]
PublicKey = {pubkey}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
```

## Формат proton.conf (опционально)

Обычный WireGuard-конфиг (например, экспорт из Proton VPN) или `wg://`-ссылка.

```ini
[Interface]
PrivateKey = {privkey}
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = {pubkey}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 149.50.211.159:51820
PersistentKeepalive = 25
```

## Использование

SOCKS5 без авторизации (создаётся только тот инпут, чей конфиг добавлен):

- WARP — `localhost:2080`
- Proton — `localhost:3080`

```none
curl --proxy socks5://localhost:2080 ip-api.com   # через WARP
curl --proxy socks5://localhost:3080 ip-api.com   # через Proton
```

С TUN трафик по спискам `.srs` идёт через дефолтный выход (WARP или Proton); SOCKS5 при этом остаётся доступным.

```none
curl ip-api.com
```

## Управление сервисом

```none
sudo systemctl enable sing-box-warp
sudo systemctl start sing-box-warp
sudo systemctl status sing-box-warp
sudo journalctl -u sing-box-warp -f
sudo systemctl restart sing-box-warp
```

## Обновление конфигурации

Отредактируйте нужные файлы в `/etc/sing-box-warp/` (нужен хотя бы один из `warp.conf` / `proton.conf`):

- `warp.conf` — конфиг WARP (удалите файл, чтобы отключить WARP)
- `proton.conf` — конфиг Proton (удалите файл, чтобы отключить Proton)
- `enable-tun` — `1`/`0` для TUN
- `default-route` — `warp` или `proton` (куда идёт весь не-SOCKS трафик; при одном эндпоинте берётся он)

затем:

```none
sudo /opt/sing-box-warp/generate-config.sh
sudo systemctl restart sing-box-warp
```

## Полная переустановка 
Заново запустить скрипт `quick-install.sh`.

## Полное удаление
```none
sudo rm -rf /opt/sing-box-warp
sudo rm -rf /etc/sing-box-warp
sudo rm -rf /etc/systemd/system/sing-box-warp.service
sudo rm -rf /var/cache/sing-box-warp
sudo rm /usr/bin/sing-box /usr/local/bin/sing-box
```


