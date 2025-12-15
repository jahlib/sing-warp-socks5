# Sing-Box WARP Docker Project

Docker проект для запуска sing-box с WARP конфигурацией.

## Структура проекта

- `Dockerfile` - образ с sing-box
- `docker-compose.yml` - оркестрация контейнера
- `generate-config.sh` - генератор конфига из wg:// URL
- `warp.conf` - WARP ключ в формате wg:// URL

## Как это работает

1. Положите ваш WARP ключ в формат `wg://` URL в файл `warp.conf`
2. При запуске контейнера `generate-config.sh` парсит ключ и генерирует `config.json`
3. SOCKS5 прокси поднимается на порту 2080

## Формат warp.conf

```
wg://SERVER:PORT?private_key=...&junk_packet_count=4&junk_packet_min_size=40&...#WARP
```

## Запуск

```bash
# Собрать и запустить
docker-compose up -d

# Просмотр логов
docker-compose logs -f

# Остановить
docker-compose down
```

## Использование

SOCKS5 прокси доступен на `localhost:2080` без авторизации.

Пример использования:
```bash
curl --proxy socks5://localhost:2080 https://ifconfig.me
```

## Обновление конфигурации

После изменения `config.json`:
```bash
docker-compose restart
```
