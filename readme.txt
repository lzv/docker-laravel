Для начала выполните в корне проекта (для linux):

UID=$(id -u) GID=$(id -g) docker compose -f compose-dev.yaml run -itP --rm --build workspace

После захода в контейнер можно установить новый проект: 

laravel new project_name --no-boost

Затем переместите файлы проекта из подкаталога project_name на уровень вверх. Корень проекта - подкаталог app, который в образе примонтирован к /var/www/html

Перенесите файлы .env и .env.example из app в корень проекта. Переменные окружения будут передаваться не через .env файл фремворка Laravel, а через переменные окружения образов docker. Удалите из .env пароли к БД и APP_KEY и запишите их в secrets. В файлах сайта, в config/app.php поменяйте 'key' => env('APP_KEY'), на 'key' => file_get_contents(env('APP_KEY_FILE')). Аналогично поменяйте нужные строки в config/database.php на file_get_contents(env('DB_PASSWORD_FILE')).

Затем переименуйте .env в .env.php - это файл только для Laravel. Создайте другой файл .env, в который запишите переменную NGINX_PORT со своим значением. Это будет файл только для docker.

Секреты:
secrets/db-root-pass - пароль root для mysql, используется только в compose-dev.yaml.
secrets/db-app-pass - пароль пользователя в БД, который работает с базой данных сайта.
secrets/app-key - значение APP_KEY.

При запуске на продакшене (с compose-prod.yaml) пароль root в mysql будет сгенерирован случайным образом. Нужно будет прочитать логи сервиса db и сохранить пароль себе, чтобы заходить через phpmyadmin.

Затем выйдите из образа и запустите все окружение для разработки: 

UID=$(id -u) GID=$(id -g) docker compose -f compose-dev.yaml up -d --build

Контейнер workspace служит для установки/удаления пакетов composer/npm, выполнения npm run build, а также для запуска vite. Команда по умолчанию в нем bash. Именованые контейнеры сохранят кэш composer и npm между запусками контейнера. Для выполнения команд к контейнеру нужно присоединиться или сделать exec bash.

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

В контейнерах development и production реализован максимальный уровень безопасности: рабочие процессы php-fpm запускается от пользователя www-data, при этом все файлы сайта принадлежат root, кроме каталогов, куда фреймворку нужна запись: bootstrap/cache и /storage.

Файлы, загружаемые на сайт, хранятся в storage/app (public и/или private). Они должны соответствовать содержимому БД и сохраняться между пересозданием контейнеров production и development. Поэтому в этих контейнерах к каталогу storage/app примонтирован именованый том. 

В файле nginx.conf.prod замените your.domain на адрес вашего сайта.

В dev конфигурации включена опция pm.status_path = /php-fpm-status, и nginx передаст запрос на этот путь с адреса status.localhost:8080.
