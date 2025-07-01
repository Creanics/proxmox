#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

### CONFIGURATION ###
TEMPLATE_ID=9000
STORAGE="local-lvm"
BRIDGE="vmbr0"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
VM_CPUS=2
VM_RAM=4096
VM_DISK=20
WORKER_COUNT=2
MASTER_NAME="k3s-master"
WORKER_NAME_PREFIX="k3s-worker"

### LOG FUNCTIONS ###
function log() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

function warn() {
  echo -e "\033[1;33m[WARN]\033[0m $1"
}

function error() {
  echo -e "\033[1;31m[ERROR]\033[0m $1"
  exit 1
}

### FIND NEXT AVAILABLE VMID ###
function find_next_vmid() {
  local id=100
  while qm status "$id" &>/dev/null; do
    ((id++))
  done
  echo "$id"
}

### ENSURE UBUNTU TEMPLATE EXISTS ###
function ensure_template_exists() {
  if qm status $TEMPLATE_ID &>/dev/null; then
    log "Template with ID $TEMPLATE_ID already exists."
    return
  fi

  log "Downloading Ubuntu 22.04 Cloud-Init image..."
  wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O ubuntu-22.04.img || error "Failed to download Ubuntu image."

  log "Creating VM $TEMPLATE_ID for template..."
  qm create $TEMPLATE_ID --memory 2048 --cores 2 --net0 virtio,bridge=$BRIDGE --ostype l26 --agent 1

  log "Importing disk image to storage $STORAGE..."
  qm importdisk $TEMPLATE_ID ubuntu-22.04.img $STORAGE

  log "Configuring VM $TEMPLATE_ID as cloud-init template..."
  qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0
  qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit
  qm set $TEMPLATE_ID --boot c --bootdisk scsi0
  qm set $TEMPLATE_ID --serial0 socket --vga serial0

  log "Converting VM $TEMPLATE_ID to template..."
  qm template $TEMPLATE_ID

  rm -f ubuntu-22.04.img
  log "Template $TEMPLATE_ID created successfully."
}

### CREATE A VM FROM TEMPLATE ###
function create_vm() {
  local vmid=$1
  local name=$2

  log "Cloning VM from template $TEMPLATE_ID to VM $vmid ($name)..."
  qm clone $TEMPLATE_ID $vmid --name $name --full true --storage $STORAGE || error "Failed to clone VM $vmid"

  log "Stopping VM $vmid if running..."
  qm stop $vmid 2>/dev/null || true
  sleep 3

  log "Configuring VM $vmid resources and cloud-init..."
  qm set $vmid \
    --memory $VM_RAM \
    --cores $VM_CPUS \
    --net0 virtio,bridge=$BRIDGE \
    --ciuser ubuntu \
    --sshkeys "$(cat $SSH_KEY_PATH)" \
    --ipconfig0 ip=dhcp

  log "Resizing disk of VM $vmid by +${VM_DISK}G..."
  qm resize $vmid scsi0 +${VM_DISK}G || warn "Resize disk failed for VM $vmid, maybe disk already resized?"

  log "Starting VM $vmid..."
  qm start $vmid

  log "VM $vmid ($name) started."
}

### GET VM IP ###
function get_vm_ip() {
  local vmid=$1
  local ip=""
  log "Waiting for VM $vmid to get IP address via cloud-init..."
  for i in {1..30}; do
    # Using Proxmox guest agent to get IP addresses
    ip=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | jq -r '.[]."ip-addresses"[]."ip-address"' | grep -E '^192\.|^10\.|^172\.' || true)
    if [[ -n "$ip" ]]; then
      log "VM $vmid IP found: $ip"
      echo "$ip"
      return
    fi
    sleep 5
  done
  error "Failed to retrieve IP address for VM $vmid after waiting."
}

### INSTALL K3S MASTER ###
function install_k3s_master() {
  local ip=$1
  log "Installing k3s master on $ip..."
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "curl -sfL https://get.k3s.io | sh -"
  local token=$(ssh ubuntu@$ip "sudo cat /var/lib/rancher/k3s/server/node-token")
  log "k3s master installed with token: $token"
  echo "$token"
}

### INSTALL K3S WORKER ###
function install_k3s_worker() {
  local ip=$1
  local master_ip=$2
  local token=$3
  log "Installing k3s worker on $ip connecting to master $master_ip..."
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "curl -sfL https://get.k3s.io | K3S_URL=https://$master_ip:6443 K3S_TOKEN=$token sh -"
  log "Worker $ip joined cluster."
}

### DEPLOY MINIO ###
function deploy_minio() {
  local master_ip=$1
  log "Deploying MinIO on Kubernetes cluster..."
  ssh ubuntu@$master_ip bash -c "'
kubectl create namespace minio || true
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args:
          - server
          - /data
        env:
          - name: MINIO_ROOT_USER
            value: minioadmin
          - name: MINIO_ROOT_PASSWORD
            value: minioadmin
        ports:
          - containerPort: 9000
          - containerPort: 9001
        volumeMounts:
          - mountPath: /data
            name: data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  type: NodePort
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
      nodePort: 30090
    - port: 9001
      targetPort: 9001
      nodePort: 30091
EOF
'"
  log "MinIO deployed. Access console at http://$master_ip:30091 with minioadmin/minioadmin"
}

### MAIN ###
if ! command -v jq &>/dev/null; then
  error "jq is not installed. Please install with: apt install -y jq"
fi

log "=== Starting K3s cluster and MinIO deployment on Proxmox ==="

ensure_template_exists

MASTER_ID=$(find_next_vmid)
create_vm "$MASTER_ID" "$MASTER_NAME"
MASTER_IP=$(get_vm_ip "$MASTER_ID")

WORKER_IDS=()
for i in $(seq 1 $WORKER_COUNT); do
  VMID=$(find_next_vmid)
  WORKER_IDS+=("$VMID")
  create_vm "$VMID" "${WORKER_NAME_PREFIX}-$i"
done

WORKER_IPS=()
for vmid in "${WORKER_IDS[@]}"; do
  ip=$(get_vm_ip "$vmid")
  WORKER_IPS+=("$ip")
done

TOKEN=$(install_k3s_master "$MASTER_IP")

for ip in "${WORKER_IPS[@]}"; do
  install_k3s_worker "$ip" "$MASTER_IP" "$TOKEN"
done

deploy_minio "$MASTER_IP"

log "=== Deployment completed successfully! ==="
echo "Master IP: $MASTER_IP"
echo "MinIO Console: http://$MASTER_IP:30091"
echo "MinIO API: http://$MASTER_IP:30090"
echo "MinIO Credentials: minioadmin / minioadmin"
