# chosen to be minimal - are there other benefits to consider?
FROM alpine:3.18

WORKDIR /app

# github cli
RUN apk add --no-cache curl git openssl
RUN curl -sSLo /usr/local/bin/gh https://github.com/cli/cli/releases/download/v2.30.0/gh_2.30.0_linux_amd64.tar.gz && \
    tar zxf /usr/local/bin/gh -C /tmp && \
    mv /tmp/gh_2.30.0_linux_amd64/bin/gh /usr/local/bin/gh && \
    rm -rf /tmp/gh_2.30.0_linux_amd64 /usr/local/bin/gh

COPY entrypoint.sh .
RUN sed -i 's/\r$//' /app/entrypoint.sh
RUN chmod +x entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
