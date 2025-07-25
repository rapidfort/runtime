#!/bin/bash

# Kind Installation and Management Script
# Usage: ./play.sh [install|uninstall|status|help]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
KUBECONFIG_PATH="$HOME/.kube/config"
KIND_CLUSTER_NAME="kind"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5000"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to detect host IP if RF_LOCAL_REGISTRY not set
detect_host_ip() {
    local host_ip=""
    
    # First try RF_LOCAL_REGISTRY
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        echo "$RF_LOCAL_REGISTRY"
        return
    fi
    
    # Try to get IP from default route
    host_ip=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || true)
    
    if [[ -z "$host_ip" ]]; then
        # Fallback to hostname -I
        host_ip=$(hostname -I | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    fi
    
    if [[ -z "$host_ip" ]]; then
        # Last resort - try to get from network interfaces
        host_ip=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    fi
    
    echo "$host_ip"
}

# Function to show help
show_help() {
    cat << EOF
Kind Installation and Management Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install         Install Kind cluster with registry, ingress, and RapidFort Runtime
    uninstall       Remove everything completely
    status          Show Kind and registry status
    deploy-rapidfort Deploy RapidFort Runtime to existing kind cluster
    help            Show this help message

OPTIONS:
    --registry-ip   IP address for registry (optional, defaults to RF_LOCAL_REGISTRY)
    --local-registry Use local registry for RapidFort images
    --image-tag     Tag for RapidFort images (e.g., 3.1.32-dev6)
    -h, --help      Show this help

EXAMPLES:
    $0 install --registry-ip 100.100.100.100
    $0 install  # Uses RF_LOCAL_REGISTRY
    $0 status
    $0 deploy-rapidfort
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    $0 uninstall

WHAT IT DOES:
    - Installs Kind (Kubernetes in Docker)
    - Runs registry container on IP:5000 (HTTP)
    - Installs NGINX ingress controller
    - Configures Kind to use the registry
    - Automatically deploys RapidFort Runtime if credentials found

PREREQUISITES:
    - Docker should be running
    - RF_LOCAL_REGISTRY environment variable (or --registry-ip)
    - Docker configured with insecure-registries for IP:5000

RAPIDFORT RUNTIME:
    - Automatically deployed if both exist:
      1. ~/.rapidfort/credentials
      2. Helm installed
    - Can be deployed later with: $0 deploy-rapidfort

EOF
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    if [[ ! "$OSTYPE" == "linux-gnu"* ]]; then
        log_error "This script only supports Linux"
        exit 1
    fi

    local required_commands=("docker" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' not found"
            exit 1
        fi
    done

    # Check if docker is running
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start docker first."
        exit 1
    fi

    log_success "System requirements check passed"
}

# Function to check for existing kubeconfig
check_existing_kubeconfig() {
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        log_warning "Existing kubeconfig found at: $KUBECONFIG_PATH"
        log_warning "Backing it up to: $KUBECONFIG_PATH.backup"
        mv "$KUBECONFIG_PATH" "$KUBECONFIG_PATH.backup"
    fi
}

# Function to check if kind is installed
is_kind_installed() {
    command -v kind &> /dev/null
}

# Function to check if kind cluster is running
is_kind_running() {
    kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"
}

# Function to check if registry is running
is_registry_running() {
    docker ps --format "table {{.Names}}" | grep -q "^${REGISTRY_NAME}$"
}

# Function to get kind version
get_kind_version() {
    if is_kind_installed; then
        kind version 2>/dev/null | head -n1 || echo "unknown"
    else
        echo "not installed"
    fi
}

# Function to show status
show_status() {
    log_info "Kind Status Report"
    echo "=================="

    if is_kind_installed; then
        log_success "Kind installed: $(get_kind_version)"
    else
        log_warning "Kind not installed"
        return
    fi

    if is_kind_running; then
        log_success "Kind cluster '$KIND_CLUSTER_NAME' is running"
        
        if command -v kubectl &> /dev/null; then
            echo ""
            log_info "Cluster nodes:"
            kubectl get nodes 2>/dev/null || echo "  Unable to get cluster info"
            
            # Check ingress
            if kubectl get namespace ingress-nginx &>/dev/null; then
                echo ""
                log_info "NGINX ingress controller:"
                local ingress_status=$(kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
                if [[ -n "$ingress_status" ]] && [[ "$ingress_status" -gt 0 ]]; then
                    log_success "NGINX Ingress: Running"
                else
                    log_warning "NGINX Ingress: Not ready"
                fi
            fi
            
            # Check RapidFort Runtime
            if kubectl get namespace rapidfort &>/dev/null; then
                echo ""
                log_info "RapidFort Runtime:"
                local rf_status=$(kubectl get pods -n rapidfort -l app=rfruntime --no-headers 2>/dev/null | grep -c Running || echo 0)
                if [[ "$rf_status" -gt 0 ]]; then
                    log_success "RapidFort: Running ($rf_status pods)"
                    kubectl get pods -n rapidfort -l app=rfruntime --no-headers | awk '{print "  " $1 " " $3}'
                else
                    log_warning "RapidFort: Not running"
                fi
            fi
        fi
    else
        log_warning "Kind cluster not running"
    fi

    # Check registry
    if is_registry_running; then
        echo ""
        log_info "Registry status:"
        log_success "Registry: Running on port $REGISTRY_PORT"
        local registry_ip=$(docker inspect $REGISTRY_NAME --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
        if [[ -n "$registry_ip" ]]; then
            echo "  Registry Container IP: $registry_ip:$REGISTRY_PORT"
        fi
    else
        echo ""
        log_warning "Registry: Not running"
    fi
}

# Function to install kind binary
install_kind_binary() {
    if is_kind_installed; then
        log_info "Kind already installed"
        return
    fi

    log_info "Installing Kind binary..."
    
    # Download kind binary
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x ./kind
    mv ./kind /usr/local/bin/kind
    
    log_success "Kind binary installed"
}

# Function to deploy RapidFort Runtime
deploy_rapidfort() {
    log_info "Deploying RapidFort Runtime to kind cluster"
    
    # Check if kind cluster is running
    if ! kind get clusters 2>/dev/null | grep -q "^kind$" || ! kubectl cluster-info &>/dev/null; then
        log_error "kind cluster is not running. Install kind first with: $0 install"
        exit 1
    fi
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Please install helm first."
        log_info "Visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    # Check prerequisites
    if [[ ! -f "$HOME/.rapidfort/credentials" ]]; then
        log_error "RapidFort credentials not found at ~/.rapidfort/credentials"
        exit 1
    fi
    
    # Get registry IP
    local registry_ip=$(detect_host_ip)
    if [[ -z "$registry_ip" ]]; then
        log_error "Could not determine host IP address. Please set RF_LOCAL_REGISTRY"
        exit 1
    fi
    log_info "Using registry IP: $registry_ip"
    
    # Parse credentials
    local creds_file="$HOME/.rapidfort/credentials"
    export RF_ACCESS_ID=$(grep "access_id" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_SECRET_ACCESS_KEY=$(grep "secret_key" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_ROOT_URL=$(grep "rf_root_url" "$creds_file" | cut -d'=' -f2 | xargs)
    
    if [[ -z "$RF_ACCESS_ID" ]] || [[ -z "$RF_SECRET_ACCESS_KEY" ]] || [[ -z "$RF_ROOT_URL" ]]; then
        log_error "Invalid or incomplete RapidFort credentials"
        exit 1
    fi
    
    # Create namespace
    kubectl create namespace rapidfort --dry-run=client -o yaml | kubectl apply -f -
    
    # Create credentials secret
    kubectl create secret generic rfruntime-credentials \
        --namespace rapidfort \
        --from-literal=RF_ACCESS_ID="$RF_ACCESS_ID" \
        --from-literal=RF_SECRET_ACCESS_KEY="$RF_SECRET_ACCESS_KEY" \
        --from-literal=RF_ROOT_URL="$RF_ROOT_URL" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Check for local registry option
    local use_local_registry=false
    local runtime_chart="oci://quay.io/rapidfort/runtime"
    local image_tag=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --local-registry)
                use_local_registry=true
                shift
                ;;
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            --image-tag)
                image_tag="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Apply registry secret if exists
    local registry_secret_path="${HOME}/.rapidfort/rapidfort-registry-secret.yaml"
    if [[ -f "$registry_secret_path" ]]; then
        kubectl apply -f "$registry_secret_path" -n rapidfort
    else
        log_warning "Registry secret not found at: $registry_secret_path"
        if [[ "$use_local_registry" == "false" ]]; then
            log_warning "Registry secret may be required for pulling from quay.io"
        fi
    fi
    
    # Deploy RapidFort Runtime
    log_info "Installing RapidFort Runtime with Helm..."
    
    local helm_args=(
        "upgrade" "--install" "rfruntime"
        "$runtime_chart"
        "--namespace" "rapidfort"
        "--set" "ClusterName=kind"
        "--set" "ClusterCaption=kind Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=generic"
        "--set" "scan.enabled=true"
        "--set" "profile.enabled=false"
        "--wait" "--timeout=5m"
    )
    
    # Check if we should use local registry
    if [[ "$use_local_registry" == "true" ]] || [[ "$RF_USE_LOCAL_REGISTRY" == "true" ]]; then
        use_local_registry=true
        log_info "Using local registry for RapidFort Runtime images"
        
        # Override the registry value in values.yaml
        helm_args+=(
            "--set" "registry=$registry_ip:5000/rapidfort"
        )
        
        # If image tag is specified, use it
        if [[ -n "$image_tag" ]]; then
            helm_args+=("--set" "imageTag=$image_tag")
        fi
        
        # Set pull policy to Always for local registry
        helm_args+=("--set" "imagePullPolicy=Always")
        
        log_info "Note: Make sure all RapidFort images are available in local registry:"
        echo "  Images needed (example with tag 3.1.32-dev6):"
        echo "    - $registry_ip:5000/rapidfort/sentry:3.1.32-dev6"
        echo "    - $registry_ip:5000/rapidfort/controller:3.1.32-dev6"
        echo "    - $registry_ip:5000/rapidfort/rfwrap-init:3.1.32-dev6"
        echo "    - $registry_ip:5000/rapidfort/bpf:3.1.32-dev6"
        echo ""
        echo "  To push images (example):"
        echo "    docker pull quay.io/rapidfort/sentry:3.1.32-dev6"
        echo "    docker tag quay.io/rapidfort/sentry:3.1.32-dev6 $registry_ip:5000/rapidfort/sentry:3.1.32-dev6"
        echo "    docker push $registry_ip:5000/rapidfort/sentry:3.1.32-dev6"
        echo ""
        echo "  Helm will use registry: $registry_ip:5000/rapidfort"
        if [[ -n "$image_tag" ]]; then
            echo "  Image tag: $image_tag"
        fi
    else
        # Add imagePullSecrets for quay.io
        if [[ -f "$registry_secret_path" ]]; then
            helm_args+=("--set" "imagePullSecrets.names={rapidfort-registry-secret}")
        fi
    fi
    
    # Execute helm install
    if helm "${helm_args[@]}"; then
        log_success "RapidFort Runtime helm chart installed"
    else
        log_error "Helm installation failed"
        kubectl describe pods -n rapidfort
        exit 1
    fi
    
    # Check deployment
    log_info "Waiting for RapidFort Runtime pods to be ready..."
    if kubectl wait --for=condition=ready pod -l app=rfruntime -n rapidfort --timeout=300s; then
        log_success "RapidFort Runtime deployed successfully"
        echo ""
        kubectl get pods -n rapidfort -o wide
        echo ""
        echo "Commands:"
        echo "  # Check logs: kubectl logs -n rapidfort -l app=rfruntime -c sentry -f"
        echo "  # Check scan results: rfjobs"
        echo "  # Check runtime status: kubectl get pods -n rapidfort"
        echo "  # Check images being used: kubectl describe pods -n rapidfort | grep Image:"
    else
        log_error "RapidFort Runtime deployment failed"
        kubectl describe pods -n rapidfort
        exit 1
    fi
}

# Function to install everything
install_all() {
    local registry_ip="$1"
    
    # If no registry IP provided, use RF_LOCAL_REGISTRY or auto-detect
    if [[ -z "$registry_ip" ]]; then
        registry_ip=$(detect_host_ip)
        if [[ -z "$registry_ip" ]]; then
            log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY or use --registry-ip"
            exit 1
        fi
    fi
    
    log_info "Installing Kind cluster with registry at $registry_ip:$REGISTRY_PORT"
    
    check_requirements
    check_existing_kubeconfig
    
    if is_kind_running && is_registry_running; then
        log_warning "Kind cluster and registry already running"
        show_status
        return 0
    fi
    
    # Install kind binary
    install_kind_binary
    
    # Create registry container
    if ! is_registry_running; then
        log_info "Creating registry container..."
        docker run -d --restart=always \
            -p $registry_ip:$REGISTRY_PORT:5000 \
            --name $REGISTRY_NAME \
            registry:2
        
        # Wait for registry to be ready
        sleep 5
        if curl -s "http://$registry_ip:$REGISTRY_PORT/v2/" > /dev/null 2>&1; then
            log_success "Registry is running at $registry_ip:$REGISTRY_PORT"
        else
            log_warning "Registry may not be fully ready yet"
        fi
    fi
    
    # Create kind cluster with registry config
    if ! is_kind_running; then
        log_info "Creating Kind cluster..."
        
        # Create kind config
        cat << EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."$registry_ip:$REGISTRY_PORT"]
    endpoint = ["http://$REGISTRY_NAME:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."$registry_ip:$REGISTRY_PORT".tls]
    insecure_skip_verify = true
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."$REGISTRY_NAME:5000"]
    endpoint = ["http://$REGISTRY_NAME:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."$REGISTRY_NAME:5000".tls]
    insecure_skip_verify = true
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
        
        # Create the cluster
        kind create cluster --name $KIND_CLUSTER_NAME --config /tmp/kind-config.yaml
        
        # Clean up config file
        rm -f /tmp/kind-config.yaml
        
        log_success "Kind cluster created"
    fi
    
    # Setup kubeconfig
    log_info "Setting up kubeconfig..."
    mkdir -p ~/.kube
    kind get kubeconfig --name $KIND_CLUSTER_NAME > "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    
    # Connect registry to kind network
    log_info "Connecting registry to kind network..."
    docker network connect "kind" $REGISTRY_NAME 2>/dev/null || log_warning "Registry already connected to kind network"
    
    # Install NGINX ingress controller
    log_info "Installing NGINX ingress controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    
    # Wait for ingress controller
    log_info "Waiting for ingress controller..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s || log_warning "Ingress taking longer to start, continuing..."
    
    # Test registry
    log_info "Testing registry connectivity..."
    sleep 5
    
    if curl -s "http://$registry_ip:$REGISTRY_PORT/v2/" > /dev/null 2>&1; then
        log_success "Registry is accessible"
    else
        log_warning "Registry may not be fully ready yet"
    fi
    
    # Test with a real image
    log_info "Testing image push/pull..."
    if command -v docker &> /dev/null; then
        docker pull hello-world:latest
        docker tag hello-world:latest $registry_ip:$REGISTRY_PORT/hello-world:test
        docker push $registry_ip:$REGISTRY_PORT/hello-world:test
        
        # Test Kubernetes can pull the image
        kubectl run test-registry --image=$registry_ip:$REGISTRY_PORT/hello-world:test --command -- sleep 30
        kubectl wait --for=condition=ready pod/test-registry --timeout=60s && log_success "Kubernetes can pull from registry" || log_warning "Kubernetes pull test failed"
        kubectl delete pod test-registry --force
    fi
    
    log_success "Installation completed!"
    
    echo ""
    log_info "Cluster Details:"
    echo "  • Kind cluster: $KIND_CLUSTER_NAME"
    echo "  • Registry URL: http://$registry_ip:$REGISTRY_PORT"
    echo "  • Ingress: NGINX (ports 80/443 forwarded to host)"
    echo ""
    log_info "Usage:"
    echo "  # Push with docker (assuming docker is configured for insecure registry):"
    echo "  docker tag myimage:latest $registry_ip:$REGISTRY_PORT/myimage:latest"
    echo "  docker push $registry_ip:$REGISTRY_PORT/myimage:latest"
    echo ""
    echo "  # Use in Kubernetes:"
    echo "  image: $registry_ip:$REGISTRY_PORT/myimage:latest"
    
    # Deploy RapidFort Runtime if credentials exist and helm is available
    if [[ -f "$HOME/.rapidfort/credentials" ]] && command -v helm &> /dev/null; then
        log_info "Found RapidFort credentials and helm, deploying RapidFort Runtime..."
        deploy_rapidfort
    else
        if [[ ! -f "$HOME/.rapidfort/credentials" ]]; then
            log_info "RapidFort credentials not found at ~/.rapidfort/credentials"
        fi
        if ! command -v helm &> /dev/null; then
            log_info "Helm not found. Install helm to deploy RapidFort Runtime"
        fi
        log_info "To deploy RapidFort Runtime later:"
        echo "  1. Ensure credentials are in ~/.rapidfort/credentials"
        echo "  2. Install helm if not already installed"
        echo "  3. Run: $0 deploy-rapidfort"
    fi
    
    echo ""
    log_info "Kind Commands:"
    echo "  # Check cluster: kind get clusters"
    echo "  # Load image: kind load docker-image myimage:latest --name $KIND_CLUSTER_NAME"
    echo "  # Delete cluster: kind delete cluster --name $KIND_CLUSTER_NAME"
}

# Function to uninstall everything
uninstall_all() {
    log_info "Uninstalling everything..."
    
    # Uninstall RapidFort Runtime if present
    if command -v helm &> /dev/null && is_kind_running && kubectl get namespace rapidfort &>/dev/null 2>&1; then
        if helm list -n rapidfort 2>/dev/null | grep -q rfruntime; then
            log_info "Uninstalling RapidFort Runtime..."
            helm uninstall rfruntime -n rapidfort 2>/dev/null || true
            kubectl delete namespace rapidfort --force --grace-period=0 2>/dev/null || true
        fi
    fi
    
    # Delete kind cluster
    if is_kind_running; then
        log_info "Deleting Kind cluster..."
        kind delete cluster --name $KIND_CLUSTER_NAME
    fi
    
    # Remove registry container
    if is_registry_running; then
        log_info "Removing registry container..."
        docker stop $REGISTRY_NAME 2>/dev/null || true
        docker rm $REGISTRY_NAME 2>/dev/null || true
    fi
    
    # Remove kubeconfig
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        rm -f "$KUBECONFIG_PATH"
    fi
    
    # Restore backup if exists
    if [[ -f "$KUBECONFIG_PATH.backup" ]]; then
        mv "$KUBECONFIG_PATH.backup" "$KUBECONFIG_PATH"
        log_info "Restored previous kubeconfig"
    fi
    
    log_success "Uninstall completed"
}

# Main function
main() {
    local command="${1:-help}"
    local registry_ip=""
    
    shift || true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry-ip)
                registry_ip="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # Pass remaining args to deploy-rapidfort
                break
                ;;
        esac
    done
    
    case "$command" in
        "install")
            install_all "$registry_ip"
            ;;
        "uninstall")
            uninstall_all
            ;;
        "status")
            show_status
            ;;
        "deploy-rapidfort")
            deploy_rapidfort "$@"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"