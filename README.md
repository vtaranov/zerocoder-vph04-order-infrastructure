# VPh04 - инфраструктура сайта обработки заказов

Учебная работа Виктора Таранова: развёртывание инфраструктуры на VPS с помощью ИИ-ассистента Codex. Форма заявок и прикладной backend относятся к следующим частям кейса.

## Состав

- Nginx - HTTPS, стартовая страница и reverse proxy.
- PostgreSQL 17 - отдельная БД `orders`, постоянный том.
- pgAdmin 4 - защищённый вход и преднастроенное подключение к PostgreSQL.
- CNCF Distribution Registry 3 - собственное хранилище Docker-образов с bcrypt-аутентификацией.
- Watchtower 1.7.1 - обновление только контейнеров с меткой разрешения и scope `vph04`.

Один внешний порт по умолчанию: **18443/TCP**. PostgreSQL, pgAdmin и Registry не публикуют собственные порты хоста. База и pgAdmin находятся в сети `internal: true`; Nginx передаёт запросы к pgAdmin. Registry доступен через HTTPS по `/v2/`, pgAdmin - по `/pgadmin/`.

## Требования

Linux VPS, Docker Engine и Compose, Python 3 для необязательного генератора конфигурации. Проверено на Ubuntu 26.04.1 LTS, x86_64, 1 vCPU и 2 ГБ RAM. Docker Engine устанавливается на сервер по [официальной инструкции](https://docs.docker.com/engine/install/ubuntu/). Переустановка ОС для этого проекта не требуется.

Нужен действительный TLS-сертификат для домена или публичного IP. Compose ожидает каталоги Certbot `live/<host>` и `archive/<host>`: оба монтируются только для чтения, чтобы относительные ссылки Certbot продолжали работать. Настройки путей задаются в `.env`. Выпуск сертификата и проверка владения адресом выполняются администратором отдельно.

## Запуск

```sh
git clone https://github.com/vtaranov/zerocoder-vph04-order-infrastructure.git
cd zerocoder-vph04-order-infrastructure
python3 scripts/init-secrets.py --host your-server.example.com --email admin@example.com
```

Проверьте `.env`: внешний порт, пути TLS, имя БД и пользователя. Если меняете имя БД/пользователя, измените также `pgadmin/servers.json`. Пароли генерируются независимо. `.env` имеет права 0600 и исключён из Git. Не запускайте `.env` через `source`: Compose читает его самостоятельно.

Создайте пользователя Registry; пароль запрашивается интерактивно и не попадает в аргументы процесса:

```sh
./registry/create-user.sh vph04
docker compose -f docker-compose.yml -f compose.lock.yml up -d --wait --wait-timeout 180
docker --config secrets login your-server.example.com:18443 --username vph04
cp secrets/config.json secrets/docker-config.json
chmod 600 secrets/config.json secrets/docker-config.json
docker compose restart watchtower
```

`create-user.sh` использует `htpasswd` из официального образа `httpd:2.4-alpine`. Для автоматизации предусмотрен `--stdin`; пароль передаётся по stdin. Каталог с хешем закрыт правами 0700; сам файл доступен процессу Registry внутри контейнера.

`compose.lock.yml` фиксирует digest пяти проверенных образов. Для воспроизведения используйте оба Compose-файла. Обычный `docker compose up -d` использует указанные в основном файле теги; при обновлении инфраструктуры нужно отдельно пересмотреть lock-файл. Watchtower не обновляет инфраструктурные контейнеры автоматически.

Запустите стек после подготовки сертификата и пользователя Registry:

```sh
docker compose -f docker-compose.yml -f compose.lock.yml up -d --wait --wait-timeout 150
docker --config secrets login your-server.example.com:18443 --username vph04
cp secrets/config.json secrets/docker-config.json
chmod 600 secrets/config.json secrets/docker-config.json
docker compose restart watchtower
```

Сертификат должен быть доверенным и соответствовать `PUBLIC_HOST`. В примере используются каталоги Certbot `live/<host>` и `archive/<host>`; монтируются оба, чтобы работали относительные символьные ссылки. Получение сертификата на новом сервере выполняется отдельно перед запуском.

## Использование

Откройте `https://your-server.example.com:18443/`, затем `/pgadmin/`. Вход pgAdmin - `PGADMIN_DEFAULT_EMAIL` и `PGADMIN_DEFAULT_PASSWORD` из `.env`. Для подключения преднастроенного сервера введите `POSTGRES_PASSWORD`. Пароль БД не записан в публичный `servers.json`.

Registry предоставляет HTTP API, отдельной панели у него нет. `/v2/` без пароля возвращает **401**, с правильным паролем - **200**. Проверяйте TLS штатно, без `-k` и без `insecure-registries`.

Пример доставки своего образа:

```sh
docker tag my-app:1.0 your-server.example.com:18443/my-app:1.0
docker --config secrets push your-server.example.com:18443/my-app:1.0
docker --config secrets pull your-server.example.com:18443/my-app:1.0
```

## Проверки

```sh
./scripts/verify-server.sh
./scripts/smoke-update.sh
```

`verify-server.sh` проверяет Compose, SQL-подключение, конфигурацию Nginx, логи Watchtower и расход памяти. `smoke-update.sh` запускается на сервере с заполненным `.env` и сохранённой авторизацией Registry: собирает две версии крошечного тестового образа, публикует их в Registry и проверяет замену контейнера через Watchtower. Контейнер после успеха удаляется; тестовые образы сохраняются. При ошибке контейнер остаётся для диагностики. Команда выполняет сборку, публикацию и временный запуск, поэтому используйте её только в учебном окружении.

Тестовый контейнер имеет обе метки:

```yaml
com.centurylinklabs.watchtower.enable: "true"
com.centurylinklabs.watchtower.scope: vph04
```

Watchtower имеет доступ к Docker socket. Метки ограничивают выбор обновляемых контейнеров, но не являются изоляцией прав самого Watchtower. `DOCKER_API_VERSION=1.44` обеспечивает совместимость использованной версии Watchtower с Docker Engine 29. Старые тестовые образы удерживаются дополнительными тегами, чтобы перезапись изменяемого тега не лишала Watchtower метаданных запущенной версии.

Проверено 16 ноября 2026:

- запуск пяти сервисов и конфигурация Nginx;
- HTTPS с обычной проверкой сертификата;
- вход в pgAdmin и реальное подключение к PostgreSQL в браузере;
- отказ Registry без пароля и с неверным паролем, успешная авторизация;
- публикация и скачивание тестового образа;
- автоматическая замена контейнера версией 2 через Watchtower;
- сохранение контрольной записи PostgreSQL после перезапуска;
- отсутствие прямого внешнего доступа к портам 5432, 5000 и 5050.

Полные протоколы и скриншоты хранятся отдельно и не публикуются вместе с секретами.

## Обслуживание и восстановление

Существующие приложения на портах 80/443 могут продолжать работать: учебный Nginx занимает отдельный порт. Логи ограничены 2 файлами по 5 МБ на контейнер. Есть лимиты памяти и постоянные тома PostgreSQL, pgAdmin, Registry.

После продления TLS требуется перечитать сертификат в контейнере. Если проект расположен в `/opt/vph04-orders`, установите hook:

```sh
sudo install -m 755 scripts/reload-tls.sh /etc/letsencrypt/renewal-hooks/deploy/vph04-nginx
```

Для другого пути измените `cd` в скрипте. Hook проверяет работающий контейнер и конфигурацию перед reload. При развёртывании hook был запущен вручную; отдельный повторный выпуск сертификата не выполнялся.

Сделать резервную копию БД:

```sh
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > orders.sql
```

Храните копию вне VPS с ограниченным доступом. Также резервируйте `.env`, хеши Registry и тома pgAdmin/Registry; при файловом копировании томов останавливайте соответствующие сервисы. Автоматическое внешнее резервирование этим проектом не настроено.

Для восстановления разверните репозиторий и приватные настройки, восстановите TLS и данные томов, затем запустите Compose. SQL-восстановление в уже созданную БД:

```sh
docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < orders.sql
```

`docker compose stop` останавливает учебный стек. Не используйте `down -v` для обычного обслуживания: этот вариант удаляет данные томов. `.env`, Docker credentials, SSH-ключи и пароли никогда не включаются в репозиторий.
