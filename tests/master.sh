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

# Configuration
SUPPORTED_CLUSTERS=("kubeadm" "k0s" "k3s" "kind" "microk8s" "minikube")
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
    $0 help

CLUSTER TYPES:
    kubeadm    - Kubernetes via kubeadm
    k0s        - k0s lightweight Kubernetes
    k3s        - k3s lightweight Kubernetes
    kind       - Kubernetes in Docker
    microk8s   - Canonical MicroK8s
    minikube   - Minikube

COMMANDS:
    install    - Install the specified cluster type
    uninstall  - Uninstall the specified cluster type
    status     - Show status of the specified cluster type
    test       - Install, deploy RF runtime, run tests, then uninstall
    
SPECIAL COMMANDS:
    test-all   - Test all cluster types sequentially
    list       - List all supported cluster types
    help       - Show this help message

OPTIONS:
    --skip-runtime     Skip RapidFort runtime deployment
    --skip-coverage    Skip coverage test
    --keep-cluster     Don't uninstall after testing
    --log-file         Save output to log file
    --timeout          Timeout for operations (default: 600s)

EXAMPLES:
    # Install k0s cluster
    $0 k0s install
    
    # Show status of kind cluster
    $0 kind status
    
    # Test k3s (install, deploy RF, run tests, uninstall)
    $0 k3s test
    
    # Test all cluster types
    $0 test-all
    
    # Test all but keep clusters after testing
    $0 test-all --keep-cluster

REQUIREMENTS:
    - RF_LOCAL_REGISTRY environment variable must be set
    - Root/sudo access for most cluster types
    - Docker for kind/minikube
    - Each cluster's play.sh in respective folder
    - RapidFort credentials in ~/.rapidfort/credentials
    - Helm installed for RapidFort Runtime deployment

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
    
    log_info "Deploying RapidFort Runtime for $cluster_type cluster..."
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Please install helm first."
        log_info "Visit: https://helm.sh/docs/intro/install/"
        return 1
    fi
    
    # Check if credentials exist
    if [[ ! -f "$HOME/.rapidfort/credentials" ]]; then
        log_warning "RapidFort credentials not found at ~/.rapidfort/credentials"
        log_warning "Skipping RapidFort runtime deployment"
        return 1
    fi
    

    local creds_file="$HOME/.rapidfort/credentials"
    export RF_ACCESS_ID=$(grep "access_id" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_SECRET_ACCESS_KEY=$(grep "secret_key" "$creds_file" | cut -d'=' -f2 | xargs)
    export RF_ROOT_URL=$(grep "rf_root_url" "$creds_file" | cut -d'=' -f2 | xargs)

    
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
    
    # Check for registry secret
    local registry_secret_path="$SCRIPT_DIR/rapidfort-registry-secret.yaml"
    if [[ ! -f "$registry_secret_path" ]]; then
        # Try parent directory
        registry_secret_path="$SCRIPT_DIR/../rapidfort-registry-secret.yaml"
    fi
    
    if [[ -f "$registry_secret_path" ]]; then
        kubectl apply -f "$registry_secret_path" -n rapidfort
    else
        log_warning "rapidfort-registry-secret.yaml not found, proceeding without it"
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
    
    # Cluster name is just the type
    local cluster_name="$cluster_type"
    
    helm upgrade --install rfruntime oci://quay.io/rapidfort/runtime \
        --namespace rapidfort \
        --set ClusterName="$cluster_name" \
        --set ClusterCaption="$cluster_type Cluster" \
        --set rapidfort.credentialsSecret=rfruntime-credentials \
        --set variant="$variant" \
        --set scan.enabled=true \
        --set profile.enabled=false \
        --wait --timeout=5m
    
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
    wait_for_pods_ready 600
    
    log_success "Coverage test completed"
    return 0
}

# Function to test a single cluster type
test_cluster() {
    local cluster_type="$1"
    local skip_runtime="$2"
    local skip_coverage="$3"
    local keep_cluster="$4"
    
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
        if ! deploy_rapidfort_runtime "$cluster_type"; then
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
        
        if test_cluster "$cluster_type" "$skip_runtime" "$skip_coverage" "$keep_cluster"; then
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
        test-all)
            shift
            # Parse options for test-all
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --skip-runtime) skip_runtime="true"; shift ;;
                    --skip-coverage) skip_coverage="true"; shift ;;
                    --keep-cluster) keep_cluster="true"; shift ;;
                    --timeout) timeout="$2"; shift 2 ;;
                    *) log_error "Unknown option: $1"; exit 1 ;;
                esac
            done
            
            check_registry_ip
            test_all_clusters "$skip_runtime" "$skip_coverage" "$keep_cluster"
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
            *) extra_args+=("$1"); shift ;;
        esac
    done
    
    # Execute command
    case "$command" in
        install|uninstall|status)
            check_registry_ip
            check_cluster_folder "$cluster_type" || exit 1
            export CURRENT_CLUSTER_TYPE="$cluster_type"
            run_cluster_command "$cluster_type" "$command" "${extra_args[@]}"
            ;;
        test)
            check_registry_ip
            export CURRENT_CLUSTER_TYPE="$cluster_type"
            test_cluster "$cluster_type" "$skip_runtime" "$skip_coverage" "$keep_cluster"
            ;;
        help|--help|-h)
            # Show cluster-specific help
            check_cluster_folder "$cluster_type" || exit 1
            run_cluster_command "$cluster_type" "help"
            ;;
        *)
            log_error "Unknown command: $command"
            log_info "Valid commands: install, uninstall, status, test, help"
            exit 1
            ;;
    esac
}

# Check if running with sudo when needed
check_sudo() {
    if [[ $EUID -ne 0 ]] && [[ "$1" != "help" ]] && [[ "$1" != "list" ]] && [[ "$1" != "--help" ]] && [[ "$1" != "-h" ]]; then
        log_warning "Most operations require root privileges"
        log_info "Consider running with: sudo $0 $@"
    fi
}

# Run checks and main
check_sudo "$@"
main "$@"