ARG DOCKER_FROM_IMAGE=php:8.2-cli
FROM ${DOCKER_FROM_IMAGE}

# Environment uses ONLY production or development
ARG PHP_INI_ENVIRONMENT=production

# Moodle App directory
ENV MOODLE_APP_DIR=/var/www/html
ENV ETC_DIR=/usr/local/etc
ENV PHP_INI_DIR $ETC_DIR/php
# ENV PHP_INI_FILE=$PHP_INI_DIR/php.ini
ENV PHP_INI_FILE_BASE=$PHP_INI_DIR/conf.d/php.ini
ENV PHP_INI_FILE $ETC_DIR/php/conf.d/moodle-php.ini

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions pdo pdo_mysql mysqli gd soap intl zip xsl opcache ldap

RUN apt-get update && apt-get install -y --no-install-recommends dos2unix cron supervisor zlib1g-dev libpng-dev libxml2-dev libzip-dev libxslt-dev wget libfcgi-bin \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN pecl install -o -f redis &&  rm -rf /tmp/pear &&  docker-php-ext-enable redis

# Add healthcheck
RUN wget --progress=dot:giga -O /usr/local/bin/php-fpm-healthcheck \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
    && chmod +x /usr/local/bin/php-fpm-healthcheck
# Update healthcheck
RUN wget --progress=dot:giga -O "$(which php-fpm-healthcheck)" \
  https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
  && chmod +x $(which php-fpm-healthcheck)

# PHP configuration
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_FILE_BASE"
COPY ./config/php/php.ini "$PHP_INI_FILE"
RUN dos2unix "$PHP_INI_FILE"

# Cron scripts
COPY ./config/cron/cron.sh /usr/local/bin/cron.sh
RUN dos2unix /usr/local/bin/cron.sh

# Site maintenance and upgrade scripts
COPY ./config/moodle/enable-maintenance-mode.sh /usr/local/bin/enable-maintenance.sh
RUN dos2unix /usr/local/bin/enable-maintenance.sh
COPY ./openshift/scripts/moodle-upgrade.sh /usr/local/bin/moodle-upgrade.sh
RUN dos2unix /usr/local/bin/moodle-upgrade.sh

CMD ["/bin/bash", "/usr/local/bin/cron.sh"]
