FROM nginx:alpine

RUN apk add --no-cache bash curl

# Copy Nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Report directories served as static content
RUN mkdir -p /usr/share/nginx/html/allure \
              /usr/share/nginx/html/sonar

# Landing page
COPY src/index.html /usr/share/nginx/html/index.html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
