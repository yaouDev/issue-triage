FROM alpine:3.19

WORKDIR /app

RUN apk add --no-cache curl git openssl bash jq

RUN apk add --no-cache curl git openssl bash jq \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    tee /usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
    tee /etc/apk/respositories.d/github-cli.list > /dev/null \
    && apk update \
    && apk add gh

COPY entrypoint.sh .
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]