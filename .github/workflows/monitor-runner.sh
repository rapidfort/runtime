#!/bin/bash
# monitor-runners.sh - Script to monitor Linode VMs and K8s clusters

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REPO_OWNER="rapidfort"
REPO_NAME="runtime"

# Check if required tools are installed
check_requirements() {
    echo "Checking requirements..."

    for cmd in linode-cli jq curl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}Error: $cmd is not installed${NC}"
            exit 1
        fi
    done

    if [ -z "$LINODE_TOKEN" ]; then
        echo -e "${RED}Error: LINODE_TOKEN environment variable not set${NC}"
        exit 1
    fi

    if [ -z "$GITHUB_PAT" ]; then
        echo -e "${RED}Error: GITHUB_PAT environment variable not set${NC}"
        exit 1
    fi

    echo -e "${GREEN}All requirements met${NC}"
}

# Get VM status from Linode
get_vm_status() {
    echo -e "\n${YELLOW}=== Linode VM Status ===${NC}"

    linode-cli linodes list --tags "github-runner,k8s-test" --json | \
    jq -r '.[] | [.label, .status, .ipv4[0], .specs.vcpus, .specs.memory, .region] | @tsv' | \
    while IFS=$'\t' read -r label status ip vcpus memory region; do
        if [ "$status" == "running" ]; then
            status_color="${GREEN}✓ $status${NC}"
        else
            status_color="${RED}✗ $status${NC}"
        fi

        printf "%-20s %b %-15s %s vCPUs, %sMB RAM, %s\n" \
            "$label" "$status_color" "$ip" "$vcpus" "$memory" "$region"
    done
}

# Get GitHub runner status
get_runner_status() {
    echo -e "\n${YELLOW}=== GitHub Runner Status ===${NC}"

    curl -s \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners" | \
    jq -r '.runners[] | select(.labels[].name | contains("k8s")) |
        [.name, .status, .busy, (.labels | map(.name) | join(","))] | @tsv' | \
    while IFS=$'\t' read -r name status busy labels; do
        if [ "$status" == "online" ]; then
            if [ "$busy" == "true" ]; then
                status_color="${YELLOW}● busy${NC}"
            else
                status_color="${GREEN}● online${NC}"
            fi
        else
            status_color="${RED}● offline${NC}"
        fi

        printf "%-15s %b %s\n" "$name" "$status_color" "$labels"
    done
}

# Check K8s cluster status on each VM
check_k8s_status() {
    echo -e "\n${YELLOW}=== Kubernetes Cluster Status ===${NC}"

    # Get all VM IPs
    vm_data=$(linode-cli linodes list --tags "github-runner,k8s-test" --json | \
        jq -r '.[] | select(.status == "running") | [.label, .ipv4[0]] | @tsv')

    while IFS=$'\t' read -r label ip; do
        distro=${label#runner-}
        echo -e "\n${YELLOW}Checking $distro ($ip)...${NC}"

        # SSH to VM and check K8s status
        ssh_output=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip 2>/dev/null << 'EOF' || echo "SSH_FAILED"
            # Try different kubectl commands based on the distribution
            if command -v kubectl &> /dev/null; then
                echo "KUBECTL_FOUND"
                kubectl get nodes 2>&1 | head -5
            elif command -v k3s &> /dev/null; then
                echo "K3S_FOUND"
                sudo k3s kubectl get nodes 2>&1 | head -5
            elif command -v microk8s &> /dev/null; then
                echo "MICROK8S_FOUND"
                sudo microk8s kubectl get nodes 2>&1 | head -5
            elif command -v k0s &> /dev/null; then
                echo "K0S_FOUND"
                sudo k0s kubectl get nodes 2>&1 | head -5
            else
                echo "NO_K8S_FOUND"
            fi
EOF
        )

        if [[ "$ssh_output" == *"SSH_FAILED"* ]]; then
            echo -e "${RED}  ✗ Unable to connect via SSH${NC}"
        elif [[ "$ssh_output" == *"NO_K8S_FOUND"* ]]; then
            echo -e "${YELLOW}  ⚠ Kubernetes not installed yet${NC}"
        elif [[ "$ssh_output" == *"NotReady"* ]]; then
            echo -e "${YELLOW}  ⚠ Kubernetes installed but not ready${NC}"
            echo "$ssh_output" | grep -v "FOUND" | sed 's/^/    /'
        elif [[ "$ssh_output" == *"Ready"* ]]; then
            echo -e "${GREEN}  ✓ Kubernetes cluster is running${NC}"
            echo "$ssh_output" | grep -v "FOUND" | sed 's/^/    /'
        else
            echo -e "${YELLOW}  ⚠ Unknown status${NC}"
            echo "$ssh_output" | grep -v "FOUND" | sed 's/^/    /'
        fi
    done
}

# Get resource usage
get_resource_usage() {
    echo -e "\n${YELLOW}=== Resource Usage ===${NC}"

    total_vcpus=0
    total_memory=0
    total_cost=0

    linode-cli linodes list --tags "github-runner,k8s-test" --json | \
    jq -r '.[] | [.label, .type, .specs.vcpus, .specs.memory] | @tsv' | \
    while IFS=$'\t' read -r label type vcpus memory; do
        total_vcpus=$((total_vcpus + vcpus))
        total_memory=$((total_memory + memory))

        # Rough cost estimate (actual costs may vary)
        hourly_cost=$(echo "scale=3; $vcpus * 0.009" | bc)
        total_cost=$(echo "scale=3; $total_cost + $hourly_cost" | bc)

        printf "%-20s %s (%s vCPUs, %sMB RAM) ~\$%s/hour\n" \
            "$label" "$type" "$vcpus" "$memory" "$hourly_cost"
    done

    echo -e "\n${YELLOW}Total Resources:${NC}"
    echo "  VMs: $(linode-cli linodes list --tags 'github-runner,k8s-test' --json | jq length)"
    echo "  Total vCPUs: $total_vcpus"
    echo "  Total Memory: ${total_memory}MB"
    echo "  Estimated Cost: ~\$${total_cost}/hour"
}

# Main function
main() {
    clear
    echo -e "${GREEN}=== Linode VM & K8s Cluster Monitor ===${NC}"
    echo "Time: $(date)"

    check_requirements
    get_vm_status
    get_runner_status
    check_k8s_status
    get_resource_usage

    echo -e "\n${GREEN}Monitor check complete!${NC}"
}

# Run main function
main

