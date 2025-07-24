#!/bin/bash

# test-complex-images.sh - Comprehensive test suite for RFRuntime with 50+ complex applications
set -e

# Default values
NAMESPACE="${NAMESPACE:-test}"
TEST_DIR="test-apps"
MODE="interactive"  # interactive, blast, or single
PARALLEL_JOBS=50
CLEANUP=${CLEANUP:-true}
VERBOSE=${VERBOSE:-false}
TEST_PATTERN=${TEST_PATTERN:-""}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-300}  # seconds to wait for pod readiness

rm -f ${TEST_DIR}/*.yaml

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Cleanup handler
cleanup() {
    local exit_code=$?

    if [[ "$CLEANUP" == "true" ]]; then
        echo
        log_info "Running cleanup..."

        # Delete all resources with test label
        log_info "Deleting all test resources in namespace $NAMESPACE..."

        # Delete all resources that have our test label
        kubectl delete all -l "test=complex-entrypoint" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true

        # Also delete configmaps, secrets, and other resources that might not be included in "all"
        kubectl delete configmaps -l "test=complex-entrypoint" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        kubectl delete secrets -l "test=complex-entrypoint" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        kubectl delete pvc -l "test=complex-entrypoint" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true

        # Clean up test directory
        if [[ -d "$TEST_DIR" ]]; then
            log_info "Debug Removing test directory..."
            # rm -rf "$TEST_DIR"
        fi

        log_success "Cleanup completed"
    # else
    #     log_warn "Cleanup disabled - resources remain in namespace $NAMESPACE"
    fi

    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Test RFRuntime with complex container images

OPTIONS:
    -m, --mode MODE        Test mode: interactive|blast|single (default: interactive)
    -n, --namespace NS     Kubernetes namespace (default: test)
    -p, --pattern PATTERN  Test only apps matching pattern (regex)
    -j, --jobs N          Number of parallel jobs in blast mode (default: 5)
    -c, --no-cleanup      Don't cleanup pods after testing
    -v, --verbose         Show detailed output
    -l, --list            List all available test applications
    -t, --timeout SECS    Timeout for waiting pod readiness (default: 60)
    -h, --help           Show this help message

MODES:
    interactive  Test one by one with pause between each
    blast       Deploy all tests in parallel
    single      Test a single application (use with --pattern)

EXAMPLES:
    # Test all apps one by one
    $0 -m interactive

    # Blast test all databases
    $0 -m blast -p "database"

    # Test single app
    $0 -m single -p "postgres"

    # List all available tests
    $0 -l

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--pattern)
            TEST_PATTERN="$2"
            shift 2
            ;;
        -j|--jobs)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -c|--no-cleanup)
            CLEANUP=false
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        -t|--timeout)
            WAIT_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            CLEANUP=false
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Create test directory
mkdir -p "$TEST_DIR"

# Function to wait for pod to be ready
wait_for_pod_ready() {
    local pod_name=$1
    local namespace=$2
    local timeout=$3
    local start_time=$(date +%s)

    log_info "Waiting for pod $pod_name to be ready (timeout: ${timeout}s)..."

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ $elapsed -gt $timeout ]]; then
            log_error "Timeout waiting for pod $pod_name to be ready"
            return 1
        fi

        # Check if pod exists
        if ! kubectl get pod "$pod_name" -n "$namespace" &>/dev/null; then
            log_error "Pod $pod_name does not exist"
            return 1
        fi

        # Get pod status
        local pod_json=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null)
        local phase=$(echo "$pod_json" | jq -r '.status.phase // "Unknown"')

        # Check container readiness
        local ready_containers=$(echo "$pod_json" | jq -r '[.status.containerStatuses[]? | select(.ready == true)] | length // 0')
        local total_containers=$(echo "$pod_json" | jq -r '.status.containerStatuses | length // 0')

        echo -ne "\r  Status: $phase, Ready: $ready_containers/$total_containers (${elapsed}s)..."

        # Check if all containers are ready
        if [[ "$phase" == "Running" ]] && [[ $ready_containers -eq $total_containers ]] && [[ $total_containers -gt 0 ]]; then
            echo
            log_success "Pod $pod_name is ready!"
            return 0
        fi

        # Check for failed state
        if [[ "$phase" == "Failed" ]] || [[ "$phase" == "Unknown" ]]; then
            echo
            log_error "Pod $pod_name is in $phase state"

            # Show container states
            echo "$pod_json" | jq -r '.status.containerStatuses[]? | "  Container \(.name): \(.state | keys[0])"'

            return 1
        fi

        sleep 1
    done
}

# Function to check pod wrapping status
check_pod_wrapped() {
    local pod_name=$1
    local namespace=$2

    local pod_json=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null)
    local wrapped=$(echo "$pod_json" | jq -r '.metadata.annotations."rapidfort.io/wrapped" // "false"')
    local container_count=$(echo "$pod_json" | jq -r '.metadata.annotations."rapidfort.io/container-count" // "0"')
    local rf_version=$(echo "$pod_json" | jq -r '.metadata.annotations."rapidfort.io/version" // "none"')

    if [[ "$wrapped" == "true" ]]; then
        log_success "✓ Pod $pod_name is wrapped by RFRuntime"
        echo "    - RFRuntime version: $rf_version"
        echo "    - Wrapped containers: $container_count"
    else
        log_warn "✗ Pod $pod_name is NOT wrapped by RFRuntime"
    fi
    return 0
}

# Function to create all test YAMLs (50 complex applications)
create_test_yamls() {
    local category=$1

    # Databases (10)
    if [[ -z "$category" || "$category" == "database" ]]; then

        cat > "$TEST_DIR/postgres-16.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-postgres-16
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: postgres
    image: postgres:16-alpine
    env:
    - name: POSTGRES_PASSWORD
      value: testpass123
    - name: POSTGRES_DB
      value: testdb
    - name: POSTGRES_INITDB_ARGS
      value: "--encoding=UTF8 --locale=en_US.UTF-8"
    args: ["-c", "shared_buffers=256MB", "-c", "max_connections=200"]
EOF

        cat > "$TEST_DIR/mysql-8.yaml" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  labels:
    test: complex-entrypoint
type: Opaque
data:
  # echo -n 'rootpass123' | base64
  mysql-root-password: cm9vdHBhc3MxMjM=
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-config
  labels:
    test: complex-entrypoint
data:
  my.cnf: |
    [mysqld]
    max_connections = 500
    innodb_buffer_pool_size = 256M
    default_authentication_plugin = mysql_native_password
---
apiVersion: v1
kind: Pod
metadata:
  name: test-mysql-8
  labels:
    test: complex-entrypoint
    category: database
spec:
  initContainers:
  - name: mysql-init
    image: busybox:1.36
    command: ['sh', '-c', 'echo "Initializing MySQL data directory..."']
  containers:
  - name: mysql
    image: mysql:8.0
    env:
    - name: MYSQL_ROOT_PASSWORD
      valueFrom:
        secretKeyRef:
          name: mysql-secret
          key: mysql-root-password
    - name: MYSQL_DATABASE
      value: testdb
    args: ["--defaults-extra-file=/etc/mysql/conf.d/my.cnf"]
    volumeMounts:
    - name: config
      mountPath: /etc/mysql/conf.d
  volumes:
  - name: config
    configMap:
      name: mysql-config
EOF

        cat > "$TEST_DIR/mariadb-11.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-mariadb-11
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: mariadb
    image: mariadb:11
    env:
    - name: MARIADB_ROOT_PASSWORD
      value: rootpass123
    - name: MARIADB_DATABASE
      value: testdb
    command: ["docker-entrypoint.sh"]
    args: ["mariadbd", "--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci"]
EOF

        cat > "$TEST_DIR/mongodb-7.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-mongodb-7
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: mongodb
    image: mongo:7
    env:
    - name: MONGO_INITDB_ROOT_USERNAME
      value: admin
    - name: MONGO_INITDB_ROOT_PASSWORD
      value: adminpass123
    command: ["mongod"]
    args: ["--bind_ip_all", "--wiredTigerCacheSizeGB", "0.25"]
EOF

        cat > "$TEST_DIR/redis-7.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  labels:
    test: complex-entrypoint
data:
  redis.conf: |
    maxmemory 128mb
    maxmemory-policy allkeys-lru
    save ""
    appendonly yes
    protected-mode no
    bind 0.0.0.0
---
apiVersion: v1
kind: Pod
metadata:
  name: test-redis-7
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: redis
    image: redis:7-alpine
    command: ["redis-server"]
    args: ["/usr/local/etc/redis/redis.conf"]
    volumeMounts:
    - name: config
      mountPath: /usr/local/etc/redis
  volumes:
  - name: config
    configMap:
      name: redis-config
EOF

        cat > "$TEST_DIR/cassandra-4.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-cassandra-4
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: cassandra
    image: cassandra:4.1
    env:
    - name: CASSANDRA_CLUSTER_NAME
      value: "TestCluster"
    - name: CASSANDRA_DC
      value: "DC1"
    - name: CASSANDRA_ENDPOINT_SNITCH
      value: "SimpleSnitch"
    - name: MAX_HEAP_SIZE
      value: "512M"
    - name: HEAP_NEWSIZE
      value: "128M"
EOF

        cat > "$TEST_DIR/elasticsearch-8.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-elasticsearch-8
  labels:
    test: complex-entrypoint
    category: database
spec:
  initContainers:
  - name: sysctl
    image: busybox:1.36
    command: ['sh', '-c', 'sysctl -w vm.max_map_count=262144 || true']
    securityContext:
      privileged: true
  containers:
  - name: elasticsearch
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.0
    env:
    - name: discovery.type
      value: single-node
    - name: xpack.security.enabled
      value: "false"
    - name: ES_JAVA_OPTS
      value: "-Xms512m -Xmx512m"
    - name: cluster.name
      value: "test-cluster"
EOF

        cat > "$TEST_DIR/influxdb-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-influxdb-2
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: influxdb
    image: influxdb:2.7-alpine
    env:
    - name: DOCKER_INFLUXDB_INIT_MODE
      value: setup
    - name: DOCKER_INFLUXDB_INIT_USERNAME
      value: admin
    - name: DOCKER_INFLUXDB_INIT_PASSWORD
      value: adminpass123
    - name: DOCKER_INFLUXDB_INIT_ORG
      value: testorg
    - name: DOCKER_INFLUXDB_INIT_BUCKET
      value: testbucket
    command: ["influxd"]
    args: ["--reporting-disabled"]
EOF

        cat > "$TEST_DIR/neo4j-5.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-neo4j-5
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: neo4j
    image: neo4j:5-community
    env:
    - name: NEO4J_AUTH
      value: "neo4j/testpass123"
    - name: NEO4J_PLUGINS
      value: '["apoc"]'
    - name: NEO4J_dbms_memory_heap_initial__size
      value: "512M"
    - name: NEO4J_dbms_memory_heap_max__size
      value: "512M"
EOF

        cat > "$TEST_DIR/couchdb-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-couchdb-3
  labels:
    test: complex-entrypoint
    category: database
spec:
  containers:
  - name: couchdb
    image: couchdb:3
    env:
    - name: COUCHDB_USER
      value: admin
    - name: COUCHDB_PASSWORD
      value: adminpass123
    - name: COUCHDB_SECRET
      value: supersecret
    - name: NODENAME
      value: 127.0.0.1
    command: ["docker-entrypoint.sh"]
    args: ["couchdb"]
EOF
    fi

    # Message Queues (8)
    if [[ -z "$category" || "$category" == "messaging" ]]; then

        cat > "$TEST_DIR/rabbitmq-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-rabbitmq-3
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: rabbitmq
    image: rabbitmq:3-management-alpine
    env:
    - name: RABBITMQ_DEFAULT_USER
      value: admin
    - name: RABBITMQ_DEFAULT_PASS
      value: adminpass123
    - name: RABBITMQ_VM_MEMORY_HIGH_WATERMARK
      value: "0.4"
    command: ["rabbitmq-server"]
EOF

        cat > "$TEST_DIR/kafka-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-kafka-3
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: zookeeper
    image: confluentinc/cp-zookeeper:7.5.0
    env:
    - name: ZOOKEEPER_CLIENT_PORT
      value: "2181"
    - name: ZOOKEEPER_TICK_TIME
      value: "2000"
    - name: ZOOKEEPER_LOG4J_ROOT_LOGLEVEL
      value: "ERROR"
    ports:
    - containerPort: 2181
      name: zookeeper
  - name: kafka
    image: confluentinc/cp-kafka:7.5.0
    env:
    - name: KAFKA_BROKER_ID
      value: "1"
    - name: KAFKA_ZOOKEEPER_CONNECT
      value: "localhost:2181"
    - name: KAFKA_ADVERTISED_LISTENERS
      value: "PLAINTEXT://localhost:9092"
    - name: KAFKA_LISTENERS
      value: "PLAINTEXT://0.0.0.0:9092"
    - name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR
      value: "1"
    - name: KAFKA_HEAP_OPTS
      value: "-Xmx512M -Xms512M"
    command: ["/bin/bash", "-c"]
    args: ["sleep 30 && exec /etc/confluent/docker/run"]  # Wait for Zookeeper to start
    ports:
    - containerPort: 9092
      name: kafka
EOF

        cat > "$TEST_DIR/nats-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nats-2
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: nats
    image: nats:2-alpine
    command: ["nats-server"]
    args:
    - "--port"
    - "4222"
    - "--http_port"
    - "8222"
    ports:
    - containerPort: 4222
      name: client
    - containerPort: 8222
      name: http
EOF

        cat > "$TEST_DIR/pulsar-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-pulsar-3
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: pulsar
    image: apachepulsar/pulsar:3.1.0
    command: ["bin/pulsar"]
    args: ["standalone", "--advertised-address", "localhost"]
    env:
    - name: PULSAR_MEM
      value: "-Xms512m -Xmx512m"
EOF

        cat > "$TEST_DIR/activemq-6.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-activemq-6
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: activemq
    image: apache/activemq-artemis:latest
    env:
    - name: ARTEMIS_USER
      value: admin
    - name: ARTEMIS_PASSWORD
      value: adminpass123
    - name: JAVA_ARGS
      value: "-Xms512M -Xmx512M"
EOF

        cat > "$TEST_DIR/mosquitto-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-mosquitto-2
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: mosquitto
    image: eclipse-mosquitto:2
    command: ["mosquitto"]
    args: ["-c", "/mosquitto-no-auth.conf"]
EOF

        cat > "$TEST_DIR/emqx-5.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-emqx-5
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: emqx
    image: emqx:5
    env:
    - name: EMQX_NAME
      value: emqx
    - name: EMQX_HOST
      value: "127.0.0.1"
    command: ["/usr/bin/docker-entrypoint.sh"]
    args: ["emqx", "foreground"]
EOF

        cat > "$TEST_DIR/nsq-1.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nsq-1
  labels:
    test: complex-entrypoint
    category: messaging
spec:
  containers:
  - name: nsqd
    image: nsqio/nsq:v1.2.1
    command: ["/nsqd"]
    args: ["--lookupd-tcp-address=nsqlookupd:4160", "--broadcast-address=nsqd"]
  - name: nsqlookupd
    image: nsqio/nsq:v1.2.1
    command: ["/nsqlookupd"]
EOF
    fi

    # Web Servers & Proxies (7)
    if [[ -z "$category" || "$category" == "web" ]]; then

        cat > "$TEST_DIR/nginx-custom.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  labels:
    test: complex-entrypoint
data:
  nginx.conf: |
    events {
        worker_connections 1024;
    }
    http {
        server {
            listen 80;
            location / {
                return 200 "Hello from custom nginx\n";
                add_header Content-Type text/plain;
            }
        }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: test-nginx-custom
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["nginx"]
    args: ["-g", "daemon off;", "-c", "/etc/nginx/nginx.conf"]
    volumeMounts:
    - name: config
      mountPath: /etc/nginx
  volumes:
  - name: config
    configMap:
      name: nginx-config
EOF

        cat > "$TEST_DIR/apache-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-apache-2
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  - name: apache
    image: httpd:2.4-alpine
    command: ["httpd-foreground"]
    env:
    - name: HTTPD_PREFIX
      value: "/usr/local/apache2"
EOF

        cat > "$TEST_DIR/caddy-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-caddy-2
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  - name: caddy
    image: caddy:2-alpine
    command: ["caddy"]
    args: ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
EOF

        cat > "$TEST_DIR/traefik-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-traefik-3
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  - name: traefik
    image: traefik:v3.0
    command: ["traefik"]
    args: ["--api.insecure=true", "--providers.docker=false", "--entrypoints.web.address=:80"]
EOF

        cat > "$TEST_DIR/haproxy-2.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: haproxy-config
  labels:
    test: complex-entrypoint
data:
  haproxy.cfg: |
    global
        daemon
    defaults
        mode    http
        timeout connect 5000ms
        timeout client  50000ms
        timeout server  50000ms
    frontend web
        bind *:80
        default_backend servers
    backend servers
        server local 127.0.0.1:8080 maxconn 32
---
apiVersion: v1
kind: Pod
metadata:
  name: test-haproxy-2
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  securityContext:
      runAsUser: 0
  - name: haproxy
    image: haproxy:2.8-alpine
    command: ["haproxy"]
    args: ["-f", "/usr/local/etc/haproxy/haproxy.cfg"]
    volumeMounts:
    - name: config
      mountPath: /usr/local/etc/haproxy
  volumes:
  - name: config
    configMap:
      name: haproxy-config
EOF

        cat > "$TEST_DIR/envoy-1.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-envoy-1
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  - name: envoy
    image: envoyproxy/envoy:v1.28-latest
    command: ["envoy"]
    args: ["-c", "/etc/envoy/envoy.yaml", "-l", "info"]
EOF

        cat > "$TEST_DIR/kong-3.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-config
  labels:
    test: complex-entrypoint
data:
  kong.yml: |
    _format_version: "3.0"
    _transform: true

    services:
    - name: test-service
      url: http://httpbin.org
      routes:
      - name: test-route
        paths:
        - /test
---
apiVersion: v1
kind: Pod
metadata:
  name: test-kong-3
  labels:
    test: complex-entrypoint
    category: web
spec:
  containers:
  - name: kong
    image: kong/kong
    env:
    - name: KONG_DATABASE
      value: "off"
    - name: KONG_DECLARATIVE_CONFIG
      value: "/kong/declarative/kong.yml"
    - name: KONG_PROXY_ACCESS_LOG
      value: "/dev/stdout"
    - name: KONG_ADMIN_ACCESS_LOG
      value: "/dev/stdout"
    - name: KONG_PROXY_ERROR_LOG
      value: "/dev/stderr"
    - name: KONG_ADMIN_ERROR_LOG
      value: "/dev/stderr"
    volumeMounts:
    - name: config
      mountPath: /kong/declarative
    ports:
    - containerPort: 8000
      name: proxy
    - containerPort: 8001
      name: admin
  volumes:
  - name: config
    configMap:
      name: kong-config
EOF
    fi

    # Monitoring & Observability (8)
    if [[ -z "$category" || "$category" == "monitoring" ]]; then

        cat > "$TEST_DIR/prometheus-2.yaml" << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-sa
  labels:
    test: complex-entrypoint
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-role
  labels:
    test: complex-entrypoint
rules:
- apiGroups: [""]
  resources: ["services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-binding
  labels:
    test: complex-entrypoint
subjects:
- kind: ServiceAccount
  name: prometheus-sa
roleRef:
  kind: Role
  name: prometheus-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  labels:
    test: complex-entrypoint
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - test
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
---
apiVersion: v1
kind: Pod
metadata:
  name: test-prometheus-2
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  serviceAccountName: prometheus-sa
  containers:
  - name: prometheus
    image: prom/prometheus:v2.47.0
    command: ["/bin/prometheus"]
    args:
    - "--config.file=/etc/prometheus/prometheus.yml"
    - "--storage.tsdb.path=/prometheus"
    - "--web.console.libraries=/usr/share/prometheus/console_libraries"
    - "--web.console.templates=/usr/share/prometheus/consoles"
    - "--web.enable-lifecycle"
    - "--web.enable-admin-api"
    volumeMounts:
    - name: config
      mountPath: /etc/prometheus
  volumes:
  - name: config
    configMap:
      name: prometheus-config
EOF

        cat > "$TEST_DIR/grafana-10.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-grafana-10
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  containers:
  - name: grafana
    image: grafana/grafana:10.2.0
    env:
    - name: GF_SECURITY_ADMIN_PASSWORD
      value: admin123
    - name: GF_INSTALL_PLUGINS
      value: "grafana-clock-panel,grafana-simple-json-datasource"
    command: ["grafana-server"]
    args: ["--homepath=/usr/share/grafana", "--config=/etc/grafana/grafana.ini"]
EOF

        cat > "$TEST_DIR/alertmanager-0.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-alertmanager-0
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  containers:
  - name: alertmanager
    image: prom/alertmanager:v0.26.0
    command: ["/bin/alertmanager"]
    args:
    - "--config.file=/etc/alertmanager/alertmanager.yml"
    - "--storage.path=/alertmanager"
    - "--cluster.listen-address="
EOF

        cat > "$TEST_DIR/loki-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-loki-2
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  containers:
  - name: loki
    image: grafana/loki:2.9.0
    command: ["/usr/bin/loki"]
    args: ["-config.file=/etc/loki/local-config.yaml"]
EOF

        cat > "$TEST_DIR/jaeger-1.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-jaeger-1
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  containers:
  - name: jaeger
    image: jaegertracing/all-in-one:1.50
    env:
    - name: COLLECTOR_ZIPKIN_HOST_PORT
      value: ":9411"
    - name: SPAN_STORAGE_TYPE
      value: "memory"
    command: ["/go/bin/all-in-one-linux"]
EOF

        cat > "$TEST_DIR/victoria-metrics.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-victoria-metrics
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  containers:
  - name: victoria-metrics
    image: victoriametrics/victoria-metrics:v1.93.0
    command: ["/victoria-metrics-prod"]
    args: ["-storageDataPath=/storage", "-httpListenAddr=:8428"]
EOF

        cat > "$TEST_DIR/thanos-0.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-thanos-0
  labels:
    test: complex-entrypoint
    category: monitoring
spec:
  containers:
  - name: thanos
    image: quay.io/thanos/thanos:v0.32.0
    command: ["thanos"]
    args: ["sidecar", "--tsdb.path=/var/prometheus", "--prometheus.url=http://localhost:9090"]
EOF
    fi

    # CI/CD Tools (5)
    if [[ -z "$category" || "$category" == "cicd" ]]; then

        cat > "$TEST_DIR/jenkins-2.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-jenkins-2
  labels:
    test: complex-entrypoint
    category: cicd
spec:
  containers:
  - name: jenkins
    image: jenkins/jenkins:lts-alpine
    env:
    - name: JAVA_OPTS
      value: "-Xmx512m -Xms256m"
    - name: JENKINS_OPTS
      value: "--httpPort=8080"
    ports:
    - containerPort: 8080
EOF

        cat > "$TEST_DIR/gitlab-runner.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-gitlab-runner
  labels:
    test: complex-entrypoint
    category: cicd
spec:
  containers:
  - name: gitlab-runner
    image: gitlab/gitlab-runner:alpine
    command: ["gitlab-runner"]
    args: ["run", "--user=gitlab-runner", "--working-directory=/home/gitlab-runner"]
EOF

        fi

     # Container Registries (3)
     if [[ -z "$category" || "$category" == "registry" ]]; then

        cat > "$TEST_DIR/nexus-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nexus-3
  labels:
    test: complex-entrypoint
    category: registry
spec:
  containers:
  - name: nexus
    image: sonatype/nexus3:3.61.0
    env:
    - name: INSTALL4J_ADD_VM_PARAMS
      value: "-Xms512m -Xmx512m -XX:MaxDirectMemorySize=1g"
    command: ["sh", "-c"]
    args: ["${SONATYPE_DIR}/start-nexus-repository-manager.sh"]
EOF
    fi

    # Security Tools (3)
    if [[ -z "$category" || "$category" == "security" ]]; then

        cat > "$TEST_DIR/vault-1.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-vault-1
  labels:
    test: complex-entrypoint
    category: security
spec:
  containers:
  - name: vault
    image: hashicorp/vault:1.15
    env:
    - name: VAULT_DEV_ROOT_TOKEN_ID
      value: "root"
    - name: VAULT_DEV_LISTEN_ADDRESS
      value: "0.0.0.0:8200"
    command: ["vault"]
    args: ["server", "-dev"]
EOF

        cat > "$TEST_DIR/keycloak-23.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-keycloak-23
  labels:
    test: complex-entrypoint
    category: security
spec:
  containers:
  - name: keycloak
    image: quay.io/keycloak/keycloak:23.0
    env:
    - name: KEYCLOAK_ADMIN
      value: admin
    - name: KEYCLOAK_ADMIN_PASSWORD
      value: admin123
    command: ["/opt/keycloak/bin/kc.sh"]
    args: ["start-dev"]
EOF

    fi

    # Application Runtimes (6)
    if [[ -z "$category" || "$category" == "runtime" ]]; then

        cat > "$TEST_DIR/nodejs-20.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nodejs-20
  labels:
    test: complex-entrypoint
    category: runtime
spec:
  containers:
  - name: nodejs
    image: node:20-alpine
    command: ["node"]
    args: ["--max-old-space-size=512", "-e", "console.log('Node.js test'); setInterval(() => console.log('Running...'), 5000)"]
EOF

        cat > "$TEST_DIR/python-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-python-3
  labels:
    test: complex-entrypoint
    category: runtime
spec:
  containers:
  - name: python
    image: python:3.12-alpine
    command: ["python3"]
    args: ["-u", "-c", "import time; print('Python test'); [print(f'Running... {i}') or time.sleep(5) for i in range(10)]"]
EOF

        cat > "$TEST_DIR/golang-1.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-golang-1
  labels:
    test: complex-entrypoint
    category: runtime
spec:
  containers:
  - name: golang
    image: golang:1.21-alpine
    command: ["/bin/sh"]
    args:
    - "-c"
    - |
      cat > /tmp/main.go << 'TESTEOF'
      package main

      import (
          "fmt"
          "time"
      )

      func main() {
          fmt.Println("Go test")
          for {
              fmt.Println("Running...")
              time.Sleep(5 * time.Second)
          }
      }
      TESTEOF
      go run /tmp/main.go
EOF

        cat > "$TEST_DIR/ruby-3.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-ruby-3
  labels:
    test: complex-entrypoint
    category: runtime
spec:
  containers:
  - name: ruby
    image: ruby:3.2-alpine
    command: ["ruby"]
    args: ["-e", "puts 'Ruby test'; loop { puts 'Running...'; sleep 5 }"]
EOF

        cat > "$TEST_DIR/php-8-fpm.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-php-8-fpm
  labels:
    test: complex-entrypoint
    category: runtime
spec:
  containers:
  - name: php
    image: php:8.3-fpm-alpine
    command: ["php-fpm"]
    args: ["-F", "-R"]
EOF

        cat > "$TEST_DIR/tomcat-10.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-tomcat-10
  labels:
    test: complex-entrypoint
    category: runtime
spec:
  containers:
  - name: tomcat
    image: tomcat:10-jdk17
    env:
    - name: JAVA_OPTS
      value: "-Xms512m -Xmx512m"
    command: ["catalina.sh"]
    args: ["run"]
EOF
    fi

# Complex Command & Args Examples
    if [[ -z "$category" || "$category" == "complex" ]]; then

        cat > "$TEST_DIR/complex-heredoc.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-complex-heredoc
  labels:
    test: complex-entrypoint
    category: complex
spec:
  containers:
  - name: complex-heredoc
    image: python:3.11-slim
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -euxo pipefail

      # Create Python application with heredoc
      cat > /tmp/app.py << 'PYTHON_APP'
      import os
      import sys
      import json
      import time
      import signal
      import threading
      import http.server
      import socketserver
      from datetime import datetime

      def signal_handler(signum, frame):
          print(f"Received signal {signum}, shutting down...")
          sys.exit(0)

      # Register signal handlers
      signal.signal(signal.SIGTERM, signal_handler)
      signal.signal(signal.SIGINT, signal_handler)

      # Configuration from environment
      config = {
          'app_name': os.environ.get('APP_NAME', 'ComplexApp'),
          'version': os.environ.get('APP_VERSION', '1.0.0'),
          'port': int(os.environ.get('HEALTH_PORT', '8080')),
          'workers': int(os.environ.get('WORKER_COUNT', '5'))
      }

      print(f"Starting {config['app_name']} v{config['version']}")

      # Do some complex operations
      for i in range(5):
          result = sum(j**2 for j in range(1000))
          print(f"Complex calculation {i+1}/5: {result}")
          time.sleep(2)

      print("Complex operations completed. Keeping container alive...")
      while True:
          time.sleep(3600)
      PYTHON_APP

      # Create configuration with another heredoc
      cat > /tmp/config.json << 'CONFIG'
      {
        "database": {
          "host": "${DB_HOST:-localhost}",
          "port": ${DB_PORT:-5432},
          "name": "${DB_NAME:-myapp}",
          "pool_size": ${DB_POOL_SIZE:-10}
        },
        "cache": {
          "type": "${CACHE_TYPE:-redis}",
          "ttl": ${CACHE_TTL:-3600},
          "max_entries": ${CACHE_MAX_ENTRIES:-1000}
        },
        "features": {
          "async_processing": ${ENABLE_ASYNC:-true},
          "rate_limiting": ${ENABLE_RATE_LIMIT:-false},
          "metrics": ${ENABLE_METRICS:-true}
        }
      }
      CONFIG

      # Process configuration with complex bash substitution
      export DB_HOST="${DB_HOST:-postgres.default.svc.cluster.local}"
      export DB_PORT="${DB_PORT:-5432}"
      export DB_NAME="${DB_NAME:-production}"
      export DB_POOL_SIZE="${DB_POOL_SIZE:-20}"
      export CACHE_TYPE="${CACHE_TYPE:-memcached}"
      export CACHE_TTL="${CACHE_TTL:-7200}"
      export CACHE_MAX_ENTRIES="${CACHE_MAX_ENTRIES:-5000}"
      export ENABLE_ASYNC="${ENABLE_ASYNC:-true}"
      export ENABLE_RATE_LIMIT="${ENABLE_RATE_LIMIT:-true}"
      export ENABLE_METRICS="${ENABLE_METRICS:-true}"

      # Perform variable substitution using complex sed/awk pipeline
      cat /tmp/config.json | \
        sed 's/\${DB_HOST:-[^}]*}/'$DB_HOST'/g' | \
        sed 's/\${DB_PORT:-[^}]*}/'$DB_PORT'/g' | \
        sed 's/\${DB_NAME:-[^}]*}/'$DB_NAME'/g' | \
        sed 's/\${DB_POOL_SIZE:-[^}]*}/'$DB_POOL_SIZE'/g' | \
        sed 's/\${CACHE_TYPE:-[^}]*}/'$CACHE_TYPE'/g' | \
        sed 's/\${CACHE_TTL:-[^}]*}/'$CACHE_TTL'/g' | \
        sed 's/\${CACHE_MAX_ENTRIES:-[^}]*}/'$CACHE_MAX_ENTRIES'/g' | \
        sed 's/\${ENABLE_ASYNC:-[^}]*}/'$ENABLE_ASYNC'/g' | \
        sed 's/\${ENABLE_RATE_LIMIT:-[^}]*}/'$ENABLE_RATE_LIMIT'/g' | \
        sed 's/\${ENABLE_METRICS:-[^}]*}/'$ENABLE_METRICS'/g' > /tmp/config_processed.json

      echo "Configuration processed:"
      cat /tmp/config_processed.json | python3 -m json.tool

      # Run pre-flight checks with subshells and complex conditions
      echo "Running pre-flight checks..."

      # Check 1: Python dependencies
      (
        python3 -c "import sys; print(f'Python {sys.version}')" && \
        echo "✓ Python runtime check passed"
      ) || (
        echo "✗ Python runtime check failed" && exit 1
      )

      # Check 2: File system
      (
        for dir in /tmp /var/log /data; do
          if [[ -w "$dir" ]] || mkdir -p "$dir" 2>/dev/null; then
            echo "✓ Directory $dir is writable"
          else
            echo "✗ Directory $dir is not writable" && exit 1
          fi
        done
      )

      # Check 3: Network connectivity simulation
      (
        python3 -c "
      import socket
      import sys
      try:
          socket.create_connection(('8.8.8.8', 53), timeout=5)
          print('✓ Network connectivity check passed')
      except:
          print('✗ Network connectivity check failed')
          sys.exit(1)
      "
      )

      echo "All pre-flight checks passed!"

      # Finally run the application with complex environment
      exec python3 -u /tmp/app.py 2>&1 | \
        while IFS= read -r line; do
          echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $line"
        done | \
        tee -a /var/log/app.log
    env:
    - name: APP_NAME
      value: "SuperComplexApp"
    - name: APP_VERSION
      value: "2.0.0"
    - name: HEALTH_PORT
      value: "8080"
    - name: WORKER_COUNT
      value: "10"
    - name: PYTHONUNBUFFERED
      value: "1"
EOF

        cat > "$TEST_DIR/ultra-complex.yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-ultra-complex
  labels:
    test: complex-entrypoint
    category: complex
spec:
  containers:
  - name: ultra-complex
    image: node:18-slim
    command: ["/bin/bash", "-c"]
    args:
    - |
      # Install additional tools
      apt-get update && apt-get install -y python3 curl jq procps net-tools > /dev/null 2>&1

      # Create a complex Node.js application inline
      cat > /tmp/server.js << 'NODE_APP'
      const http = require('http');
      const cluster = require('cluster');
      const os = require('os');

      if (cluster.isMaster) {
        console.log(`Master ${process.pid} is running`);

        // Fork workers
        const numWorkers = parseInt(process.env.WORKER_COUNT || os.cpus().length);
        for (let i = 0; i < numWorkers; i++) {
          cluster.fork();
        }

        cluster.on('exit', (worker, code, signal) => {
          console.log(`Worker ${worker.process.pid} died`);
          cluster.fork();
        });
      } else {
        // Worker process
        const server = http.createServer((req, res) => {
          if (req.url === '/health') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
              worker: process.pid,
              uptime: process.uptime(),
              memory: process.memoryUsage()
            }));
          } else {
            res.writeHead(404);
            res.end();
          }
        });

        server.listen(8000, () => {
          console.log(`Worker ${process.pid} started`);
        });
      }
      NODE_APP

      # Pre-start validation with complex logic
      echo "Running pre-start validation..."

      # Validation 1: Check available memory
      AVAILABLE_MEM=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
      REQUIRED_MEM=512

      if [[ $AVAILABLE_MEM -lt $REQUIRED_MEM ]]; then
        echo "ERROR: Insufficient memory. Available: ${AVAILABLE_MEM}MB, Required: ${REQUIRED_MEM}MB"
        exit 1
      else
        echo "✓ Memory check passed: ${AVAILABLE_MEM}MB available"
      fi

      # Validation 2: Port availability check
      for port in 8000 8080 9090; do
        if netstat -tuln | grep -q ":$port "; then
          echo "ERROR: Port $port is already in use"
          exit 1
        else
          echo "✓ Port $port is available"
        fi
      done

      # Start main application
      echo "Starting Node.js cluster application..."

      # Run in background
      NODE_ENV=production \
      WORKER_COUNT=${WORKER_COUNT:-4} \
      LOG_LEVEL=${LOG_LEVEL:-info} \
      node /tmp/server.js &

      NODE_PID=$!
      echo "Node.js app started with PID $NODE_PID"

      # Wait a bit to ensure it's running
      sleep 5

      # Check if it's still running
      if kill -0 $NODE_PID 2>/dev/null; then
        echo "✓ Node.js cluster is running successfully"
      else
        echo "✗ Node.js cluster failed to start"
        exit 1
      fi

      # KEEP CONTAINER ALIVE
      echo "Complex operations completed. Keeping container alive for verification..."
      while true; do
        if ! kill -0 $NODE_PID 2>/dev/null; then
          echo "Node.js app died, restarting..."
          node /tmp/server.js &
          NODE_PID=$!
        fi
        sleep 60
      done
    env:
    - name: WORKER_COUNT
      value: "4"
    - name: LOG_LEVEL
      value: "debug"
    - name: NODE_OPTIONS
      value: "--max-old-space-size=512"
EOF
    fi

    log_success "Created all test YAML files in $TEST_DIR"
}

# Function to get test apps based on pattern
get_test_apps() {
    local pattern=$1
    local apps=()

    for yaml in "$TEST_DIR"/*.yaml; do
        if [[ -f "$yaml" ]]; then
            # Check if file matches pattern (check both filename and content)
            if [[ -z "$pattern" ]]; then
                apps+=("$yaml")
            elif echo "$(basename "$yaml")" | grep -qE "$pattern"; then
                apps+=("$yaml")
            elif grep -qE "$pattern" "$yaml"; then
                apps+=("$yaml")
            fi
        fi
    done

    printf '%s\n' "${apps[@]}"
}

# Function to test a single pod
test_pod() {
    local yaml_file=$1

    # Extract pod name more reliably by finding the Pod resource specifically
    local pod_name=""
    local in_pod_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^kind:[[:space:]]*Pod ]]; then
            in_pod_section=true
        elif [[ "$in_pod_section" == true ]] && [[ "$line" =~ ^[[:space:]]*name:[[:space:]]*(test-[^ ]+) ]]; then
            pod_name="${BASH_REMATCH[1]}"
            break
        elif [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^kind: ]]; then
            in_pod_section=false
        fi
    done < "$yaml_file"

    # Fallback if still not found
    if [[ -z "$pod_name" ]]; then
        pod_name=$(grep "name: test-" "$yaml_file" | head -1 | awk '{print $3}')
    fi

    echo "================================================="
    echo "Testing: $pod_name"
    echo "================================================="
    # Delete existing resources if they exist
    log_info "Cleaning up any existing resources for $pod_name..."
    kubectl delete -f "$yaml_file" -n "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
    sleep 2

    # Apply the pod (handles multi-document YAML)
    log_info "Creating resources from $yaml_file..."

    # Check what resources will be created
    local resource_types=$(grep "^kind:" "$yaml_file" | awk '{print $2}' | sort | uniq | tr '\n' ', ' | sed 's/,$//')
    if [[ -n "$resource_types" ]]; then
        log_info "Resource types: $resource_types"
    fi

    if ! kubectl apply -f "$yaml_file" -n "$NAMESPACE"; then
        log_error "Failed to create resources"
        return 1
    fi

    # Wait for pod to be ready
    if wait_for_pod_ready "$pod_name" "$NAMESPACE" "$WAIT_TIMEOUT"; then
        # Check if pod is wrapped
        check_pod_wrapped "$pod_name" "$NAMESPACE"
        local wrapped=$?

        # Show logs if verbose
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "\nContainer Logs (last 10 lines):"
            kubectl logs "$pod_name" -n "$NAMESPACE" --tail=10 2>&1 || echo "No logs available"
        fi

        echo -e "\n--- Summary for $pod_name ---"
        echo "Status: Running and Ready"
        if [[ $wrapped -eq 0 ]]; then
            echo "Result: ✓ SUCCESS - Pod is wrapped and ready"
        else
            echo "Result: ✗ FAILED - Pod is ready but NOT wrapped"
        fi
    else
        echo -e "\n--- Summary for $pod_name ---"
        echo "Result: ✗ FAILED - Pod did not become ready"
    fi

    echo
}

# Function for blast testing
blast_test() {
    local apps=("$@")
    local total=${#apps[@]}
    local results=()

    log_info "Starting blast test with $total applications"
    log_info "Deploying all resources..."

    # Deploy all resources (kubectl apply handles multi-document YAML files correctly)
    local deploy_count=0
    for yaml in "${apps[@]}"; do
        kubectl apply -f "$yaml" -n "$NAMESPACE" &>/dev/null &
        deploy_count=$((deploy_count + 1))
        echo -ne "\rDeployed: $deploy_count/$total"
    done
    echo

    # Wait for all background deployments to complete
    wait

    log_success "All resources deployed, waiting for pod readiness..."

    # Track pod readiness
    local ready_pods=()
    local failed_pods=()
    local start_time=$(date +%s)

    # Get all pod names from YAML files
    local all_pod_names=()
    for yaml in "${apps[@]}"; do
        # Extract pod name more reliably
        local pod_name=""
        local in_pod_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^kind:[[:space:]]*Pod ]]; then
                in_pod_section=true
            elif [[ "$in_pod_section" == true ]] && [[ "$line" =~ ^[[:space:]]*name:[[:space:]]*(test-[^ ]+) ]]; then
                pod_name="${BASH_REMATCH[1]}"
                break
            elif [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^kind: ]]; then
                in_pod_section=false
            fi
        done < "$yaml"

        # Fallback if still not found
        if [[ -z "$pod_name" ]]; then
            pod_name=$(grep "name: test-" "$yaml" | head -1 | awk '{print $3}')
        fi

        if [[ -n "$pod_name" ]]; then
            all_pod_names+=("$pod_name:$yaml")
        fi
    done

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ $elapsed -gt $WAIT_TIMEOUT ]]; then
            log_warn "Timeout reached after ${WAIT_TIMEOUT}s"
            break
        fi

        # Check each pod
        local pending_count=0
        for pod_info in "${all_pod_names[@]}"; do
            local pod_name="${pod_info%%:*}"
            local yaml_file="${pod_info#*:}"

            # Skip if already processed
            if [[ " ${ready_pods[@]} " =~ " ${pod_name} " ]] || [[ " ${failed_pods[@]} " =~ " ${pod_name} " ]]; then
                continue
            fi

            # Check pod status
            local pod_json=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o json 2>/dev/null)
            if [[ -z "$pod_json" ]]; then
                failed_pods+=("$pod_name")
                continue
            fi

            local phase=$(echo "$pod_json" | jq -r '.status.phase // "Unknown"')
            local ready_containers=$(echo "$pod_json" | jq -r '[.status.containerStatuses[]? | select(.ready == true)] | length // 0')
            local total_containers=$(echo "$pod_json" | jq -r '.status.containerStatuses | length // 0')

            if [[ "$phase" == "Running" ]] && [[ $ready_containers -eq $total_containers ]] && [[ $total_containers -gt 0 ]]; then
                ready_pods+=("$pod_name")
            elif [[ "$phase" == "Failed" ]] || [[ "$phase" == "Unknown" ]]; then
                failed_pods+=("$pod_name")
            else
                pending_count=$((pending_count + 1))
            fi
        done

        echo -ne "\rReady: ${#ready_pods[@]}/${#all_pod_names[@]}, Failed: ${#failed_pods[@]}, Pending: $pending_count (${elapsed}s)..."

        if [[ $pending_count -eq 0 ]]; then
            echo
            break
        fi

        sleep 1
    done

    echo -e "\n\n=== Pod Status Summary ==="

    # Check wrapping status for all pods
    local wrapped_count=0

    for pod_info in "${all_pod_names[@]}"; do
        local pod_name="${pod_info%%:*}"
        local status="Unknown"
        local wrapped="false"

        if [[ " ${ready_pods[@]} " =~ " ${pod_name} " ]]; then
            status="Ready"
            # Check if wrapped
            local pod_json=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o json 2>/dev/null)
            wrapped=$(echo "$pod_json" | jq -r '.metadata.annotations."rapidfort.io/wrapped" // "false"')
            if [[ "$wrapped" == "true" ]]; then
                wrapped_count=$((wrapped_count + 1))
            fi
        elif [[ " ${failed_pods[@]} " =~ " ${pod_name} " ]]; then
            status="Failed"
        else
            status="Pending"
        fi

        # Print status with color
        if [[ "$status" == "Ready" ]] && [[ "$wrapped" == "true" ]]; then
            echo -e "${GREEN}✓${NC} $pod_name: $status (wrapped)"
        elif [[ "$status" == "Ready" ]]; then
            echo -e "${YELLOW}⚠${NC} $pod_name: $status (NOT wrapped)"
        else
            echo -e "${RED}✗${NC} $pod_name: $status"
        fi
    done

    # Summary statistics
    echo -e "\n=== Final Statistics ==="
    echo "Total pods: ${#all_pod_names[@]}"
    echo "Ready: ${#ready_pods[@]}"
    echo "Failed: ${#failed_pods[@]}"
    echo "Wrapped: $wrapped_count"
    if [[ ${#all_pod_names[@]} -gt 0 ]]; then
        echo "Success rate: $((wrapped_count * 100 / ${#all_pod_names[@]}))%"
    else
        echo "Success rate: N/A"
    fi

    # Show some webhook logs
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "\n=== Recent Webhook Activity ==="
        kubectl logs -n rfruntime -l app=rfruntime --tail=20 | grep -E "(Wrapped|Patched|ERROR)" | tail -10 || echo "No webhook logs found"
    fi
}

# Check webhook configuration
check_webhook_config() {
    echo "=== RFRuntime Webhook Configuration Check ==="

    # Check if webhook exists
    if ! kubectl get mutatingwebhookconfigurations rfruntime-mutating-webhook &>/dev/null; then
        log_error "RFRuntime mutating webhook not found!"
        return 1
    fi

    log_success "RFRuntime mutating webhook found"

    # Get webhook details
    local webhook_json=$(kubectl get mutatingwebhookconfigurations rfruntime-mutating-webhook -o json)

    # Check namespace selector
    echo -e "\nNamespace Selector:"
    echo "$webhook_json" | jq '.webhooks[0].namespaceSelector' | head -5

    # Check if our test namespace has the required label
    local ns_labels=$(kubectl get namespace "$NAMESPACE" -o json 2>/dev/null | jq -r '.metadata.labels // {}')
    if [[ -n "$ns_labels" ]]; then
        echo -e "\nTest namespace labels:"
        echo "$ns_labels" | jq .
    fi

    echo
}

# Function to list available tests
list_tests() {
    echo "Available test applications:"
    echo
    local categories=("database" "messaging" "web" "monitoring" "cicd" "registry" "security" "runtime" "complex")

    for category in "${categories[@]}"; do
        echo "=== $category ==="
        create_test_yamls "$category" &>/dev/null

        for yaml in "$TEST_DIR"/*-*.yaml; do
            if [[ -f "$yaml" ]] && grep -q "category: $category" "$yaml"; then
                local name=$(basename "$yaml" .yaml)
                local image=$(grep "image:" "$yaml" | grep -A1 "kind: Pod" -B5 | grep "image:" | head -1 | awk '{print $2}')
                if [[ -z "$image" ]]; then
                    image=$(grep "image:" "$yaml" | head -1 | awk '{print $2}')
                fi

                # Check for additional resources
                local has_cm=$(grep -q "kind: ConfigMap" "$yaml" && echo " [+ConfigMap]" || echo "")
                local has_secret=$(grep -q "kind: Secret" "$yaml" && echo " [+Secret]" || echo "")

                printf "  %-25s %-40s%s%s\n" "$name" "$image" "$has_cm" "$has_secret"
            fi
        done
        echo
    done

    echo "Note: [+ConfigMap] and [+Secret] indicate additional resources included in the YAML"
    echo

    rm -rf "$TEST_DIR"
}

# Main execution
main() {
    # Handle list mode
    if [[ "$LIST_ONLY" == "true" ]]; then
        list_tests
        exit 0
    fi

    log_info "Runtime Complex Image Test Suite"
    log_info "Mode: $MODE"
    log_info "Namespace: $NAMESPACE"
    log_info "Cleanup: $CLEANUP (will delete all test resources on exit)"
    log_info "Timeout: ${WAIT_TIMEOUT}s"

    if [[ "$CLEANUP" == "true" ]]; then
        log_warn "Cleanup will delete all resources with label 'test=complex-entrypoint'"
        echo
    fi

    # Create namespace if needed
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_info "Creating namespace $NAMESPACE..."
        kubectl create namespace "$NAMESPACE"
    fi

    # Check webhook configuration
    #check_webhook_config

    # Create all test YAMLs
    log_info "Creating test applications..."
    create_test_yamls

    # Get apps to test
    local apps=($(get_test_apps "$TEST_PATTERN"))

    if [[ ${#apps[@]} -eq 0 ]]; then
        log_error "No applications match pattern: $TEST_PATTERN"
        exit 1
    fi

    log_info "Found ${#apps[@]} applications to test"

    # Execute based on mode
    case "$MODE" in
        interactive)
            for yaml in "${apps[@]}"; do
                test_pod "$yaml"
                if [[ "$yaml" != "${apps[-1]}" ]]; then
                    read -p "Press enter to continue to next test..." -r
                fi
            done
            ;;
        blast)
            blast_test "${apps[@]}"
            ;;
        single)
            if [[ ${#apps[@]} -ne 1 ]]; then
                log_error "Single mode requires exactly one match, found ${#apps[@]}"
                exit 1
            fi
            test_pod "${apps[0]}"
            ;;
        *)
            log_error "Invalid mode: $MODE"
            usage
            exit 1
            ;;
    esac

    log_success "Test completed!"
}

# Run main
main
