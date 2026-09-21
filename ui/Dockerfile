FROM node:20-slim
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY . .
# curl needed for the container healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
EXPOSE 3000
CMD ["node", "server.js"]
