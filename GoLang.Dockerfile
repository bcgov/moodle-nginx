ARG GOLANG_FROM_IMAGE=golang:1.12
ARG UBUNTU_FROM_IMAGE=ubuntu:24.04
ARG DEPLOY_ENVIRONMENT="remote"

FROM ${GOLANG_FROM_IMAGE} AS builder

RUN go get github.com/RedisLabs/sentinel_tunnel

FROM ${UBUNTU_FROM_IMAGE}
COPY --from=builder /go/bin/sentinel_tunnel /usr/local/bin/
COPY ./config/redis/entrypoint /usr/local/bin
RUN mkdir /etc/sentinel_tunnel && \
    chown www-data /etc/sentinel_tunnel && \
    chmod g+rwx /etc/sentinel_tunnel && \
    apt update && \
    apt install --assume-yes --no-install-recommends redis-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY ./config/redis/sentinel_tunnel.$DEPLOY_ENVIRONMENT.config.json /etc/sentinel_tunnel/config.json

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["/usr/local/bin/sentinel_tunnel", "/etc/sentinel_tunnel/config.json", "/dev/stdout"]

USER www-data
