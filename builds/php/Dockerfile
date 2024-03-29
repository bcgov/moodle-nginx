# FROM artifacts.developer.gov.bc.ca/docker-remote/php:7.4-fpm
# PHP 8.1 is required for PECL
# artifacts.developer.gov.bc.ca/docker-remote/php:7.4-fpm
ARG PHP_IMAGE=php:8.0-fpm

FROM $PHP_IMAGE

# Config arguments
ARG DB_PORT=3306
ARG DB_HOST=${DB_HOST}
ARG DB_NAME=${DB_NAME}
ARG DB_PASSWORD=${DB_PASSWORD}
ARG DB_USER=${DB_USER}
ARG ETC_DIR=/usr/local/etc

# Version control for Moodle and plugins
ARG MOODLE_BRANCH_VERSION=MOODLE_311_STABLE
ARG F2F_BRANCH_VERSION=MOODLE_311_STABLE
ARG HVP_BRANCH_VERSION=stable
ARG FORMAT_BRANCH_VERSION=MOODLE_311
ARG CERTIFICATE_BRANCH_VERSION=MOODLE_31_STABLE
ARG CUSTOMCERT_BRANCH_VERSION=MOODLE_311_STABLE
ARG DATAFLOWS_BRANCH_VERSION=MOODLE_35_STABLE

# ENV MOODLE_BRANCH_VERSION MOODLE_311_STABLE
# ENV F2F_BRANCH_VERSION MOODLE_311_STABLE
# ENV HVP_BRANCH_VERSION stable
# ENV FORMAT_BRANCH_VERSION MOODLE_311
# ENV CERTIFICATE_BRANCH_VERSION MOODLE_31_STABLE
# ENV CUSTOMCERT_BRANCH_VERSION MOODLE_311_STABLE
# ENV DATAFLOWS_BRANCH_VERSION MOODLE_35_STABLE

# Moodle App directory.
# Build dir is used to aid in sharing app with other pods.
# Build then copy to final (PVC) destination upon deployment in OpenShift.
ENV DOCKER_CONTEXT /builds/php
ENV MOODLE_BUILD_BASE_DIR /app
ENV MOODLE_BUILD_DIR $MOODLE_BUILD_BASE_DIR/public
ENV MOODLE_VAR_DIR /var/www
ENV MOODLE_APP_DIR $MOODLE_VAR_DIR/html
ENV MOODLE_DATA_DIR $MOODLE_VAR_DIR/moodledata
ENV CONF_FILE $MOODLE_BUILD_DIR/config.php
ENV PHP_FPM_DIR $ETC_DIR/php-fpm.d
ENV PHP_INI_FILE $ETC_DIR/php/conf.d/moodle-php.ini

RUN mkdir -p $MOODLE_BUILD_BASE_DIR
RUN chown -R www-data:www-data $MOODLE_BUILD_BASE_DIR
RUN mkdir -p $MOODLE_BUILD_DIR
RUN chown -R www-data:www-data $MOODLE_BUILD_DIR
RUN mkdir -p $MOODLE_DATA_DIR
RUN chown -R www-data:www-data $MOODLE_DATA_DIR

RUN apt-get update && apt-get install -y mariadb-client-10.5 rsync git zlib1g-dev libpng-dev libxml2-dev libzip-dev libxslt-dev libldap-dev
RUN pecl install channel://pecl.php.net/xmlrpc-1.0.0RC3
RUN docker-php-ext-enable xmlrpc
RUN docker-php-ext-install pdo pdo_mysql mysqli gd soap intl zip xsl opcache ldap
RUN pecl install -o -f redis
RUN rm -rf /tmp/pear
RUN docker-php-ext-enable redis

RUN pecl install xdebug
RUN docker-php-ext-enable xdebug

RUN apt-get update

RUN git clone --recurse-submodules --jobs 8 --branch $MOODLE_BRANCH_VERSION --single-branch https://github.com/moodle/moodle $MOODLE_BUILD_DIR

COPY $DOCKER_CONTEXT/php.ini $PHP_INI_FILE
COPY $DOCKER_CONTEXT/php-fpm.conf $PHP_FPM_DIR
COPY $DOCKER_CONTEXT/favicon.ico $MOODLE_BUILD_DIR

RUN mkdir -p $MOODLE_BUILD_DIR/admin/tool/trigger && \
    mkdir -p $MOODLE_BUILD_DIR/admin/tool/dataflows && \
    mkdir -p $MOODLE_BUILD_DIR/mod/facetoface && \
    mkdir -p $MOODLE_BUILD_DIR/mod/hvp  && \
    mkdir -p $MOODLE_BUILD_DIR/course/format/topcoll  && \
    mkdir -p $MOODLE_BUILD_DIR/mod/certificate  && \
    mkdir -p $MOODLE_BUILD_DIR/mod/customcert  && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/admin/tool/ && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/mod/ && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/course/format/ && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/admin/tool/trigger && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/admin/tool/dataflows && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/mod/facetoface && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/mod/hvp && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/course/format/topcoll && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/mod/certificate && \
    chown -R www-data:www-data $MOODLE_BUILD_DIR/mod/customcert

RUN git clone --recurse-submodules --jobs 8 https://github.com/catalyst/moodle-tool_trigger $MOODLE_BUILD_DIR/admin/tool/trigger && \
    git clone --recurse-submodules --jobs 8 --branch $DATAFLOWS_BRANCH_VERSION --single-branch https://github.com/catalyst/moodle-tool_dataflows.git $MOODLE_BUILD_DIR/admin/tool/dataflows && \
    git clone --recurse-submodules --jobs 8 --branch $F2F_BRANCH_VERSION --single-branch https://github.com/catalyst/moodle-mod_facetoface $MOODLE_BUILD_DIR/mod/facetoface && \
    git clone --recurse-submodules --jobs 8 --branch $HVP_BRANCH_VERSION --single-branch https://github.com/h5p/moodle-mod_hvp $MOODLE_BUILD_DIR/mod/hvp && \
    git clone --recurse-submodules --jobs 8 --branch $FORMAT_BRANCH_VERSION --single-branch https://github.com/gjb2048/moodle-format_topcoll $MOODLE_BUILD_DIR/course/format/topcoll && \
    git clone --recurse-submodules --jobs 8 --branch $CERTIFICATE_BRANCH_VERSION --single-branch https://github.com/mdjnelson/moodle-mod_certificate $MOODLE_BUILD_DIR/mod/certificate && \
    git clone --recurse-submodules --jobs 8 --branch $CUSTOMCERT_BRANCH_VERSION --single-branch https://github.com/mdjnelson/moodle-mod_customcert $MOODLE_BUILD_DIR/mod/customcert

# Copy Moodle config
COPY --chown=www-data:www-data $DOCKER_CONTEXT/moodle-config.php $CONF_FILE

# Update config with vars
RUN sed -i "s|DB_PORT|${DB_PORT}|" $CONF_FILE  && \
  sed -i "s|DB_PORT|${DB_PORT}|" $CONF_FILE  && \
  sed -i "s|DB_HOST|${DB_HOST}|" $CONF_FILE  && \
  sed -i "s|DB_NAME|${DB_NAME}|" $CONF_FILE  && \
  sed -i "s|DB_USER|${DB_USER}|" $CONF_FILE  && \
  sed -i "s|DB_PASSWORD|${DB_PASSWORD}|" $CONF_FILE  && \
  sed -i "s|MOODLE_APP_DIR|${MOODLE_APP_DIR}|" $CONF_FILE  && \
  sed -i "s|MOODLE_DATA_DIR|${MOODLE_DATA_DIR}|" $CONF_FILE  && \
  sed -i "s|SITE_URL|${SITE_URL}|" $CONF_FILE

COPY --chown=www-data:www-data .$DOCKER_CONTEXT/healthcheck $MOODLE_BUILD_DIR/healthcheck
# USER www-data
# CMD ["php-fpm"]
# ENTRYPOINT ["docker-php-entrypoint"]
# CMD ["php-fpm"]
