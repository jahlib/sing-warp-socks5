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
wg://162.159.192.1:500?private_key=key&peer_public_key=pubkey&pre_shared_key=&reserved=112-103-154&persistent_keepalive=0&mtu=1280&use_system_interface=false&local_address=172.16.0.2/32-2606:4700:110:8f05:fa00:8aff:48e2:9b49/128&workers=0&enable_amnezia=true&junk_packet_count=4&junk_packet_min_size=40&junk_packet_max_size=70&init_packet_junk_size=0&response_packet_junk_size=0&init_packet_magic_header=1&response_packet_magic_header=2&underload_packet_magic_header=3&transport_packet_magic_header=4#WARP
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
https://generator-warp-config.netlify.app/ - для throne

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
