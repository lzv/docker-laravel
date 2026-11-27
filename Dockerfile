# Базовый образ, содержащий общее для php образов сборки и workspace, чтобы избежать дублирования.
# Документация по образу: https://hub.docker.com/_/php
FROM php:8.5-fpm-trixie AS base_builder_php

# pcntl нужен для пакета composer laravel/pail, который является dev зависимостью, но 
# в целях схожести образов production и development установим его в обоих образах.
# unzip и расширение zip (которому нужен libzip-dev) нужны для composer
RUN <<EOF
    set -e

    apt-get update 

    apt-get install -y --no-install-recommends libicu-dev libzip-dev unzip
    docker-php-ext-install -j$(nproc) intl
    docker-php-ext-install -j$(nproc) zip
    docker-php-ext-install -j$(nproc) pdo_mysql

    docker-php-ext-install -j$(nproc) pcntl

    apt-get clean
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && composer --version

# Файлы конфигурации laravel читаются после установки пакетов composer. Поэтому файлы, указанные в этих переменных, должны существовать.
# Но их содержимое при этом не используется. Поэтому не нужно монтировать секреты, а достаточно создать пустые файлы.
ARG APP_KEY_FILE="/tmp/key_file"
ARG DB_PASSWORD_FILE="/tmp/db_pass_file"
RUN touch ${APP_KEY_FILE} && touch ${DB_PASSWORD_FILE}

# Образ workspace предназначен для создания проекта и работы с пакетами composer,
# а также работы с npm и запуска vite.
FROM base_builder_php AS workspace

# Удаление ненужных файлов
RUN rm ${APP_KEY_FILE} && rm ${DB_PASSWORD_FILE}

COPY --from=node:24-trixie-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:24-trixie-slim /usr/local/include/node /usr/local/include/node
COPY --from=node:24-trixie-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && export NODE_DISABLE_COMPILE_CACHE=1 \
    && node --version && npm --version

ARG UID=1000
ARG GID=1000

RUN groupmod -g ${GID} www-data && \
    usermod -u ${UID} www-data && \
    usermod -g www-data www-data && \
    mkdir -p /var/www/.npm && \
    mkdir -p /var/www/.composer/cache && \
    chmod 755 /var/www/html && \
    chown -R www-data:www-data /var/www

USER www-data

ENV PATH="/var/www/.composer/vendor/bin:${PATH}"
RUN --mount=type=cache,target=/var/www/.composer/cache,sharing=locked,uid=${UID},gid=${GID} \
    composer global require laravel/installer

COPY configs/php.ini-development $PHP_INI_DIR/php.ini

EXPOSE 5173

CMD ["bash"]

FROM base_builder_php AS builder_php_prod

COPY app /var/www/html/

RUN --mount=type=cache,target=/root/.composer/cache,sharing=locked \
    --mount=type=secret,id=app-key \
    composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist

# Документация по образу: https://hub.docker.com/_/php
FROM php:8.5-fpm-trixie AS production

# libfcgi-bin и procps нужны для скрипта php-fpm-healthcheck
RUN <<EOF
    set -e

    apt-get update 
    apt-get install -y --no-install-recommends libicu76 libfcgi-bin procps libzip5 zlib1g
    apt-get clean
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

COPY --from=builder_php_prod /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder_php_prod /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

COPY --chmod=+x scripts/php-fpm-healthcheck /usr/local/bin/php-fpm-healthcheck
COPY --chmod=+x scripts/docker-php-entrypoint-prod /usr/local/bin/docker-php-entrypoint

COPY configs/php.ini-production $PHP_INI_DIR/php.ini
COPY configs/www.conf-production /usr/local/etc/php-fpm.d/www.conf

COPY --from=builder_php_prod /var/www/html/ /var/www/html/

RUN chown -R www-data:www-data /var/www/html/bootstrap/cache /var/www/html/storage && \
    chmod 755 /var/www/html && \
    chown root:root /var/www/html

WORKDIR /var/www/html

# Образ не наследует builder_php_prod, чтобы при 
# изменении кода не устанавливать заново xdebug.
FROM base_builder_php AS builder_php_dev

RUN --mount=type=cache,target=/tmp/pear,sharing=locked \
    pecl install xdebug-3.5.3 && docker-php-ext-enable xdebug

COPY configs/docker-php-ext-xdebug.ini /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

COPY app /var/www/html/

RUN --mount=type=cache,target=/root/.composer/cache,sharing=locked \
    --mount=type=secret,id=app-key \
    composer install --no-interaction --prefer-dist

FROM production AS development

COPY --from=builder_php_dev /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder_php_dev /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

COPY --chmod=+x scripts/docker-php-entrypoint-dev /usr/local/bin/docker-php-entrypoint

COPY configs/php.ini-development $PHP_INI_DIR/php.ini
COPY configs/www.conf-development /usr/local/etc/php-fpm.d/www.conf

RUN rm -r /var/www/html
COPY --from=builder_php_dev /var/www/html/ /var/www/html/

RUN chown -R www-data:www-data /var/www/html/bootstrap/cache /var/www/html/storage && \
    chmod 755 /var/www/html && \
    chown root:root /var/www/html

# Документация по образу: https://hub.docker.com/_/nginx
FROM nginx:alpine AS nginx_prod

COPY configs/nginx.conf.prod /etc/nginx/nginx.conf

# Т.к. ассеты собраны в образе workspace и находятся на хосте, копируем из с хоста, 
# а не с builder_php_dev, что бы не добавлять лишнюю зависимость при сборке.
COPY app/public/ /var/www/html/public/

RUN mkdir -p /var/www/html/storage/app

FROM nginx_prod AS nginx_dev

COPY configs/nginx.conf.dev /etc/nginx/nginx.conf
