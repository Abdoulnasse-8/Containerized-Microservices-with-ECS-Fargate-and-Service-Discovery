FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src
ARG APP_VERSION=v1
ENV NODE_ENV=production PORT=3000 APP_VERSION=$APP_VERSION
USER node
EXPOSE 3000
CMD ["node", "src/index.js"]
