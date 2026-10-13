# The sync server's image (#1): Bun, standard Lua 5.1 for the merge, and
# the addon's shared Lua files. Dokploy builds it from the repo root:
#   docker build -f apps/server/Dockerfile .
FROM oven/bun:1.4.2
RUN apt-get update && apt-get install -y --no-install-recommends lua5.1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# Every workspace's package.json, so the frozen lockfile matches.
COPY package.json bun.lock ./
COPY apps/addon/package.json apps/addon/
COPY apps/server/package.json apps/server/
COPY packages/api/package.json packages/api/
RUN bun install --frozen-lockfile --production
COPY packages/api packages/api
COPY apps/server apps/server
COPY apps/addon/RoadToSixty/Packed.lua apps/addon/RoadToSixty/Tidy.lua apps/addon/RoadToSixty/Parse.lua \
     apps/addon/RoadToSixty/Tally.lua apps/addon/RoadToSixty/Merge.lua /app/lua/
ENV NODE_ENV=production LUA51=lua5.1 LUA_DIR=/app/lua PORT=3000
USER bun
EXPOSE 3000
CMD ["bun", "apps/server/src/index.ts"]
