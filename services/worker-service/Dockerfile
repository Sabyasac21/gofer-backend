FROM node:18-alpine

WORKDIR /app

COPY services/worker-service/package*.json ./

RUN npm install --omit=dev

COPY services/worker-service/src ./services/worker-service/src
COPY services/worker-service/scripts ./services/worker-service/scripts
COPY services/worker-service/package.json ./services/worker-service/package.json
COPY shared ./shared

WORKDIR /app/services/worker-service

EXPOSE 3003

CMD ["node", "src/index.js"]
