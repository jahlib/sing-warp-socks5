# Sing-Box WARP Project
> Author remark:
> вы спросите - нахуя такие сложности? А потому что нативный warp не поддерживает amneziaWG ключи для обфускации WireGuard. А ебаться в саму амнезию нет желания. К тому же sing-box сразу может поднять локальный сокс что упрощает просовывание этого варпа во всякого рода панели.`


Проект для запуска sing-box с WARP конфигурацией.

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

Возьмите на странице [Warp-Generator](https://warp-generator.github.io/warp/) конфиг для Throne и вставьте его в warp.conf как есть

```
wg://SERVER:PORT?private_key=...&junk_packet_count=4&junk_packet_min_size=40&...#WARP
```

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
Создавать warp.conf не нужно, скрипт сам спросит скопированный ws:// на ввод
```
curl -fsSL https://raw.githubusercontent.com/jahlib/sing-warp-socks5/refs/heads/master/quick-install.sh | sudo bash
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
