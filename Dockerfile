FROM alpine:3.18

WORKDIR /app

RUN apk add --no-cache curl git openssl bash jq

RUN set -x && \
    curl -sSLo /tmp/gh.tar.gz https://github.com/cli/cli/releases/download/v2.39.1/gh_2.39.1_linux_amd64.tar.gz && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    cp /tmp/gh_2.39.1_linux_amd64/bin/gh /usr/local/bin/gh && \
    rm -rf /tmp/gh_2.39.1_linux_amd64 /tmp/gh.tar.gz && \
    gh --version

COPY entrypoint.sh .
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]