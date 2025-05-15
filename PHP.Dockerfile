ARG DOCKER_FROM_IMAGE=php:8.1-fpm
FROM ${DOCKER_FROM_IMAGE}

ARG PHP_INI_ENVIRONMENT=production

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

ENV ETC_DIR=/usr/local/etc
ENV PHP_INI_DIR=$ETC_DIR/php
ENV PHP_INI_FILE_BASE=$PHP_INI_DIR/conf.d/php.ini
ENV MOODLE_PHP_INI_FILE=$PHP_INI_DIR/conf.d/moodle-php.ini
ENV PHP_INI_FILE=$PHP_INI_DIR/conf.d/moodle-php.ini
ENV PHP_FPM_CONF_FILE=$ETC_DIR/php-fpm.d/zz-docker.conf

RUN echo "Building PHP version: $DOCKER_FROM_IMAGE for $PHP_INI_ENVIRONMENT environment"

# Update and install additional tools
RUN apt-get update && apt-get install --no-install-recommends -y \
    dos2unix \
    zlib1g-dev \
    libssl-dev \
    libpng-dev \
    libxml2-dev \
    libzip-dev \
    libxslt-dev \
    libldap-dev \
    libfreetype-dev \
    wget \
    libfcgi-bin \
    libonig-dev \
    rsync \
    memcached \
    libmemcached-dev

RUN yes '' | pecl install -f memcached-3.3.0 \
  && docker-php-ext-enable memcached

RUN apt-get upgrade -y
RUN apt-get autoremove -y
RUN apt-get clean
RUN rm -rf /var/lib/apt/lists/*

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
    apcu \
    gd \
    xmlrpc \
    pdo \
    pdo_mysql \
    mysqli \
    soap \
    intl \
    zip \
    xsl \
    opcache \
    ldap \
    exif \
    mbstring

RUN pecl install -o -f redis \
  && pecl install -o -f igbinary \
  && docker-php-ext-enable redis \
  && docker-php-ext-enable igbinary \
    igbinary \
    xmlrpc  \
  && rm -rf /tmp/pear

RUN wget --progress=dot:giga -O /usr/local/bin/php-fpm-healthcheck \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
  && chmod +x /usr/local/bin/php-fpm-healthcheck \
  && wget -O $(which php-fpm-healthcheck) \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
  && chmod +x $(which php-fpm-healthcheck)

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_FILE_BASE"
COPY ./config/php/php.ini "$MOODLE_PHP_INI_FILE"
RUN dos2unix "$MOODLE_PHP_INI_FILE"
# COPY ./config/php/php-fpm.conf "$PHP_FPM_CONF_FILE"
# RUN dos2unix "$PHP_FPM_CONF_FILE"

# Add commands for site maintenance and upgrades
COPY ./config/moodle/enable-maintenance-mode.sh /usr/local/bin/enable-maintenance.sh
RUN dos2unix /usr/local/bin/enable-maintenance.sh
COPY ./openshift/scripts/moodle-upgrade.sh /usr/local/bin/moodle-upgrade.sh
RUN dos2unix /usr/local/bin/moodle-upgrade.sh
COPY ./openshift/scripts/migrate-build-files.sh /usr/local/bin/migrate-build-files.sh
RUN dos2unix /usr/local/bin/migrate-build-files.sh
COPY ./openshift/scripts/_utils.sh /usr/local/bin/_utils.sh
RUN dos2unix /usr/local/bin/_utils.sh
COPY ./openshift/scripts/test-migration-complete.sh /usr/local/bin/test-migration-complete.sh
RUN dos2unix /usr/local/bin/test-migration-complete.sh

# Install Composer (if not already present)
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
  rm composer-setup.php

# Install ZipStream library for Moodle plugins
RUN composer require maennchen/zipstream-php
