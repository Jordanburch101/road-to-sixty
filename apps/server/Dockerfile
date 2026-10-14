# The sync server's image (#1): Bun, standard Lua 5.1 for the merge, and
# the addon's shared Lua files. Dokploy builds it from the repo root:
#   docker build -f apps/server/Dockerfile .
FROM oven/bun:1.4.2
RUN apt-get update && apt-get install -y --no-install-recommends lua5.1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# The package.json of every workspace the server uses, so the frozen
# lockfile matches.
COPY package.json bun.lock ./
COPY apps/addon/package.json apps/addon/
COPY apps/server/package.json apps/server/
COPY packages/api/package.json packages/api/
COPY packages/ui/package.json packages/ui/
RUN bun install --frozen-lockfile --production
COPY packages/api packages/api
# The link page draws its fog with the shared UI code and serves its compass and font.
COPY packages/ui packages/ui
COPY apps/server apps/server
COPY apps/addon/RoadToSixty/Packed.lua apps/addon/RoadToSixty/Tidy.lua apps/addon/RoadToSixty/Parse.lua \
     apps/addon/RoadToSixty/Tally.lua apps/addon/RoadToSixty/Merge.lua /app/lua/
ENV NODE_ENV=production LUA51=lua5.1 LUA_DIR=/app/lua PORT=3000
USER bun
EXPOSE 3000
CMD ["bun", "apps/server/src/index.ts"]
