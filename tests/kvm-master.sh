#!/bin/bash

# KVM Master Management Script
# For Debian/Ubuntu headless systems
# Supports Ubuntu 20.04, 22.04, and 24.04 VM creation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VM_DIR="/var/lib/libvirt/images"
CLOUD_IMG_DIR="/var/lib/libvirt/cloud-images"
DEFAULT_MEMORY=4096  # MB
DEFAULT_VCPUS=2
DEFAULT_DISK_SIZE=20 # GB
DEFAULT_NETWORK="default"

# Cloud image URLs
declare -A CLOUD_IMAGES=(
    ["ubuntu20"]="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
    ["ubuntu22"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ["ubuntu24"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

# Function to print colored output
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_msg $RED "This script must be run as root"
        exit 1
    fi
}

# Detect distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_msg $RED "Cannot detect OS"
        exit 1
    fi
}

# Install KVM and dependencies
install_kvm() {
    print_msg $BLUE "Installing KVM and dependencies..."
    
    detect_distro
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        apt-get update
        apt-get install -y \
            qemu-kvm \
            libvirt-daemon-system \
            libvirt-clients \
            bridge-utils \
            virtinst \
            cloud-image-utils \
            cpu-checker \
            libguestfs-tools \
            libosinfo-bin \
            wget \
            whois
    else
        print_msg $RED "Unsupported distribution: $OS"
        exit 1
    fi
    
    # Enable and start libvirtd
    systemctl enable libvirtd
    systemctl start libvirtd
    
    # Create directories
    mkdir -p "$VM_DIR" "$CLOUD_IMG_DIR"
    
    print_msg $GREEN "KVM installation completed!"
}

# Check KVM capabilities
check_kvm() {
    print_msg $BLUE "Checking KVM capabilities..."
    
    if ! kvm-ok &>/dev/null; then
        print_msg $RED "KVM acceleration not available. Check BIOS virtualization settings."
        exit 1
    fi
    
    if ! systemctl is-active --quiet libvirtd; then
        print_msg $RED "libvirtd is not running"
        exit 1
    fi
    
    print_msg $GREEN "KVM is ready!"
}

# Setup default network if not exists
setup_network() {
    print_msg $BLUE "Setting up network..."
    
    if ! virsh net-info default &>/dev/null; then
        print_msg $YELLOW "Creating default network..."
        virsh net-define /dev/stdin <<EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
        virsh net-start default
        virsh net-autostart default
    fi
    
    print_msg $GREEN "Network setup completed!"
}

# Download cloud image if not exists
download_cloud_image() {
    local os_type=$1
    local img_url=${CLOUD_IMAGES[$os_type]}
    local img_name=$(basename "$img_url")
    local img_path="$CLOUD_IMG_DIR/$img_name"
    
    if [ ! -f "$img_path" ]; then
        print_msg $BLUE "Downloading $os_type cloud image..."
        wget -q --show-progress -O "$img_path" "$img_url"
        print_msg $GREEN "Download completed!"
    else
        print_msg $YELLOW "Cloud image already exists: $img_path"
    fi
    
    echo "$img_path"
}

# Generate cloud-init configuration
generate_cloud_init() {
    local vm_name=$1
    local password=$2
    local ssh_key=$3
    local cloud_init_dir="/tmp/cloud-init-${vm_name}"
    
    mkdir -p "$cloud_init_dir"
    
    # Create meta-data
    cat > "$cloud_init_dir/meta-data" <<EOF
instance-id: $vm_name
local-hostname: $vm_name
EOF
    
    # Create user-data
    cat > "$cloud_init_dir/user-data" <<EOF
#cloud-config
hostname: $vm_name
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    shell: /bin/bash
    lock_passwd: false
EOF
    
    if [ -n "$password" ]; then
        echo "    passwd: $(echo $password | mkpasswd -m sha-512 -s)" >> "$cloud_init_dir/user-data"
    fi
    
    if [ -n "$ssh_key" ]; then
        echo "    ssh_authorized_keys:" >> "$cloud_init_dir/user-data"
        echo "      - $ssh_key" >> "$cloud_init_dir/user-data"
    fi
    
    # Add package updates
    cat >> "$cloud_init_dir/user-data" <<EOF
package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - net-tools
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF
    
    # Create cloud-init ISO
    local iso_path="$VM_DIR/${vm_name}-cloud-init.iso"
    cloud-localds "$iso_path" "$cloud_init_dir/user-data" "$cloud_init_dir/meta-data"
    
    rm -rf "$cloud_init_dir"
    echo "$iso_path"
}

# Create VM
create_vm() {
    local vm_name=$1
    local os_type=$2
    local memory=${3:-$DEFAULT_MEMORY}
    local vcpus=${4:-$DEFAULT_VCPUS}
    local disk_size=${5:-$DEFAULT_DISK_SIZE}
    local password=${6:-"ubuntu"}
    local ssh_key=${7:-""}
    
    print_msg $BLUE "Creating VM: $vm_name"
    
    # Check if VM already exists
    if virsh dominfo "$vm_name" &>/dev/null; then
        print_msg $RED "VM $vm_name already exists!"
        return 1
    fi
    
    # Download cloud image
    local base_img=$(download_cloud_image "$os_type")
    
    # Create VM disk from cloud image
    local vm_disk="$VM_DIR/${vm_name}.qcow2"
    print_msg $BLUE "Creating VM disk..."
    qemu-img create -f qcow2 -F qcow2 -b "$base_img" "$vm_disk" "${disk_size}G"
    
    # Generate cloud-init ISO
    local cloud_init_iso=$(generate_cloud_init "$vm_name" "$password" "$ssh_key")
    
    # Get OS variant
    local os_variant=""
    case $os_type in
        ubuntu20) os_variant="ubuntu20.04" ;;
        ubuntu22) os_variant="ubuntu22.04" ;;
        ubuntu24) os_variant="ubuntu24.04" ;;
    esac
    
    # Create VM
    print_msg $BLUE "Creating VM with virt-install..."
    virt-install \
        --name "$vm_name" \
        --memory "$memory" \
        --vcpus "$vcpus" \
        --disk "$vm_disk",device=disk,bus=virtio \
        --disk "$cloud_init_iso",device=cdrom \
        --os-variant "$os_variant" \
        --network network="$DEFAULT_NETWORK",model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --quiet
    
    # Wait for VM to start
    sleep 5
    
    # Get VM IP
    print_msg $BLUE "Waiting for VM to get IP address..."
    local ip=""
    for i in {1..30}; do
        ip=$(virsh domifaddr "$vm_name" | grep -oP '192\.168\.\d+\.\d+' | head -1)
        if [ -n "$ip" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -n "$ip" ]; then
        print_msg $GREEN "VM created successfully!"
        print_msg $GREEN "VM Name: $vm_name"
        print_msg $GREEN "IP Address: $ip"
        print_msg $GREEN "Username: ubuntu"
        print_msg $GREEN "Password: $password"
        print_msg $GREEN "Connect: ssh ubuntu@$ip"
    else
        print_msg $YELLOW "VM created but IP not detected yet. Use 'virsh domifaddr $vm_name' to check later."
    fi
}

# List VMs
list_vms() {
    print_msg $BLUE "Active VMs:"
    virsh list --all
}

# Delete VM
delete_vm() {
    local vm_name=$1
    
    print_msg $YELLOW "Deleting VM: $vm_name"
    
    # Stop VM if running
    if virsh domstate "$vm_name" 2>/dev/null | grep -q "running"; then
        virsh destroy "$vm_name"
    fi
    
    # Undefine VM
    virsh undefine "$vm_name" --remove-all-storage
    
    # Remove cloud-init ISO
    rm -f "$VM_DIR/${vm_name}-cloud-init.iso"
    
    print_msg $GREEN "VM $vm_name deleted!"
}

# VM control functions
start_vm() {
    virsh start "$1"
    print_msg $GREEN "VM $1 started"
}

stop_vm() {
    virsh shutdown "$1"
    print_msg $GREEN "VM $1 shutdown initiated"
}

force_stop_vm() {
    virsh destroy "$1"
    print_msg $GREEN "VM $1 forcefully stopped"
}

restart_vm() {
    virsh reboot "$1"
    print_msg $GREEN "VM $1 restarted"
}

# Connect to VM console
connect_vm() {
    print_msg $BLUE "Connecting to $1 console (Ctrl+] to exit)..."
    virsh console "$1"
}

# Show VM info
vm_info() {
    local vm_name=$1
    print_msg $BLUE "VM Information: $vm_name"
    virsh dominfo "$vm_name"
    echo
    print_msg $BLUE "Network interfaces:"
    virsh domifaddr "$vm_name"
}

# Main menu
show_menu() {
    echo
    print_msg $BLUE "=== KVM VM Management ==="
    echo "1) Install KVM (first time setup)"
    echo "2) Create Ubuntu 20.04 VM"
    echo "3) Create Ubuntu 22.04 VM"
    echo "4) Create Ubuntu 24.04 VM"
    echo "5) List VMs"
    echo "6) Start VM"
    echo "7) Stop VM"
    echo "8) Force stop VM"
    echo "9) Restart VM"
    echo "10) Connect to VM console"
    echo "11) Show VM info"
    echo "12) Delete VM"
    echo "13) Exit"
    echo
}

# Interactive mode
interactive_mode() {
    while true; do
        show_menu
        read -p "Select option: " choice
        
        case $choice in
            1)
                install_kvm
                setup_network
                ;;
            2|3|4)
                read -p "VM name: " vm_name
                read -p "Memory (MB) [$DEFAULT_MEMORY]: " memory
                memory=${memory:-$DEFAULT_MEMORY}
                read -p "vCPUs [$DEFAULT_VCPUS]: " vcpus
                vcpus=${vcpus:-$DEFAULT_VCPUS}
                read -p "Disk size (GB) [$DEFAULT_DISK_SIZE]: " disk_size
                disk_size=${disk_size:-$DEFAULT_DISK_SIZE}
                read -p "Password [ubuntu]: " password
                password=${password:-ubuntu}
                read -p "SSH public key (optional): " ssh_key
                
                case $choice in
                    2) os_type="ubuntu20" ;;
                    3) os_type="ubuntu22" ;;
                    4) os_type="ubuntu24" ;;
                esac
                
                create_vm "$vm_name" "$os_type" "$memory" "$vcpus" "$disk_size" "$password" "$ssh_key"
                ;;
            5)
                list_vms
                ;;
            6)
                read -p "VM name: " vm_name
                start_vm "$vm_name"
                ;;
            7)
                read -p "VM name: " vm_name
                stop_vm "$vm_name"
                ;;
            8)
                read -p "VM name: " vm_name
                force_stop_vm "$vm_name"
                ;;
            9)
                read -p "VM name: " vm_name
                restart_vm "$vm_name"
                ;;
            10)
                read -p "VM name: " vm_name
                connect_vm "$vm_name"
                ;;
            11)
                read -p "VM name: " vm_name
                vm_info "$vm_name"
                ;;
            12)
                read -p "VM name: " vm_name
                read -p "Are you sure? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    delete_vm "$vm_name"
                fi
                ;;
            13)
                print_msg $GREEN "Goodbye!"
                exit 0
                ;;
            *)
                print_msg $RED "Invalid option"
                ;;
        esac
    done
}

# CLI mode
cli_mode() {
    case "$1" in
        init)
            install_kvm
            setup_network
            ;;
        create)
            shift
            if [ $# -lt 2 ]; then
                print_msg $RED "Usage: $0 create <vm_name> <ubuntu20|ubuntu22|ubuntu24> [memory_mb] [vcpus] [disk_gb] [password] [ssh_key]"
                exit 1
            fi
            create_vm "$@"
            ;;
        list)
            list_vms
            ;;
        start)
            start_vm "$2"
            ;;
        stop)
            stop_vm "$2"
            ;;
        force-stop)
            force_stop_vm "$2"
            ;;
        restart)
            restart_vm "$2"
            ;;
        console)
            connect_vm "$2"
            ;;
        info)
            vm_info "$2"
            ;;
        delete)
            delete_vm "$2"
            ;;
        *)
            cat <<EOF
Usage: $0 <command> [options]

Commands:
    init                    Install KVM and setup environment
    create <name> <os>      Create new VM (os: ubuntu20|ubuntu22|ubuntu24)
    list                    List all VMs
    start <name>            Start VM
    stop <name>             Gracefully stop VM
    force-stop <name>       Force stop VM
    restart <name>          Restart VM
    console <name>          Connect to VM console
    info <name>             Show VM information
    delete <name>           Delete VM

Interactive mode:
    $0                      Run without arguments for menu

Examples:
    $0 init
    $0 create myvm ubuntu24 8192 4 50 mypassword
    $0 create webserver ubuntu22
    $0 start myvm
    $0 console myvm
EOF
            exit 1
            ;;
    esac
}

# Main
main() {
    check_root
    
    # Check if KVM is installed (skip for init command)
    if [ $# -eq 0 ] || ([ $# -gt 0 ] && [ "$1" != "init" ]); then
        if ! command -v virsh &>/dev/null; then
            print_msg $RED "KVM is not installed. Run: $0 init"
            exit 1
        fi
        check_kvm
    fi
    
    if [ $# -eq 0 ]; then
        interactive_mode
    else
        cli_mode "$@"
    fi
}

main "$@"