# The website's image (#173): Bun builds the static pages, nginx serves them.
# Dokploy builds it from the repo root:
#   docker build -f apps/web/Dockerfile .
# The site's and the addon's addresses are build settings (build args here,
# Dokploy's build settings on the server), never in the repo.
FROM oven/bun:1.4.2 AS build
WORKDIR /app
# The package.json of every workspace, so the frozen lockfile matches.
COPY package.json bun.lock ./
COPY apps/addon/package.json apps/addon/
COPY apps/desktop/package.json apps/desktop/
COPY apps/server/package.json apps/server/
COPY apps/web/package.json apps/web/
COPY packages/api/package.json packages/api/
COPY packages/ui/package.json packages/ui/
RUN bun install --frozen-lockfile --filter @road-to-sixty/web
COPY tsconfig.base.json ./
COPY packages packages
COPY apps/web apps/web
ARG PUBLIC_SITE_URL
ARG PUBLIC_DOWNLOADS
ARG PUBLIC_ADDON_URL
ENV PUBLIC_SITE_URL=$PUBLIC_SITE_URL PUBLIC_DOWNLOADS=$PUBLIC_DOWNLOADS PUBLIC_ADDON_URL=$PUBLIC_ADDON_URL
RUN cd apps/web && bun run build

FROM nginx:1.28.0-alpine
# Only the site: not nginx's sample pages.
RUN rm -rf /usr/share/nginx/html/*
COPY apps/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/apps/web/dist /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
