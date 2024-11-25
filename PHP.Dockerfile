ARG DOCKER_FROM_IMAGE=php:8.1-fpm
FROM ${DOCKER_FROM_IMAGE}

ARG PHP_INI_ENVIRONMENT=production

ENV ETC_DIR=/usr/local/etc
ENV PHP_INI_DIR=$ETC_DIR/php
ENV PHP_INI_FILE_BASE=$PHP_INI_DIR/conf.d/php.ini
ENV PHP_INI_FILE=$PHP_INI_DIR/conf.d/moodle-php.ini

RUN echo "Building PHP version: $DOCKER_FROM_IMAGE for $PHP_INI_ENVIRONMENT environment"

# Update and install additional tools
RUN apt-get update && apt-get install --no-install-recommends -y \
    dos2unix \
    zlib1g-dev \
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
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

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
  && docker-php-ext-enable redis \
  xmlrpc  \
  && rm -rf /tmp/pear

RUN wget --progress=dot:giga -O /usr/local/bin/php-fpm-healthcheck \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
  && chmod +x /usr/local/bin/php-fpm-healthcheck \
  && wget -O $(which php-fpm-healthcheck) \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
  && chmod +x $(which php-fpm-healthcheck)

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_FILE_BASE"
COPY ./config/php/php.ini "$PHP_INI_DIR/conf.d/moodle-php.ini"
COPY ./config/php/php-fpm.conf "$ETC_DIR/php-fpm.d/php-fpm.conf"
RUN dos2unix "$ETC_DIR/php-fpm.d/php-fpm.conf"

# Add commands for site maintenance and upgrades
COPY ./config/moodle/enable-maintenance-mode.sh /usr/local/bin/enable-maintenance.sh
RUN dos2unix /usr/local/bin/enable-maintenance.sh
COPY ./openshift/scripts/moodle-upgrade.sh /usr/local/bin/moodle-upgrade.sh
RUN dos2unix /usr/local/bin/moodle-upgrade.sh
COPY ./openshift/scripts/migrate-build-files.sh /usr/local/bin/migrate-build-files.sh
RUN dos2unix /usr/local/bin/migrate-build-files.sh
COPY ./openshift/scripts/test-migration-complete.sh /usr/local/bin/test-migration-complete.sh
RUN dos2unix /usr/local/bin/test-migration-complete.sh
