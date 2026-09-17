# VV Web/API — Stage-0-Skeleton (ADR-02/10). Läuft via tsx, kein Build-Schritt nötig.
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY . .
EXPOSE 3000
CMD ["npm", "start"]
