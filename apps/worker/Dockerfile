# VV Agenten-/Job-Worker — Stage-0-Skeleton (ADR-02/06/10). Reproduzierbar via npm ci.
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
CMD ["npm", "start"]
