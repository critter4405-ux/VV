# VV Agenten-/Job-Worker — Stage-0-Skeleton (ADR-02/06/10). Reproduzierbar via npm ci.
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# Heartbeat-Ordner (Healthcheck) — eigener Ordner statt /tmp, nur für den Prozess-Nutzer.
RUN mkdir -p /run/vv-worker && chmod 700 /run/vv-worker
CMD ["npm", "start"]
