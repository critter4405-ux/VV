# VV Web/API — Stage-0-Skeleton (ADR-02/10). Reproduzierbar via npm ci (Lockfile).
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
EXPOSE 3000
CMD ["npm", "start"]
