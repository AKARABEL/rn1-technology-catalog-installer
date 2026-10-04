#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CONFIGURE ONLY THIS SECTION
###############################################################################

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"

# General
TZ="Europe/Berlin"
BASEURL="http://catalog-web"

# Enable / Disable optional services
INSTALL_NGINX_PROXY_MANAGER="true"

# Image Tags
NGINX_PROXY_MANAGER_TAG="latest"
OPENSEARCH_TAG="2"
OPENSEARCH_DASHBOARDS_TAG="2"
MONGO_TAG="8"
MINIO_TAG="latest"
RABBITMQ_TAG="3-management-alpine"

CATALOG_VERSION="25.4.4191.133"
CATALOG_IMAGE_REPO="raynetgmbh/rayventory-catalog"
CATALOG_WORKER_IMAGE_REPO="raynetgmbh/rayventory-catalog-worker"

# Mongo
MONGO_INITDB_ROOT_USERNAME="raymaster_rc"
MONGO_INITDB_DATABASE="raymaster_rc"
MONGO_AUTH_DATABASE="admin"
MONGO_PORT_HOST="27017"

# MinIO
MINIO_ROOT_USER="rvc"
MINIO_API_PORT_HOST="9001"
MINIO_CONSOLE_PORT_HOST="9002"
MINIO_PORT_CONTAINER="9000"

# RabbitMQ
RABBITMQ_DEFAULT_USER="rvc"
RABBITMQ_AMQP_PORT="5672"
RABBITMQ_UI_PORT="15672"

# Catalog / App
CATALOG_WEB_PORT="8080"
CATALOG_LICENSE_PATH="/app/license"

# OpenSearch
OPENSEARCH_HEAP="-Xms512m -Xmx512m"
OPENSEARCH_URL="http://opensearch:9200"
OPENSEARCH_DASHBOARDS_PORT="5601"

# Nginx Proxy Manager
NPM_HTTP_PORT="80"
NPM_HTTPS_PORT="443"
NPM_ADMIN_PORT="81"
X_FRAME_OPTIONS="sameorigin"
DISABLE_IPV6="true"

# Shared app config
QUEUE_PREFIX="rvc"
FILESTORAGE_BUCKET="rvc"
FILESTORAGE_LOCATION="local"
AUTOSYNC_CRON="30 7 * * *"
VULNERABILITIES_CACHING_CRON="-"
ASPNETCORE_URLS="http://+:80"
ASPNETCORE_HTTP_PORTS="80"
LOG_LEVEL_DEFAULT="Information"

###############################################################################
# DO NOT CHANGE ANYTHING BELOW
###############################################################################

rand32() {
  set +o pipefail
  local v
  v="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  set -o pipefail
  printf '%s' "$v"
}

echo "Generating passwords..."
MONGO_INITDB_ROOT_PASSWORD="$(rand32)"
MINIO_ROOT_PASSWORD="$(rand32)"
RABBITMQ_DEFAULT_PASS="$(rand32)"

echo "Writing ${ENV_FILE}..."
cat > "$ENV_FILE" <<EOF
# General
TZ=${TZ}
BASEURL=${BASEURL}

# Enable / Disable optional services
INSTALL_NGINX_PROXY_MANAGER=${INSTALL_NGINX_PROXY_MANAGER}

# Image Tags
NGINX_PROXY_MANAGER_TAG=${NGINX_PROXY_MANAGER_TAG}
OPENSEARCH_TAG=${OPENSEARCH_TAG}
OPENSEARCH_DASHBOARDS_TAG=${OPENSEARCH_DASHBOARDS_TAG}
MONGO_TAG=${MONGO_TAG}
MINIO_TAG=${MINIO_TAG}
RABBITMQ_TAG=${RABBITMQ_TAG}
CATALOG_IMAGE=${CATALOG_IMAGE_REPO}:${CATALOG_VERSION}
CATALOG_WORKER_IMAGE=${CATALOG_WORKER_IMAGE_REPO}:${CATALOG_VERSION}

# Mongo
MONGO_INITDB_ROOT_USERNAME=${MONGO_INITDB_ROOT_USERNAME}
MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD}
MONGO_INITDB_DATABASE=${MONGO_INITDB_DATABASE}
MONGO_AUTH_DATABASE=${MONGO_AUTH_DATABASE}
MONGO_PORT_HOST=${MONGO_PORT_HOST}

# MinIO
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_API_PORT_HOST=${MINIO_API_PORT_HOST}
MINIO_CONSOLE_PORT_HOST=${MINIO_CONSOLE_PORT_HOST}
MINIO_PORT_CONTAINER=${MINIO_PORT_CONTAINER}

# RabbitMQ
RABBITMQ_DEFAULT_USER=${RABBITMQ_DEFAULT_USER}
RABBITMQ_DEFAULT_PASS=${RABBITMQ_DEFAULT_PASS}
RABBITMQ_AMQP_PORT=${RABBITMQ_AMQP_PORT}
RABBITMQ_UI_PORT=${RABBITMQ_UI_PORT}

# Catalog / App
CATALOG_WEB_PORT=${CATALOG_WEB_PORT}
CATALOG_LICENSE_PATH=${CATALOG_LICENSE_PATH}

# OpenSearch
OPENSEARCH_HEAP=${OPENSEARCH_HEAP}
OPENSEARCH_URL=${OPENSEARCH_URL}
OPENSEARCH_DASHBOARDS_PORT=${OPENSEARCH_DASHBOARDS_PORT}

# Nginx Proxy Manager
NPM_HTTP_PORT=${NPM_HTTP_PORT}
NPM_HTTPS_PORT=${NPM_HTTPS_PORT}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
X_FRAME_OPTIONS=${X_FRAME_OPTIONS}
DISABLE_IPV6=${DISABLE_IPV6}

# Shared app config
QUEUE_PREFIX=${QUEUE_PREFIX}
FILESTORAGE_BUCKET=${FILESTORAGE_BUCKET}
FILESTORAGE_LOCATION=${FILESTORAGE_LOCATION}
AUTOSYNC_CRON=${AUTOSYNC_CRON}
VULNERABILITIES_CACHING_CRON=${VULNERABILITIES_CACHING_CRON}
ASPNETCORE_URLS=${ASPNETCORE_URLS}
ASPNETCORE_HTTP_PORTS=${ASPNETCORE_HTTP_PORTS}
LOG_LEVEL_DEFAULT=${LOG_LEVEL_DEFAULT}
EOF

echo "Writing ${COMPOSE_FILE}..."
{
  echo "services:"

  if [ "${INSTALL_NGINX_PROXY_MANAGER}" = "true" ]; then
    cat <<'EOF'
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:${NGINX_PROXY_MANAGER_TAG}
    hostname: nginx-proxy-manager
    restart: always
    environment:
      X_FRAME_OPTIONS: "${X_FRAME_OPTIONS}"
      DISABLE_IPV6: "${DISABLE_IPV6}"
    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt
    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_ADMIN_PORT}:81"
      - "${NPM_HTTPS_PORT}:443"

EOF
  fi

  cat <<'EOF'
  opensearch:
    image: opensearchproject/opensearch:${OPENSEARCH_TAG}
    container_name: opensearch
    environment:
      cluster.name: opensearch
      node.name: opensearch
      discovery.type: single-node
      bootstrap.memory_lock: "true"
      OPENSEARCH_JAVA_OPTS: "${OPENSEARCH_HEAP}"
      DISABLE_INSTALL_DEMO_CONFIG: "true"
      DISABLE_SECURITY_PLUGIN: "true"
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - opensearch_data:/usr/share/opensearch/data

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:${OPENSEARCH_DASHBOARDS_TAG}
    container_name: opensearch-dashboards
    ports:
      - "${OPENSEARCH_DASHBOARDS_PORT}:5601"
    expose:
      - "5601"
    depends_on:
      - opensearch
    environment:
      OPENSEARCH_HOSTS: '["${OPENSEARCH_URL}"]'
      DISABLE_SECURITY_DASHBOARDS_PLUGIN: "true"

  mongo:
    image: mongo:${MONGO_TAG}
    restart: unless-stopped
    depends_on:
      - opensearch-dashboards
    volumes:
      - db_data:/data/db
      - db_config:/data/configdb
    ports:
      - "${MONGO_PORT_HOST}:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: "${MONGO_INITDB_ROOT_USERNAME}"
      MONGO_INITDB_ROOT_PASSWORD: "${MONGO_INITDB_ROOT_PASSWORD}"
      MONGO_INITDB_DATABASE: "${MONGO_INITDB_DATABASE}"

  minio:
    image: minio/minio:${MINIO_TAG}
    volumes:
      - minio_storage:/container/vol
    ports:
      - "${MINIO_API_PORT_HOST}:9000"
      - "${MINIO_CONSOLE_PORT_HOST}:9001"
    restart: always
    environment:
      MINIO_ROOT_USER: "${MINIO_ROOT_USER}"
      MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD}"
    command: server /container/vol --console-address :9001

  rabbitmq:
    image: rabbitmq:${RABBITMQ_TAG}
    container_name: rabbitmq
    ports:
      - "${RABBITMQ_AMQP_PORT}:5672"
      - "${RABBITMQ_UI_PORT}:15672"
    healthcheck:
      test: rabbitmq-diagnostics -q ping
      interval: 30s
      timeout: 30s
      retries: 30
    restart: always
    volumes:
      - rmq_data:/var/lib/rabbitmq/
      - rmq_log:/var/log/rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: "${RABBITMQ_DEFAULT_USER}"
      RABBITMQ_DEFAULT_PASS: "${RABBITMQ_DEFAULT_PASS}"

  catalog-web:
    image: ${CATALOG_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - opensearch
      - opensearch-dashboards
    restart: always
    ports:
      - "${CATALOG_WEB_PORT}:80"
    volumes:
      - catalog_license:${CATALOG_LICENSE_PATH}
    environment:
      TZ: "${TZ}"
      BASEURL: "${BASEURL}"
      ServiceConfig__MongoConfiguration__ConnectionString: "mongodb://mongo"
      ServiceConfig__MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      ServiceConfig__MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      ServiceConfig__MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      ServiceConfig__MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      Logging__LogLevel__Default: "${LOG_LEVEL_DEFAULT}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"
      ASPNETCORE_URLS: "${ASPNETCORE_URLS}"
      ASPNETCORE_HTTP_PORTS: "${ASPNETCORE_HTTP_PORTS}"
      Synchronization__AutoSyncJobCronExpression: "${AUTOSYNC_CRON}"
      OpenSearch__Urls: '["${OPENSEARCH_URL}"]'
      Vulnerabilities__CachingJobCronExpression: "${VULNERABILITIES_CACHING_CRON}"

  worker-recognition-1:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: always
    volumes:
      - worker1_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "recognition"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      Logging__LogLevel__Default: "${LOG_LEVEL_DEFAULT}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"

  worker-recognition-2:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: always
    volumes:
      - worker2_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "recognition"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      Logging__LogLevel__Default: "${LOG_LEVEL_DEFAULT}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"

  worker-other:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: unless-stopped
    volumes:
      - worker_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "cleanup applycustomattribute suggestions"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"

  worker-search:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: unless-stopped
    volumes:
      - worker_search_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "search"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"
      OpenSearch__Urls: '["${OPENSEARCH_URL}"]'

volumes:
  db_data:
  db_config:
  worker1_token:
  worker2_token:
  worker_token:
  worker_search_token:
  rmq_data:
  rmq_log:
  minio_storage:
  catalog_license:
  opensearch_data:
  npm_data:
  npm_letsencrypt:
EOF
} > "$COMPOSE_FILE"

chmod 600 "$ENV_FILE"

echo "Created $ENV_FILE and $COMPOSE_FILE"
echo
echo "Generated credentials:"
echo "  Mongo user     : $MONGO_INITDB_ROOT_USERNAME"
echo "  Mongo password : $MONGO_INITDB_ROOT_PASSWORD"
echo "  MinIO user     : $MINIO_ROOT_USER"
echo "  MinIO password : $MINIO_ROOT_PASSWORD"
echo "  RabbitMQ user  : $RABBITMQ_DEFAULT_USER"
echo "  RabbitMQ pass  : $RABBITMQ_DEFAULT_PASS"
echo "  Nginx enabled  : $INSTALL_NGINX_PROXY_MANAGER"
echo
echo "Next steps:"
echo "  docker compose config"
echo "  docker compose up -d"
echo

if [ "${INSTALL_NGINX_PROXY_MANAGER}" = "true" ]; then
  echo "Nginx Proxy Manager is enabled."
  echo "After the stack is up, create a Proxy Host in Nginx Proxy Manager and point your domain to catalog-web on port 80."
  echo "Target in Nginx Proxy Manager:"
  echo "  Forward Hostname / IP : catalog-web"
  echo "  Forward Port          : 80"
  echo "Recommended Nginx Proxy Manager settings:"
  echo "  - Enable Block Common Exploits"
  echo "  - Enable Websockets if needed"
  echo "  - Enable SSL"
  echo "  - Request a new Let's Encrypt certificate"
  echo "  - Enable Force SSL"
  echo "  - Enable HTTP/2 Support"
  echo "If your domain already points to this server, Let's Encrypt can generate the SSL certificate automatically."
else
  echo "Nginx Proxy Manager is disabled."
  echo "Catalog Web can be reached directly over:"
  echo "  http://{server-ip}:${CATALOG_WEB_PORT}"
fi
