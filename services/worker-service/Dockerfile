FROM node:18-alpine

WORKDIR /app

COPY services/worker-service/package*.json ./

RUN npm install --omit=dev

COPY services/worker-service/src ./services/worker-service/src
COPY shared ./shared

EXPOSE 3003

CMD ["node", "services/worker-service/src/index.js"]
