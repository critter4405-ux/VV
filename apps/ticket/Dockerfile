# VV Ticket-Dienst (C-1, Grill P58). Zustandslos, eigener Container, nur internes Netz.
# Der HMAC-Schlüssel kommt ausschließlich als Docker-Secret (/run/secrets/ticket_keyring) — nie per Umgebung/Image.
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund --omit=dev
COPY . .
USER node
EXPOSE 8081
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD wget -qO- http://127.0.0.1:8081/health || exit 1
CMD ["npx", "tsx", "src/index.ts"]
