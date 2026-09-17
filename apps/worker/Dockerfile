# VV Agenten-/Job-Worker — Stage-0-Skeleton (ADR-02/06/10). Läuft via tsx.
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY . .
CMD ["npm", "start"]
