ARG DOCKER_FROM_IMAGE=php:php:8.3.0-fpm
FROM ${DOCKER_FROM_IMAGE}

# Moodle Configs
ENV MOODLE_APP_DIR /app/public
ARG MOODLE_ENVIRONMENT=""

# PHP Configs
ENV ETC_DIR=/usr/local/etc
ENV PHP_INI_DIR $ETC_DIR/php
ENV PHP_INI_FILE $ETC_DIR/php/conf.d/moodle-php.ini
ARG PHP_INI_ENVIRONMENT=production

# Version control for Moodle and plugins
ARG MOODLE_BRANCH_VERSION=MOODLE_403_STABLE
ARG F2F_BRANCH_VERSION=MOODLE_400_STABLE
ARG HVP_BRANCH_VERSION=stable
ENV HVP_URL=" https://github.com/h5p/moodle-mod_hvp"
ENV HVP_DIR=$MOODLE_APP_DIR/mod/hvp
ARG FORMAT_BRANCH_VERSION=MOODLE_402
ENV FORMAT_URL="https://github.com/gjb2048/moodle-format_topcoll"
ENV FORMAT_DIR=$MOODLE_APP_DIR/course/format/topcoll
ARG CERTIFICATE_BRANCH_VERSION=MOODLE_31_STABLE
ARG CUSTOMCERT_BRANCH_VERSION=MOODLE_402_STABLE
ENV CUSTOMCERT_URL="https://github.com/mdjnelson/moodle-mod_customcert"
ENV CUSTOMCERT_DIR=$MOODLE_APP_DIR/mod/customcert
# ARG DATAFLOWS_BRANCH_VERSION=MOODLE_35_STABLE
# ENV DATAFLOWS_URL="https://github.com/catalyst/moodle-tool_dataflows.git"
# ENV DATAFLOWS_DIR=$MOODLE_APP_DIR/admin/tool/dataflows
# ENV TRIGGER_URL="https://github.com/catalyst/moodle-tool_trigger"
# ENV TRIGGER_DIR=$MOODLE_APP_DIR/admin/tool/trigger
# ENV F2F_URL="https://github.com/catalyst/moodle-mod_facetoface"
# ENV F2F_DIR=$MOODLE_APP_DIR/mod/facetoface
# ENV CERTIFICATE_URL=" https://github.com/mdjnelson/moodle-mod_certificate"
# ENV CERTIFICATE_DIR=$MOODLE_APP_DIR/mod/certificate

RUN echo "Building Moodle version: $MOODLE_BRANCH_VERSION for $PHP_INI_ENVIRONMENT environment"

RUN apt-get update && apt-get install --no-install-recommends -y \
    git \
    zlib1g-dev \
    libpng-dev \
    libxml2-dev \
    libzip-dev \
    libxslt-dev \
    libldap-dev \
    libfreetype-dev \
    wget \
    libfcgi-bin \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --recurse-submodules --jobs 8 --branch $MOODLE_BRANCH_VERSION --single-branch https://github.com/moodle/moodle $MOODLE_APP_DIR

COPY ./config/moodle/${MOODLE_ENVIRONMENT}.config.php "$MOODLE_APP_DIR/config.php"
# Add PHP info (debugging)
RUN mkdir $MOODLE_APP_DIR/info
COPY ./config/php/info.php "$MOODLE_APP_DIR/info/info.php"
# Add PHP config check (security)
COPY ./config/php/phpconfigcheck.php "$MOODLE_APP_DIR/info/phpconfigcheck.php"

# Add all plugin folders to a list, so we can clean them up later
RUN echo $DATAFLOWS_DIR >> $MOODLE_APP_DIR/plugin-folders.txt && \
    # echo $TRIGGER_DIR > $MOODLE_APP_DIR/plugin-folders.txt && \
    # echo $F2F_DIR >> $MOODLE_APP_DIR/plugin-folders.txt && \
    echo $HVP_DIR >> $MOODLE_APP_DIR/plugin-folders.txt && \
    echo $FORMAT_DIR >> $MOODLE_APP_DIR/plugin-folders.txt && \
    echo $CUSTOMCERT_DIR >> $MOODLE_APP_DIR/plugin-folders.txt
    # echo $CERTIFICATE_DIR >> $MOODLE_APP_DIR/plugin-folders.txt

RUN mkdir -p $HVP_DIR  && \
  # mkdir -p $DATAFLOWS_DIR && \
  # mkdir -p $TRIGGER_DIR && \
  # mkdir -p $F2F_DIR && \
    mkdir -p $FORMAT_DIR  && \
  # mkdir -p $CERTIFICATE  && \
    mkdir -p $CUSTOMCERT_DIR  && \
    chown -R www-data:www-data $MOODLE_APP_DIR

RUN git clone --recurse-submodules --jobs 8 --branch $HVP_BRANCH_VERSION --single-branch $HVP_URL $HVP_DIR && \
  # git clone --recurse-submodules --jobs 8 --branch $DATAFLOWS_BRANCH_VERSION --single-branch $DATAFLOWS_URL $DATAFLOWS_DIR && \
  # git clone --recurse-submodules --jobs 8 $TRIGGER_URL $TRIGGER_DIR && \
  # git clone --recurse-submodules --jobs 8 --branch $F2F_BRANCH_VERSION --single-branch $F2F_URL $F2F_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $FORMAT_BRANCH_VERSION --single-branch $FORMAT_URL $FORMAT_DIR && \
    git clone --recurse-submodules --jobs 8 --branch $CUSTOMCERT_BRANCH_VERSION --single-branch $CUSTOMCERT_URL $CUSTOMCERT_DIR
  # git clone --recurse-submodules --jobs 8 --branch $CERTIFICATE_BRANCH_VERSION --single-branch $CERTIFICATE_URL $CERTIFICATE_DIR

# Add commands for site upgrades / migrations
COPY ./config/moodle/moodle_index_during_maintenance.php /tmp/moodle_index_during_maintenance.php
COPY ./openshift/scripts/migrate-build-files.sh /usr/local/bin/migrate-build-files.sh
COPY ./openshift/scripts/test-migration-complete.sh /usr/local/bin/test-migration-complete.sh
