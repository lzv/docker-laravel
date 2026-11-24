Для начала создайте в корне проекта пустой файл .env.php и выполните (для linux):

UID=$(id -u) GID=$(id -g) docker compose -f compose-dev.yaml run -itP --rm --build workspace

После захода в контейнер можно установить новый проект: 

laravel new project_name --no-boost

Затем переместите файлы проекта из подкаталога project_name на уровень вверх. Корень проекта - подкаталог app, который в образе примонтирован к /var/www/html

Перенесите файлы .env и .env.example из app в корень проекта. Переменные окружения будут передаваться не через .env файл фремворка Laravel, а через переменные окружения образов docker. Удалите из .env пароли к БД и APP_KEY и запишите их в secrets. В файлах сайта, в config/app.php поменяйте 'key' => env('APP_KEY'), на 'key' => file_get_contents(env('APP_KEY_FILE')). Аналогично поменяйте нужные строки в config/database.php на file_get_contents(env('DB_PASSWORD_FILE')).

Затем переименуйте .env в .env.php (и .env.example в .env.php.example) - это файл только для Laravel. Создайте другой файл .env, в который запишите переменную NGINX_PORT со своим значением - порт, по которму будет доступен nginx с хоста (например, 8080). Это будет файл только для docker.

Секреты:
secrets/db-root-pass - пароль root для mysql, используется только в compose-dev.yaml.
secrets/db-app-pass - пароль пользователя в БД, который работает с базой данных сайта.
secrets/app-key - значение APP_KEY.

При запуске на продакшене (с compose-prod.yaml) пароль root в mysql будет сгенерирован случайным образом. Нужно будет прочитать логи сервиса db и сохранить пароль себе, чтобы заходить через phpmyadmin.

Затем выйдите из образа и запустите все окружение для разработки: 

UID=$(id -u) GID=$(id -g) docker compose -f compose-dev.yaml up -d --build

Контейнер workspace служит для установки/удаления пакетов composer/npm, выполнения npm run build, а также для запуска vite. Команда по умолчанию в нем bash. Именованые контейнеры сохранят кэш composer и npm между запусками контейнера. Для выполнения команд нужно присоединиться к контейнеру или сделать exec bash.

npm run build не выполняется во время сборки, т.к. предполагается, что оно выполняется вручную в контейнере workspace, и готовые ассеты копируются в образ с работающим сайтом и в образ с nginx. 

Для vite можно установить необязательный пакет fontaine: 
npm i -D fontaine

Затем можно запускать npm run dev. Что бы vite был доступен снаружи, есть несколько путей. Один из них, это прописать в vite.config.js опцию server.host = true. Другой, это в package.json добавить к команде его запуска параметр --host.

composer run dev нет смысла запускать в контейнере workspace, т.к. сайт работает в другом контейнере, и очереди и логи не будут прочитаны. При желании можно доустановить composer в контейнер development и выполнять команду там. Но лучше установить что-нибудь вроде Laravel Telescope.

Если все же есть желание запускать composer run dev в контейнере development, нужно отключить запуск встроенного php сервера и vite. Для этого нужно добавить в файл app/Providers/AppServiceProvider.php: 
в верх файла: use Illuminate\Foundation\DevCommands;
в метод boot: DevCommands::except('server', 'vite');
В workspace все еще можно будет запустить vite через npm run dev.

Цель контейнера development - быть наиболее похожим на контейнер production, чтобы отловить все ошибки из за окружения. Поэтому там только добавляется xdebug, и больше ничего.

Чтобы xdebug из контейнера смог соединиться с вашей IDE, нужно добавить исключение в файервол. Если у вас ufw, выполните: 
sudo ufw allow from 172.18.0.0/16 to any port 9003 comment 'docker xdebug'
Выяснить нужный ip можно так:
docker inspect id_контейнера_с_php | grep Gateway

Пример конфигурации в launch.json при использовании vscode и расширения devsense.phptools-vscode:
{
    "name": "Listen for Xdebug",
    "type": "php",
    "request": "launch",
    "port": 9003,
    "pathMappings": {
        "/var/www/html": "${workspaceRoot}/app"
    },
    "serverReadyAction": {
        "action": "openExternally",
        "pattern": ".*",
        "uriFormat": "http://localhost:8080/?XDEBUG_SESSION_START=1"
    }
}

В контейнерах development и production реализован максимальный уровень безопасности: рабочие процессы php-fpm запускается от пользователя www-data, при этом все файлы и каталоги сайта принадлежат root, кроме каталогов, куда фреймворку нужна запись: bootstrap/cache и /storage.

Файлы, загружаемые на сайт, хранятся в storage/app (public и/или private). Они должны соответствовать содержимому БД и сохраняться между пересозданием контейнеров production и development. Поэтому в этих контейнерах к каталогу storage/app примонтирован именованый том. 

Другие файлы в storage и файлы в bootstrap/cache создаются приложением и должны соответствовать текущему php коду. Поэтому эти каталоги исключены из контекста сборки, и при этом их содержимое не сохраняется в каком-либо томе.

В файле nginx.conf.prod замените your.domain на адрес вашего сайта.

В конфигурации php-fpm включена опция pm.status_path = /php-fpm-status, и в dev конфигурации nginx передаст запрос на этот путь с адреса status.localhost:8080. В prod конфигурации этот адрес недоступен снаружи контейнера и используется только скриптом php-fpm-healthcheck. Настройте nginx для доступа к адресу.

Если нужно, чтобы каталог storage/app/public был доступен публично, перейдите в public и создайте относительную ссылку: 
ln -s ../storage/app/public storage

---------------

Для корректной работы расширения laravel.vscode-laravel в vscode ему нужно указать опции:

"Laravel.phpEnvironment": "docker",
"Laravel.phpCommand": [
    "docker",
    "compose",
    "-f",
    "../compose-dev.yaml",
    "exec",
    "-T",
    "workspace",
    "php"
],
"Laravel.basePath": "app",

Это будет работать только при запущенных контейнерах. Но при этом не будет работать создание файлов laravel через ПКМ на каталоге в дереве каталогов, из за бага с неправильным поиском файла composer.json. Для решения этого можно напрямую открыть подкаталог app в отдельном окне vscode, либо настроить multi-root workspace. В настройках каталога app не нужно указывать опцию Laravel.basePath, а в его файле launch.json нужно убрать подкаталог app из опции pathMappings.

При использовании multi-root workspace опции Laravel.phpEnvironment и Laravel.phpCommand указываются в файле .code-workspace, при этом каталог app должен идти первым, т.к. опции применяются к первому каталогу. В settings.json корня проекта нужно исключить подкаталог app из обработки, чтобы избежать дублирования: 

"files.exclude": {
    "app": true
},
"search.exclude": {
    "app": true
}

---------------

При использовании расширения devsense.phptools-vscode можно настроить его на использование php в контейнере сервиса workspace. Можно использовать и php-fpm, но там нет файлов с тестами. Для начала создайте файл app/.vscode/php-docker.sh с правами на выполнение: 

#!/bin/bash

LOCAL_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_PATH="$(dirname "$LOCAL_PATH")"
ROOT_PATH="$(dirname "$LOCAL_PATH")"
CONTAINER_PATH="/var/www/html"

ARGS=()
for arg in "$@"; do
    ARGS+=("${arg//$LOCAL_PATH/$CONTAINER_PATH}")
done

docker compose -f "$ROOT_PATH/compose-dev.yaml" exec -T workspace php "${ARGS[@]}"

После этого пропишите настройки для каталога app: 

"php.executables": {
    "docker-php": "${workspaceFolder}/.vscode/php-docker.sh"
},
"php.version": "docker-php",


