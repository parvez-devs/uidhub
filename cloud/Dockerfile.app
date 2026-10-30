FROM node:24-bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip gzip patch ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /srv
# Uses the existing public GitHub ZIP. Only application source files are copied;
# personal .replit, .git, .local and .config contents never enter the app layer.
RUN curl -fsSL --retry 3 https://raw.githubusercontent.com/parvez-devs/uidhub/main/xrixuid.zip -o /tmp/xrixuid.zip \
 && unzip -q /tmp/xrixuid.zip -d /tmp/xrixuid-source \
 && mkdir -p /srv/app \
 && cd /tmp/xrixuid-source/xrixuid \
 && cp -a artifacts lib scripts package.json pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json tsconfig.json /srv/app/ \
 && if test -f .npmrc; then cp .npmrc /srv/app/; fi \
 && rm -rf /tmp/xrixuid.zip /tmp/xrixuid-source
WORKDIR /srv/app
RUN curl -fsSL --retry 3 https://raw.githubusercontent.com/parvez-devs/uidhub/main/termux/uid-prefix.patch.gz.b64 -o /tmp/uid-prefix.gz.b64 \
 && base64 -d /tmp/uid-prefix.gz.b64 | gzip -dc | patch --batch --forward --fuzz=0 -p1 \
 && rm -f /tmp/uid-prefix.gz.b64
RUN npm install -g pnpm@10 && pnpm install --no-frozen-lockfile && PORT=3000 BASE_PATH=/ NODE_ENV=production pnpm run build:deploy

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /srv/app
COPY --from=builder /srv/app /srv/app
COPY cloud/supervisor.py /srv/supervisor.py
ENV NODE_ENV=production WEB_DIST=/srv/app/artifacts/uid-web/dist/public PORT=3000 CONTROL_PORT=9100
EXPOSE 3000
CMD ["python3", "-u", "/srv/supervisor.py"]
