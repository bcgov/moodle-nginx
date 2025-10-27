ARG DOCKER_FROM_IMAGE=php:8.1-fpm
FROM ${DOCKER_FROM_IMAGE}

# Moodle Configs
ENV MOODLE_APP_DIR=/app/public
ARG DEPLOY_ENVIRONMENT="remote"

# PHP Configs
ENV ETC_DIR=/usr/local/etc
ENV PHP_INI_DIR=$ETC_DIR/php
ENV PHP_INI_FILE=$ETC_DIR/php/conf.d/moodle-php.ini
ARG PHP_INI_ENVIRONMENT=production
ENV GIT_SSL_NO_VERIFY=1

# Version control for Moodle and plugins
ARG MOODLE_URL="https://github.com/moodle/moodle"
ARG MOODLE_BRANCH_VERSION=MOODLE_401_STABLE
ARG PSAELMSYNC_URL="https://github.com/bcgov/psaelmsync"
ARG PSAELMSYNC_BRANCH_VERSION=main
ENV PSAELMSYNC_DIR=$MOODLE_APP_DIR/local/psaelmsync

ARG THEME_URL="https://github.com/bcgov/bcgovpsa-moodle"
ARG THEME_BRANCH_VERSION=main
ENV THEME_DIR=$MOODLE_APP_DIR/theme/bcgovpsa
ARG HVP_URL=" https://github.com/h5p/moodle-mod_hvp"
ARG HVP_BRANCH_VERSION=stable
ENV HVP_DIR=$MOODLE_APP_DIR/mod/hvp
ARG REPORT_ALL_BACKUPS_URL="https://github.com/catalyst/moodle-report_allbackups"
ARG REPORT_ALL_BACKUPS_BRANCH_VERSION=MOODLE_400_STABLE
ENV REPORT_ALL_BACKUPS_DIR=$MOODLE_APP_DIR/report/allbackups

RUN echo "Building Moodle version: $MOODLE_BRANCH_VERSION for $PHP_INI_ENVIRONMENT environment for a $DEPLOY_ENVIRONMENT deployment"

RUN apt-get update && apt-get install --no-install-recommends -y \
    dos2unix \
    git \
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

RUN echo "Building to directory: $MOODLE_APP_DIR"

RUN mkdir -p $MOODLE_APP_DIR
RUN git config --global http.postBuffer 157286400
RUN git config --global http.version HTTP/1.1
RUN git config --global core.compression 0
RUN git clone --depth=1 --jobs 12 --branch $MOODLE_BRANCH_VERSION --recurse-submodules --single-branch $MOODLE_URL $MOODLE_APP_DIR

WORKDIR $MOODLE_APP_DIR
RUN git fetch --unshallow
RUN git pull --all

COPY ./config/moodle/$DEPLOY_ENVIRONMENT.config.php "$MOODLE_APP_DIR/config.php"
# Add PHP info (debugging)
RUN mkdir $MOODLE_APP_DIR/info
COPY ./config/php/info.php "$MOODLE_APP_DIR/info/info.php"
# Add PHP config check (security)
COPY ./config/php/phpconfigcheck.php "$MOODLE_APP_DIR/info/phpconfigcheck.php"

# Add favicon
COPY ./config/moodle/favicon.ico "$MOODLE_APP_DIR/favicon.ico"

RUN mkdir -p $PSAELMSYNC_DIR
RUN mkdir -p $PCURATOR_DIR
RUN mkdir -p $COURSESEARCH_DIR

RUN git clone --depth=1 --recurse-submodules --jobs 8 --branch $PSAELMSYNC_BRANCH_VERSION --single-branch $PSAELMSYNC_URL $PSAELMSYNC_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $THEME_BRANCH_VERSION --single-branch $THEME_URL $THEME_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $PCURATOR_BRANCH_VERSION --single-branch $PCURATOR_URL $PCURATOR_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $COURSESEARCH_BRANCH_VERSION --single-branch $COURSESEARCH_URL $COURSESEARCH_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $HVP_BRANCH_VERSION --single-branch $HVP_URL $HVP_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $REPORT_ALL_BACKUPS_BRANCH_VERSION --single-branch $REPORT_ALL_BACKUPS_URL $REPORT_ALL_BACKUPS_DIR

# Install Composer (if not already present)
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
rm composer-setup.php

# Install ZipStream library for Moodle plugins
RUN composer require maennchen/zipstream-php:"^2.1" --with-all-dependencies
RUN composer install --no-dev --optimize-autoloader

COPY ./config/moodle/enable-maintenance-mode.sh /usr/local/bin/enable-maintenance.sh
RUN dos2unix /usr/local/bin/enable-maintenance.sh
COPY ./config/moodle/moodle_index_during_maintenance.php /tmp/moodle_index_during_maintenance.php
COPY ./openshift/scripts/migrate-build-files.sh /usr/local/bin/migrate-build-files.sh

# Add utility functions
COPY ./openshift/scripts/_utils.sh /usr/local/bin/_utils.sh
COPY ./openshift/scripts/utils/moodle.sh /usr/local/bin/utils/moodle.sh
COPY ./openshift/scripts/utils/database.sh /usr/local/bin/utils/database.sh
COPY ./openshift/scripts/utils/openshift.sh /usr/local/bin/utils/openshift.sh
COPY ./openshift/scripts/utils/redis.sh /usr/local/bin/utils/redis.sh
COPY ./openshift/scripts/test-migration-complete.sh /usr/local/bin/test-migration-complete.sh

RUN chmod +x /usr/local/bin/migrate-build-files.sh && \
	dos2unix /usr/local/bin/migrate-build-files.sh && \
  chmod +x /usr/local/bin/_utils.sh && \
	dos2unix /usr/local/bin/_utils.sh && \
  chmod +x /usr/local/bin/utils/moodle.sh && \
  dos2unix /usr/local/bin/utils/moodle.sh && \
  chmod +x /usr/local/bin/utils/database.sh && \
  dos2unix /usr/local/bin/utils/database.sh && \
  chmod +x /usr/local/bin/utils/openshift.sh && \
  dos2unix /usr/local/bin/utils/openshift.sh && \
  chmod +x /usr/local/bin/utils/redis.sh && \
  dos2unix /usr/local/bin/utils/redis.sh && \
  chmod +x /usr/local/bin/test-migration-complete.sh && \
  dos2unix /usr/local/bin/test-migration-complete.sh

RUN chown -R www-data:www-data $MOODLE_APP_DIR
