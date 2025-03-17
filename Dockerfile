# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.21 AS base
ENV TZ=UTC
WORKDIR /src

# source stage =================================================================
FROM base AS source

# get and extract source from git (must use only one or another build-args)
ARG BRANCH
ARG VERSION
ADD https://github.com/traefik/traefik/archive/refs/${BRANCH:+heads/$BRANCH}${VERSION:+tags/v$VERSION}.tar.gz /tmp/source.tgz
RUN tar --strip-components=1 -xf /tmp/source.tgz

# frontend stage ===============================================================
FROM base AS build-frontend

# dependencies
RUN apk add --no-cache yarn

# node_modules
COPY --from=source /src/webui/package.json /src/webui/yarn.lock ./
RUN yarn install --frozen-lockfile --network-timeout 120000

# frontend source and build
COPY --from=source /src/webui ./
RUN yarn build --env production --no-stats

# build stage ==================================================================
FROM base AS build-backend
ENV CGO_ENABLED=0

# dependencies
RUN apk add --no-cache git libcap-utils && \
    apk add --no-cache go --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

# build dependencies
COPY --from=source /src/go.mod /src/go.sum ./
RUN go mod download

# build app
COPY --from=source /src/cmd ./cmd
COPY --from=source /src/pkg ./pkg
COPY --from=source /src/init ./init
COPY --from=source /src/internal ./internal
COPY --from=source /src/integration ./integration
COPY --from=source /src/webui/embed.go ./webui/
COPY --from=build-frontend /src/static ./webui/static
ARG VERSION
RUN mkdir /build && \
    go build -trimpath -ldflags "-s -w \
        -X github.com/traefik/traefik/v3/pkg/version.Version=$VERSION \
        -X github.com/traefik/traefik/v3/pkg/version.Codename=cheddar \
        -X github.com/traefik/traefik/v3/pkg/version.BuildDate=$(date -u '+%Y-%m-%d_%I:%M:%S%p')" \
        -o /build/ ./cmd/traefik && \
    setcap cap_net_bind_service+eip /build/traefik

# runtime stage ================================================================
FROM base

ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534
ENV HOME=/config
WORKDIR /config
VOLUME /config
EXPOSE 80 443

# copy files
COPY --from=build-backend /build /app
COPY ./rootfs/. /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay logrotate curl

# run using s6-overlay
ENTRYPOINT ["/init"]
