# Sing-Box WARP Project
> Author remark:
> вы спросите - нахуя такие сложности? А потому что нативный warp не поддерживает amneziaWG ключи для обфускации WireGuard. А ебаться в саму амнезию нет желания. К тому же sing-box сразу может поднять локальный сокс что упрощает просовывание этого варпа во всякого рода панели.


Проект для запуска sing-box AWG > local socks5.

## Структура проекта

- `Dockerfile` - образ с sing-box
- `docker-compose.yml` - оркестрация контейнера
- `generate-config.sh` - генератор конфига из WireGuard AWG3.0 формата
- `warp.conf` - WARP конфигурация в формате WireGuard AWG3.0

## Как это работает

1. Положите ваш WARP конфиг в формате AWG3.0 в файл `warp.conf`
2. При запуске контейнера `generate-config.sh` парсит конфиг и генерирует `config.json`
3. SOCKS5 прокси поднимается на порту 2080

## Формат warp.conf

Вставьте WireGuard конфигурацию в файл `warp.conf`:

```AWG3.0
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

**Параметры:**
- `PrivateKey` - приватный ключ WireGuard
- `Address` - локальный IP адрес (IPv4)
- `MTU` - размер MTU (по умолчанию 1280)
- `S1-S4` - reserved байты для обфускации (используются первые 3)
- `Jc, Jmin, Jmax` - параметры Amnezia для junk пакетов
- `H1-H4` - magic headers для обфускации
- `PublicKey` - публичный ключ сервера
- `Endpoint` - адрес и порт сервера

## Запуск Docker-Compose

```bash
# Собрать и запустить
docker compose up -d

# Просмотр логов
docker compose logs -f

# Остановить
docker compose down -v
```

## (Alternative) Установка как systemd service без docker!
Скрипт попросит вставить WireGuard конфигурацию при установке
https://warp-generator.github.io/ AWG 3.0

```
curl -fsSL https://raw.githubusercontent.com/jahlib/sing-warp-socks5/refs/heads/master/quick-install.sh | sudo bash
```
После вставки конфига нажмите Enter - ctrl+D

## Использование

SOCKS5 прокси доступен на `localhost:2080` без авторизации.

Пример использования:
```bash
curl --proxy socks5://localhost:2080 ip-api.com
```

## Обновление конфигурации

После изменения `config.json`:
```bash
docker-compose restart
```
