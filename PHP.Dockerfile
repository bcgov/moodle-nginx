ARG DOCKER_FROM_IMAGE=php:8.2-fpm
FROM ${DOCKER_FROM_IMAGE}

ARG PHP_INI_ENVIRONMENT=production

ENV ETC_DIR=/usr/local/etc
ENV PHP_INI_DIR $ETC_DIR/php
ENV PHP_INI_FILE $PHP_INI_DIR/conf.d/moodle-php.ini

RUN echo "Building PHP version: $DOCKER_FROM_IMAGE for $PHP_INI_ENVIRONMENT environment"

# Update and install additional tools
RUN apt-get update && apt-get install --no-install-recommends -y \
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

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_FILE"
COPY ./config/php/php.ini "$PHP_INI_DIR/conf.d/moodle-php.ini"
COPY ./config/php/www.conf "$ETC_DIR/php-fpm.d/www.conf"

# Add commands for site maintenance / upgrades
COPY ./config/moodle/enable-maintenance-mode.sh /usr/local/bin/enable-maintenance.sh
COPY ./openshift/scripts/moodle-upgrade.sh /usr/local/bin/moodle-upgrade.sh
