FROM nginx:alpine
LABEL org.opencontainers.image.source="https://github.com/yairm1/R-Devops-Home-Task"
RUN apk upgrade --no-cache && \
    apk add --no-cache git && \
    rm -rf /usr/share/nginx/html && \
    git clone --depth=1 https://github.com/gabrielecirulli/2048 /usr/share/nginx/html && \
    apk del git

EXPOSE 80
