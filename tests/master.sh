#!/bin/bash

# Master Script for Managing Multiple Kubernetes Cluster Types
# Usage: ./master.sh [cluster-type] [command] [options]
#        ./master.sh test-all

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration - Added zuul to supported clusters
SUPPORTED_CLUSTERS=("kubeadm" "k0s" "k3s" "kind" "microk8s" "minikube" "zuul")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
KUBECONFIG_PATH="$HOME/.kube/config"
LOG_DIR="$SCRIPT_DIR/logs"
COVERAGE_SCRIPT="$SCRIPT_DIR/coverage.sh"

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

log_header() {
    echo -e "\n${PURPLE}===================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}===================================================${NC}\n"
}

# Function to detect OS and architecture
detect_system() {
    local os=""
    local arch=""
    
    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        os="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        os="darwin"
    else
        log_error "Unsupported OS: $OSTYPE"
        return 1
    fi
    
    # Detect architecture
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *) 
            log_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac
    
    echo "${os}-${arch}"
}

# Function to install kubectl
install_kubectl() {
    log_info "Installing kubectl..."
    
    local system=$(detect_system)
    if [[ -z "$system" ]]; then
        return 1
    fi
    
    # Get latest stable version
    local version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    log_info "Installing kubectl version: $version"
    
    # Download kubectl
    local url="https://dl.k8s.io/release/${version}/bin/${system%%-*}/${system##*-}/kubectl"
    
    if command -v wget &> /dev/null; then
        wget -q -O /tmp/kubectl "$url"
    elif command -v curl &> /dev/null; then
        curl -L -s -o /tmp/kubectl "$url"
    else
        log_error "Neither wget nor curl is available"
        return 1
    fi
    
    # Install kubectl
    chmod +x /tmp/kubectl
    if [[ $EUID -eq 0 ]]; then
        mv /tmp/kubectl /usr/local/bin/kubectl
    else
        log_info "Installing kubectl to user directory..."
        mkdir -p "$HOME/.local/bin"
        mv /tmp/kubectl "$HOME/.local/bin/kubectl"
        export PATH="$HOME/.local/bin:$PATH"
        log_warning "kubectl installed to $HOME/.local/bin/"
        log_warning "Make sure $HOME/.local/bin is in your PATH"
    fi
    
    # Verify installation
    if kubectl version --client &>/dev/null; then
        log_success "kubectl installed successfully"
        kubectl version --client --short
        return 0
    else
        log_error "kubectl installation failed"
        return 1
    fi
}

# Function to install helm
install_helm() {
    log_info "Installing helm..."
    
    local system=$(detect_system)
    if [[ -z "$system" ]]; then
        return 1
    fi
    
    # Download helm installation script
    local helm_script="/tmp/get_helm.sh"
    
    if command -v wget &> /dev/null; then
        wget -q -O "$helm_script" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    elif command -v curl &> /dev/null; then
        curl -fsSL -o "$helm_script" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    else
        log_error "Neither wget nor curl is available"
        return 1
    fi
    
    chmod 700 "$helm_script"
    
    # Install helm
    if [[ $EUID -eq 0 ]]; then
        bash "$helm_script"
    else
        # Install to user directory
        HELM_INSTALL_DIR="$HOME/.local/bin" bash "$helm_script" --no-sudo
        export PATH="$HOME/.local/bin:$PATH"
        log_warning "helm installed to $HOME/.local/bin/"
        log_warning "Make sure $HOME/.local/bin is in your PATH"
    fi
    
    rm -f "$helm_script"
    
    # Verify installation
    if helm version &>/dev/null; then
        log_success "helm installed successfully"
        helm version --short
        return 0
    else
        log_error "helm installation failed"
        return 1
    fi
}

# Function to install yq
install_yq() {
    log_info "Installing yq..."
    
    local system=$(detect_system)
    if [[ -z "$system" ]]; then
        return 1
    fi
    
    # Get latest version
    local version=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$version" ]]; then
        version="v4.35.2"  # Fallback version
    fi
    
    log_info "Installing yq version: $version"
    
    # Download yq
    local binary_name="yq_${system}"
    local url="https://github.com/mikefarah/yq/releases/download/${version}/${binary_name}"
    
    if command -v wget &> /dev/null; then
        wget -q -O /tmp/yq "$url"
    elif command -v curl &> /dev/null; then
        curl -L -s -o /tmp/yq "$url"
    else
        log_error "Neither wget nor curl is available"
        return 1
    fi
    
    # Install yq
    chmod +x /tmp/yq
    if [[ $EUID -eq 0 ]]; then
        mv /tmp/yq /usr/local/bin/yq
    else
        log_info "Installing yq to user directory..."
        mkdir -p "$HOME/.local/bin"
        mv /tmp/yq "$HOME/.local/bin/yq"
        export PATH="$HOME/.local/bin:$PATH"
        log_warning "yq installed to $HOME/.local/bin/"
        log_warning "Make sure $HOME/.local/bin is in your PATH"
    fi
    
    # Verify installation
    if yq --version &>/dev/null; then
        log_success "yq installed successfully"
        yq --version
        return 0
    else
        log_error "yq installation failed"
        return 1
    fi
}

# Function to check and install dependencies
check_and_install_dependencies() {
    log_header "Checking Dependencies"
    
    local deps_missing=false
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl is not installed"
        if [[ "${INSTALL_DEPS:-true}" == "true" ]]; then
            install_kubectl || deps_missing=true
        else
            deps_missing=true
        fi
    else
        log_success "kubectl is available: $(kubectl version --client --short 2>/dev/null || kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        log_warning "helm is not installed"
        if [[ "${INSTALL_DEPS:-true}" == "true" ]]; then
            install_helm || deps_missing=true
        else
            deps_missing=true
        fi
    else
        log_success "helm is available: $(helm version --short)"
    fi
    
    # Check yq
    if ! command -v yq &> /dev/null; then
        log_warning "yq is not installed"
        if [[ "${INSTALL_DEPS:-true}" == "true" ]]; then
            install_yq || deps_missing=true
        else
            deps_missing=true
        fi
    else
        log_success "yq is available: $(yq --version)"
    fi
    
    # Check other common dependencies
    local required_commands=("docker" "git" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_warning "$cmd is not installed"
            deps_missing=true
        else
            log_success "$cmd is available"
        fi
    done
    
    if [[ "$deps_missing" == "true" ]]; then
        log_error "Some dependencies are missing"
        log_info "To disable automatic installation, set INSTALL_DEPS=false"
        if [[ "${INSTALL_DEPS:-true}" != "true" ]]; then
            log_info "Please install missing dependencies manually"
            return 1
        fi
    else
        log_success "All dependencies are satisfied"
    fi
    
    # Update PATH if needed
    if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    return 0
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

# Function to check RF_LOCAL_REGISTRY
check_registry_ip() {
    if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
        log_error "RF_LOCAL_REGISTRY environment variable is not set"
        log_error "Please set it to your registry IP address:"
        echo "  export RF_LOCAL_REGISTRY=<your-registry-ip>"
        exit 1
    fi
    
    log_info "Using registry IP: $RF_LOCAL_REGISTRY"
}

# Function to show help
show_help() {
    cat << EOF
Kubernetes Cluster Management Master Script

USAGE:
    $0 [cluster-type] [command] [options]
    $0 test-all [options]
    $0 deploy-rapidfort [cluster-type] [options]
    $0 check-deps
    $0 help

CLUSTER TYPES:
    kubeadm    - Kubernetes via kubeadm
    k0s        - k0s lightweight Kubernetes
    k3s        - k3s lightweight Kubernetes
    kind       - Kubernetes in Docker
    microk8s   - Canonical MicroK8s
    minikube   - Minikube
    zuul       - Zuul-based deployment (simulates CI/CD environment)

COMMANDS:
    install         - Install the specified cluster type
    uninstall       - Uninstall the specified cluster type
    status          - Show status of the specified cluster type
    test            - Install, deploy RF runtime, run tests, then uninstall
    deploy-rapidfort - Deploy RapidFort Runtime to existing cluster
    
SPECIAL COMMANDS:
    test-all        - Test all cluster types sequentially
    list            - List all supported cluster types
    check-deps      - Check and install missing dependencies
    help            - Show this help message

OPTIONS:
    --skip-runtime     Skip RapidFort runtime deployment
    --skip-coverage    Skip coverage test
    --keep-cluster     Don't uninstall after testing
    --log-file         Save output to log file
    --timeout          Timeout for operations (default: 600s)
    --strict           For zuul: Apply strict security policies
    --local-registry   Use local registry for RapidFort images
    --image-tag        Tag for RapidFort images (e.g., 3.1.32-dev6)
    --no-deps          Don't automatically install missing dependencies

ENVIRONMENT VARIABLES:
    RF_LOCAL_REGISTRY  - Registry IP address (auto-detected if not set)
    INSTALL_DEPS       - Set to 'false' to disable automatic dependency installation

EXAMPLES:
    # Check and install dependencies
    $0 check-deps
    
    # Install k0s cluster
    $0 k0s install
    
    # Install zuul cluster with strict security
    $0 zuul install --strict
    
    # Deploy RapidFort to existing cluster
    $0 deploy-rapidfort
    
    # Deploy RapidFort to specific cluster type
    $0 deploy-rapidfort k3s
    
    # Deploy RapidFort from local registry
    $0 deploy-rapidfort --local-registry --image-tag 3.1.32-dev6
    
    # Show status of kind cluster
    $0 kind status
    
    # Test k3s (install, deploy RF, run tests, uninstall)
    $0 k3s test
    
    # Test with local registry
    $0 k3s test --local-registry --image-tag 3.1.32-dev6
    
    # Test all cluster types
    $0 test-all
    
    # Test all but keep clusters after testing
    $0 test-all --keep-cluster

REQUIREMENTS:
    - RF_LOCAL_REGISTRY environment variable must be set (or auto-detected)
    - Root/sudo access for most cluster types
    - Docker for kind/minikube
    - Each cluster's play.sh in respective folder
    - RapidFort credentials in ~/.rapidfort/credentials
    - kubectl, helm, yq (will be installed automatically if missing)

EOF
}

# Function to check if cluster folder exists
check_cluster_folder() {
    local cluster_type="$1"
    local cluster_dir="$SCRIPT_DIR/$cluster_type"
    
    if [[ ! -d "$cluster_dir" ]]; then
        log_error "Cluster directory not found: $cluster_dir"
        return 1
    fi
    
    if [[ ! -f "$cluster_dir/play.sh" ]]; then
        log_error "play.sh not found in: $cluster_dir"
        return 1
    fi
    
    if [[ ! -x "$cluster_dir/play.sh" ]]; then
        log_warning "play.sh is not executable, fixing..."
        chmod +x "$cluster_dir/play.sh"
    fi
    
    return 0
}

# Function to run cluster command
run_cluster_command() {
    local cluster_type="$1"
    local command="$2"
    shift 2
    local extra_args=("$@")
    
    local cluster_dir="$SCRIPT_DIR/$cluster_type"
    local play_script="$cluster_dir/play.sh"
    
    log_info "Running: $cluster_type $command"
    
    # Build command args based on cluster type
    local cmd_args=("$command")
    
    if [[ "$command" == "install" ]]; then
        # Add registry IP for install command
        case "$cluster_type" in
            kubeadm)
                # kubeadm uses RF_LOCAL_REGISTRY directly
                ;;
            zuul)
                # zuul doesn't need registry-ip flag, but may need --strict
                ;;
            k0s)
                cmd_args+=("--registry-ip" "$RF_LOCAL_REGISTRY")
                ;;
            k3s|kind|microk8s|minikube)
                cmd_args+=("--registry-ip" "$RF_LOCAL_REGISTRY")
                ;;
        esac
    fi
    
    # Add any extra arguments
    cmd_args+=("${extra_args[@]}")
    
    # Change to cluster directory and run
    cd "$cluster_dir"
    
    if [[ -n "$LOG_FILE" ]]; then
        "$play_script" "${cmd_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    else
        "$play_script" "${cmd_args[@]}"
    fi
    
    local exit_code=$?
    cd "$SCRIPT_DIR"
    
    return $exit_code
}

# Function to wait for all pods to be ready
wait_for_pods_ready() {
    local timeout="${1:-300}"
    local namespace="${2:-}"
    
    log_info "Waiting for all pods to be ready..."
    
    local cmd="kubectl get pods"
    if [[ -n "$namespace" ]]; then
        cmd="$cmd -n $namespace"
    else
        cmd="$cmd --all-namespaces"
    fi
    
    local start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -gt $timeout ]]; then
            log_error "Timeout waiting for pods to be ready"
            return 1
        fi
        
        # Check if all pods are ready
        local not_ready=$($cmd 2>/dev/null | grep -v "STATUS" | grep -v "Running" | grep -v "Completed" | wc -l || echo "999")
        
        if [[ "$not_ready" -eq 0 ]]; then
            log_success "All pods are ready"
            return 0
        fi
        
        echo -n "."
        sleep 5
    done
}

# Function to deploy RapidFort runtime
deploy_rapidfort_runtime() {
    local cluster_type="${1:-$CURRENT_CLUSTER_TYPE}"
    local use_local_registry="false"
    local image_tag=""
    
    # Parse additional arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --local-registry) use_local_registry="true"; shift ;;
            --image-tag) image_tag="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    # If no cluster type specified, try to detect from current context
    if [[ -z "$cluster_type" ]]; then
        log_info "Detecting cluster type from current context..."
        
        # Try to detect based on various indicators
        if kubectl get nodes -o wide 2>/dev/null | grep -q "k0s"; then
            cluster_type="k0s"
        elif kubectl get nodes -o wide 2>/dev/null | grep -q "k3s"; then
            cluster_type="k3s"
        elif kubectl get nodes -o wide 2>/dev/null | grep -q "minikube"; then
            cluster_type="minikube"
        elif kubectl get nodes -o wide 2>/dev/null | grep -q "kind"; then
            cluster_type="kind"
        elif kubectl get nodes -o wide 2>/dev/null | grep -q "microk8s"; then
            cluster_type="microk8s"
        else
            cluster_type="generic"
        fi
        
        log_info "Detected cluster type: $cluster_type"
    fi
    
    log_info "Deploying RapidFort Runtime for $cluster_type cluster..."
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Please install helm first."
        log_info "Visit: https://helm.sh/docs/intro/install/"
        return 1
    fi
        
    # Get registry IP
    local registry_ip=""
    if [[ -n "$RF_LOCAL_REGISTRY" ]]; then
        registry_ip="$RF_LOCAL_REGISTRY"
    else
        # Auto-detect IP
        registry_ip=$(detect_host_ip)
    fi
    
    if [[ -z "$registry_ip" ]]; then
        log_error "Could not determine registry IP. Please set RF_LOCAL_REGISTRY"
        return 1
    fi
    
    log_info "Using registry IP: $registry_ip"
    
    local creds_file="$HOME/.rapidfort/credentials"
    if [[ -f "$creds_file" ]]; then
        export RF_ACCESS_ID=$(grep "access_id" "$creds_file" | cut -d'=' -f2 | xargs)
        export RF_SECRET_ACCESS_KEY=$(grep "secret_key" "$creds_file" | cut -d'=' -f2 | xargs)
        export RF_ROOT_URL=$(grep "rf_root_url" "$creds_file" | cut -d'=' -f2 | xargs)
    fi

    if [[ -z "$RF_ACCESS_ID" ]] || [[ -z "$RF_SECRET_ACCESS_KEY" ]] || [[ -z "$RF_ROOT_URL" ]]; then
        log_error "Invalid or incomplete RapidFort credentials"
        return 1
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
    
    # Apply registry secret if exists
    local registry_secret_path="${HOME}/.rapidfort/rapidfort-registry-secret.yaml"
    if [[ -f "$registry_secret_path" ]]; then
        kubectl apply -f "$registry_secret_path" -n rapidfort
    else
        if [[ "$use_local_registry" != "true" ]]; then
            log_warning "Registry secret not found at: $registry_secret_path"
            log_warning "This may be required for pulling from quay.io"
        fi
    fi
    
    # Install RapidFort Runtime with Helm
    log_info "Installing RapidFort Runtime with Helm..."
    
    # Determine variant based on cluster type
    local variant="generic"
    case "$cluster_type" in
        k0s) variant="k0s" ;;
        k3s) variant="k3s" ;;
        *) variant="generic" ;;
    esac
    
    # Build helm arguments
    local helm_args=(
        "upgrade" "--install" "rfruntime"
        "oci://quay.io/rapidfort/runtime"
        "--namespace" "rapidfort"
        "--set" "ClusterName=$cluster_type"
        "--set" "ClusterCaption=$cluster_type Cluster"
        "--set" "rapidfort.credentialsSecret=rfruntime-credentials"
        "--set" "variant=$variant"
        "--set" "scan.enabled=true"
        "--set" "profile.enabled=false"
        "--wait" "--timeout=5m"
    )
    
    # Check if we should use local registry
    if [[ "$use_local_registry" == "true" ]] || [[ "$RF_USE_LOCAL_REGISTRY" == "true" ]]; then
        log_info "Configuring RapidFort Runtime to use local registry"
        
        # Override the registry in values.yaml
        helm_args+=("--set" "registry=$registry_ip:5000/rapidfort")
        
        # Set image tag if specified
        if [[ -n "$image_tag" ]]; then
            helm_args+=("--set" "imageTag=$image_tag")
        fi
        
        # Always pull from local registry
        helm_args+=("--set" "imagePullPolicy=Always")
        
        log_info "RapidFort images will be pulled from: $registry_ip:5000/rapidfort"
        log_info "Make sure the following images are available:"
        local tag_info=""
        if [[ -n "$image_tag" ]]; then
            tag_info=":$image_tag"
        fi
        echo "  - $registry_ip:5000/rapidfort/sentry$tag_info"
        echo "  - $registry_ip:5000/rapidfort/controller$tag_info"
        echo "  - $registry_ip:5000/rapidfort/rfwrap-init$tag_info"
        echo "  - $registry_ip:5000/rapidfort/bpf$tag_info"
    else
        # Add imagePullSecrets for quay.io if registry secret exists
        if [[ -f "$registry_secret_path" ]]; then
            helm_args+=("--set" "imagePullSecrets.names={rapidfort-registry-secret}")
        fi
    fi
    
    # Execute helm install
    if helm "${helm_args[@]}"; then
        log_success "RapidFort Runtime helm chart installed"
    else
        log_error "Helm installation failed"
        return 1
    fi
    
    # Wait for RapidFort pods to be ready
    log_info "Waiting for RapidFort Runtime to be ready..."
    wait_for_pods_ready 300 rapidfort
    
    # Verify deployment
    local rf_pods=$(kubectl get pods -n rapidfort -l app=rfruntime --no-headers | grep -c Running || echo 0)
    if [[ "$rf_pods" -gt 0 ]]; then
        log_success "RapidFort Runtime deployed successfully ($rf_pods pods running)"
        kubectl get pods -n rapidfort
        return 0
    else
        log_error "RapidFort Runtime deployment failed"
        kubectl get pods -n rapidfort
        return 1
    fi
}

# Function to run coverage test
run_coverage_test() {
    log_info "Running coverage test..."
    
    if [[ ! -f "$COVERAGE_SCRIPT" ]]; then
        log_warning "coverage.sh not found at: $COVERAGE_SCRIPT"
        log_warning "Skipping coverage test"
        return 1
    fi
    
    if [[ ! -x "$COVERAGE_SCRIPT" ]]; then
        chmod +x "$COVERAGE_SCRIPT"
    fi
    
    log_info "Executing: coverage.sh -m blast -c"
    "$COVERAGE_SCRIPT" -m blast -c
    
    # Wait for all pods to be ready after coverage deployment
    log_info "Waiting for all coverage test pods to be ready..."
    wait_for_pods_ready 900
    
    log_success "Coverage test completed"
    return 0
}

# Function to test a single cluster type
test_cluster() {
    local cluster_type="$1"
    local skip_runtime="$2"
    local skip_coverage="$3"
    local keep_cluster="$4"
    shift 4 || true
    local extra_args=("$@")
    
    export CURRENT_CLUSTER_TYPE="$cluster_type"
    
    log_header "Testing $cluster_type cluster"
    
    # Check if cluster folder exists
    if ! check_cluster_folder "$cluster_type"; then
        log_error "Cannot test $cluster_type - folder/script not found"
        return 1
    fi
    
    # Install cluster
    log_info "Installing $cluster_type cluster..."
    if ! run_cluster_command "$cluster_type" "install"; then
        log_error "Failed to install $cluster_type cluster"
        return 1
    fi
    
    # Wait for cluster to stabilize
    log_info "Waiting for cluster to stabilize..."
    sleep 30
    wait_for_pods_ready 300
    
    # Deploy RapidFort Runtime
    if [[ "$skip_runtime" != "true" ]]; then
        if ! deploy_rapidfort_runtime "$cluster_type" "${extra_args[@]}"; then
            log_warning "Failed to deploy RapidFort Runtime"
            # Continue with test even if RF deployment fails
        fi
    else
        log_info "Skipping RapidFort Runtime deployment"
    fi
    
    # Run coverage test
    if [[ "$skip_coverage" != "true" ]]; then
        if ! run_coverage_test; then
            log_warning "Coverage test failed or was skipped"
            # Continue even if coverage test fails
        fi
    else
        log_info "Skipping coverage test"
    fi
    
    # Show final status
    log_info "Final cluster status:"
    run_cluster_command "$cluster_type" "status"
    
    # For zuul, also run test-ctr command
    if [[ "$cluster_type" == "zuul" ]]; then
        log_info "Running zuul-specific ctr tests..."
        run_cluster_command "$cluster_type" "test-ctr"
    fi
    
    # Uninstall cluster
    if [[ "$keep_cluster" != "true" ]]; then
        log_info "Uninstalling $cluster_type cluster..."
        if ! run_cluster_command "$cluster_type" "uninstall"; then
            log_error "Failed to uninstall $cluster_type cluster"
            return 1
        fi
    else
        log_info "Keeping $cluster_type cluster as requested"
    fi
    
    log_success "$cluster_type test completed"
    return 0
}

# Function to test all cluster types
test_all_clusters() {
    local skip_runtime="$1"
    local skip_coverage="$2"
    local keep_cluster="$3"
    shift 3 || true
    local extra_args=("$@")
    
    log_header "Testing All Kubernetes Cluster Types"
    log_info "Registry IP: $RF_LOCAL_REGISTRY"
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local summary_file="$LOG_DIR/test_summary_$timestamp.log"
    
    # Initialize summary
    echo "Kubernetes Cluster Test Summary - $(date)" > "$summary_file"
    echo "Registry IP: $RF_LOCAL_REGISTRY" >> "$summary_file"
    echo "======================================" >> "$summary_file"
    echo "" >> "$summary_file"
    
    local total_clusters=${#SUPPORTED_CLUSTERS[@]}
    local passed=0
    local failed=0
    local skipped=0
    
    # Test each cluster type
    for cluster_type in "${SUPPORTED_CLUSTERS[@]}"; do
        echo "" >> "$summary_file"
        echo "Testing $cluster_type..." >> "$summary_file"
        
        # Set log file for this cluster
        export LOG_FILE="$LOG_DIR/${cluster_type}_$timestamp.log"
        
        if ! check_cluster_folder "$cluster_type"; then
            log_warning "Skipping $cluster_type - folder not found"
            echo "  Status: SKIPPED (folder not found)" >> "$summary_file"
            ((skipped++))
            continue
        fi
        
        local start_time=$(date +%s)
        
        if test_cluster "$cluster_type" "$skip_runtime" "$skip_coverage" "$keep_cluster" "${extra_args[@]}"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "$cluster_type: PASSED (Duration: ${duration}s)"
            echo "  Status: PASSED" >> "$summary_file"
            echo "  Duration: ${duration}s" >> "$summary_file"
            ((passed++))
        else
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_error "$cluster_type: FAILED (Duration: ${duration}s)"
            echo "  Status: FAILED" >> "$summary_file"
            echo "  Duration: ${duration}s" >> "$summary_file"
            ((failed++))
        fi
        
        # Add separator between clusters
        if [[ "$cluster_type" != "${SUPPORTED_CLUSTERS[-1]}" ]]; then
            log_info "Waiting before next cluster test..."
            sleep 30
        fi
    done
    
    # Summary
    echo "" >> "$summary_file"
    echo "======================================" >> "$summary_file"
    echo "SUMMARY:" >> "$summary_file"
    echo "  Total: $total_clusters" >> "$summary_file"
    echo "  Passed: $passed" >> "$summary_file"
    echo "  Failed: $failed" >> "$summary_file"
    echo "  Skipped: $skipped" >> "$summary_file"
    echo "======================================" >> "$summary_file"
    
    log_header "Test Summary"
    cat "$summary_file"
    
    log_info "Detailed logs saved in: $LOG_DIR"
    
    if [[ $failed -eq 0 && $skipped -eq 0 ]]; then
        log_success "All cluster tests passed!"
        return 0
    else
        if [[ $failed -gt 0 ]]; then
            log_error "$failed cluster(s) failed"
        fi
        if [[ $skipped -gt 0 ]]; then
            log_warning "$skipped cluster(s) skipped"
        fi
        return 1
    fi
}

# Function to list supported clusters
list_clusters() {
    log_header "Supported Kubernetes Cluster Types"
    
    for cluster_type in "${SUPPORTED_CLUSTERS[@]}"; do
        if check_cluster_folder "$cluster_type" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $cluster_type"
        else
            echo -e "  ${RED}✗${NC} $cluster_type (folder not found)"
        fi
    done
}

# Main function
main() {
    local command="${1:-help}"
    local cluster_type=""
    local skip_runtime="false"
    local skip_coverage="false"
    local keep_cluster="false"
    local timeout="600"
    local strict_mode="false"
    local use_local_registry="false"
    local image_tag=""
    local skip_deps_check="false"
    
    # Check for special commands first
    case "$command" in
        help|--help|-h)
            show_help
            exit 0
            ;;
        list)
            list_clusters
            exit 0
            ;;
        check-deps)
            check_and_install_dependencies
            exit $?
            ;;
        deploy-rapidfort)
            shift
            cluster_type="${1:-}"
            shift || true
            
            # Check dependencies first
            if [[ "$skip_deps_check" != "true" ]]; then
                check_and_install_dependencies || exit 1
            fi
            
            # Check if we have a working kubectl
            if ! kubectl cluster-info &>/dev/null; then
                log_error "No active Kubernetes cluster found"
                log_info "Please ensure kubectl is configured and cluster is running"
                exit 1
            fi
            
            # Deploy RapidFort Runtime with remaining arguments
            deploy_rapidfort_runtime "$cluster_type" "$@"
            exit $?
            ;;
        test-all)
            shift
            # Parse options for test-all
            local extra_args=()
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --skip-runtime) skip_runtime="true"; shift ;;
                    --skip-coverage) skip_coverage="true"; shift ;;
                    --keep-cluster) keep_cluster="true"; shift ;;
                    --timeout) timeout="$2"; shift 2 ;;
                    --local-registry) extra_args+=("--local-registry"); shift ;;
                    --image-tag) extra_args+=("--image-tag" "$2"); shift 2 ;;
                    --no-deps) skip_deps_check="true"; shift ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done
            
            # Check dependencies first
            if [[ "$skip_deps_check" != "true" ]]; then
                check_and_install_dependencies || exit 1
            fi
            
            # Set RF_LOCAL_REGISTRY if not set
            if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
                RF_LOCAL_REGISTRY=$(detect_host_ip)
                if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
                    log_error "Could not detect registry IP. Please set RF_LOCAL_REGISTRY"
                    exit 1
                fi
                export RF_LOCAL_REGISTRY
            fi
            
            test_all_clusters "$skip_runtime" "$skip_coverage" "$keep_cluster" "${extra_args[@]}"
            exit $?
            ;;
    esac
    
    # For cluster-specific commands
    if [[ -n "$1" ]]; then
        cluster_type="$1"
        shift
        
        # Validate cluster type
        if [[ ! " ${SUPPORTED_CLUSTERS[@]} " =~ " ${cluster_type} " ]]; then
            log_error "Unknown cluster type: $cluster_type"
            log_info "Supported types: ${SUPPORTED_CLUSTERS[*]}"
            exit 1
        fi
        
        command="${1:-help}"
        shift
    else
        show_help
        exit 0
    fi
    
    # Parse remaining options
    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-runtime) skip_runtime="true"; shift ;;
            --skip-coverage) skip_coverage="true"; shift ;;
            --keep-cluster) keep_cluster="true"; shift ;;
            --log-file) LOG_FILE="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --strict) 
                strict_mode="true"
                extra_args+=("--strict")
                shift 
                ;;
            --local-registry) extra_args+=("--local-registry"); shift ;;
            --image-tag) extra_args+=("--image-tag" "$2"); shift 2 ;;
            --no-deps) skip_deps_check="true"; shift ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done
    
    # Check dependencies first (unless explicitly skipped)
    if [[ "$skip_deps_check" != "true" ]] && [[ "$command" != "help" ]] && [[ "$command" != "--help" ]] && [[ "$command" != "-h" ]]; then
        check_and_install_dependencies || exit 1
    fi
    
    # Execute command
    case "$command" in
        install|uninstall|status)
            if [[ "$cluster_type" != "zuul" ]]; then
                if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
                    RF_LOCAL_REGISTRY=$(detect_host_ip)
                    if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
                        log_error "Could not detect registry IP. Please set RF_LOCAL_REGISTRY"
                        exit 1
                    fi
                    export RF_LOCAL_REGISTRY
                fi
            fi
            check_cluster_folder "$cluster_type" || exit 1
            export CURRENT_CLUSTER_TYPE="$cluster_type"
            run_cluster_command "$cluster_type" "$command" "${extra_args[@]}"
            ;;
        test)
            if [[ "$cluster_type" != "zuul" ]]; then
                if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
                    RF_LOCAL_REGISTRY=$(detect_host_ip)
                    if [[ -z "$RF_LOCAL_REGISTRY" ]]; then
                        log_error "Could not detect registry IP. Please set RF_LOCAL_REGISTRY"
                        exit 1
                    fi
                    export RF_LOCAL_REGISTRY
                fi
            fi
            export CURRENT_CLUSTER_TYPE="$cluster_type"
            test_cluster "$cluster_type" "$skip_runtime" "$skip_coverage" "$keep_cluster" "${extra_args[@]}"
            ;;
        test-ctr|debug)
            # Pass through commands for zuul
            check_cluster_folder "$cluster_type" || exit 1
            export CURRENT_CLUSTER_TYPE="$cluster_type"
            run_cluster_command "$cluster_type" "$command" "${extra_args[@]}"
            ;;
        help|--help|-h)
            # Show cluster-specific help
            check_cluster_folder "$cluster_type" || exit 1
            run_cluster_command "$cluster_type" "help"
            ;;
        *)
            log_error "Unknown command: $command"
            log_info "Valid commands: install, uninstall, status, test, deploy-rapidfort, help"
            if [[ "$cluster_type" == "zuul" ]]; then
                log_info "Zuul-specific commands: test-ctr, debug"
            fi
            exit 1
            ;;
    esac
}

# Check if running with sudo when needed
check_sudo() {
    if [[ $EUID -ne 0 ]] && [[ "$1" != "help" ]] && [[ "$1" != "list" ]] && [[ "$1" != "--help" ]] && [[ "$1" != "-h" ]] && [[ "$1" != "check-deps" ]]; then
        log_warning "Most operations require root privileges"
        log_info "Consider running with: sudo $0 $@"
    fi
}

# Run checks and main
check_sudo "$@"
main "$@"