FROM node:22-alpine

WORKDIR /app

COPY scripts/frontend/package.json .
RUN npm install

COPY scripts/frontend .

EXPOSE 3000

CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "3000"]
