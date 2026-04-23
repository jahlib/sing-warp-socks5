# Sing-Box WARP Project
> Author remark:
> вы спросите - нахуя такие сложности? А потому что нативный warp не поддерживает amneziaWG ключи для обфускации WireGuard. А ебаться в саму амнезию нет желания. К тому же sing-box сразу может поднять локальный сокс что упрощает просовывание этого варпа во всякого рода панели.


Проект для запуска sing-box с WARP конфигурацией.

## Структура проекта

- `Dockerfile` - образ с sing-box
- `docker-compose.yml` - оркестрация контейнера
- `generate-config.sh` - генератор конфига из WireGuard AWG2.0 формата
- `warp.conf` - WARP конфигурация в формате WireGuard AWG2.0

## Как это работает

1. Положите ваш WARP конфиг в формате AWG2.0 в файл `warp.conf`
2. При запуске контейнера `generate-config.sh` парсит конфиг и генерирует `config.json`
3. SOCKS5 прокси поднимается на порту 2080

## Формат warp.conf

Вставьте WireGuard конфигурацию в файл `warp.conf`:

```AWG2.0
[Interface]
PrivateKey = {somethinghere}
Address = 172.16.0.2
DNS = 8.8.8.8, 8.8.4.4	
MTU = 1280
S1 = 0
S2 = 0
S3 = 0
S4 = 0
Jc = 4
Jmin = 40
Jmax = 70
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = {somethinghere}
I2 = {somethinghere}

[Peer]
PublicKey = {somethinghere}
AllowedIPs = 0.0.0.0/0
Endpoint = engage.cloudflareclient.com:880
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
```
curl -fsSL https://raw.githubusercontent.com/jahlib/sing-warp-socks5/refs/heads/master/quick-install.sh | sudo bash
```

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
