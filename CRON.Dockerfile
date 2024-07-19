ARG DOCKER_FROM_IMAGE=php:8.3-cli
FROM ${DOCKER_FROM_IMAGE}

# Environment uses ONLY production or development
ARG PHP_INI_ENVIRONMENT=production

# Moodle App directory
ENV MOODLE_APP_DIR /var/www/html
ENV PHP_INI_DIR /usr/local/etc/php
ENV PHP_INI_FILE $PHP_INI_DIR/php.ini

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions pdo pdo_mysql mysqli gd soap intl zip xsl opcache ldap

RUN apt-get update && apt-get install -y --no-install-recommends cron supervisor zlib1g-dev libpng-dev libxml2-dev libzip-dev libxslt-dev wget libfcgi-bin \
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

RUN mv "$PHP_INI_DIR/php.ini-$PHP_INI_ENVIRONMENT" "$PHP_INI_FILE"
COPY ./config/php/php.ini "$PHP_INI_DIR/moodle-php.ini"
COPY ./config/php/php-fpm.conf "/usr/local/etc/php-fpm.d"

COPY ./config/cron/cron.sh /usr/local/bin/cron.sh
CMD ["/bin/bash", "/usr/local/bin/cron.sh"]
