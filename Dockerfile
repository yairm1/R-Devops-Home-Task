FROM nginx:alpine

RUN apk add --no-cache git && \
    rm -rf /usr/share/nginx/html && \
    git clone --depth=1 https://github.com/gabrielecirulli/2048 /usr/share/nginx/html && \
    apk del git

EXPOSE 80
