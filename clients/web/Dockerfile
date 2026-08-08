# Aro's web client.
#
# The deployment target is Mercury: a 32-bit ARMv7 Raspberry Pi with 917 MB of RAM and
# four slow cores. Building Next.js there is not realistic, and building it under QEMU
# emulation on a Mac is barely better — so the build stage is pinned to the *native*
# builder platform and only the runtime stage is armv7. That works because a Next build
# emits JavaScript, which has no architecture: the slow part runs at full speed and only
# the finished output is carried across.
ARG NODE_IMAGE=node:22-bookworm-slim

FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS builder
WORKDIR /app

# Dependencies first, so a change to the app's own source does not re-resolve the tree.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM ${NODE_IMAGE} AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=4851 \
    HOSTNAME=0.0.0.0

RUN groupadd --system --gid 1001 aro \
    && useradd --system --uid 1001 --gid aro aro

# `output: "standalone"` traces the modules the server actually loads and writes a
# self-contained tree; static assets and `public/` are not traced and come across
# explicitly.
COPY --from=builder --chown=aro:aro /app/.next/standalone ./
COPY --from=builder --chown=aro:aro /app/.next/static ./.next/static
COPY --from=builder --chown=aro:aro /app/public ./public

USER aro
EXPOSE 4851

# Reports the process as healthy whether or not the hub is answering — the two are
# separate services, and restarting this one would not fix the other.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||4851)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
