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

function find_next_vmid() {
  local id=100
  while qm status "$id" &>/dev/null; do
    ((id++))
  done
  echo "$id"
}

function ensure_template_exists() {
  if qm status $TEMPLATE_ID &>/dev/null; then
    echo "[✓] Template $TEMPLATE_ID déjà présent."
    return
  fi

  echo "[+] Création du template cloud-init Ubuntu 22.04 (ID: $TEMPLATE_ID)..."

  wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O ubuntu-22.04.img

  qm create $TEMPLATE_ID --name ubuntu-2204-template --memory 2048 --cores 2 --net0 virtio,bridge=$BRIDGE --ostype l26 --agent 1
  qm importdisk $TEMPLATE_ID ubuntu-22.04.img $STORAGE
  qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0
  qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit
  qm set $TEMPLATE_ID --boot c --bootdisk scsi0
  qm set $TEMPLATE_ID --serial0 socket --vga serial0
  qm template $TEMPLATE_ID

  rm -f ubuntu-22.04.img
}

function create_vm() {
  local id=$1
  local name=$2

  echo "[+] Création de la VM $name (ID: $id)..."

  qm clone $TEMPLATE_ID $id --name $name --full true --storage $STORAGE

  qm stop $id 2>/dev/null || true
  sleep 2

  qm set $id \
    --memory $VM_RAM \
    --cores $VM_CPUS \
    --net0 virtio,bridge=$BRIDGE \
    --ciuser ubuntu \
    --sshkeys "$SSH_KEY_PATH" \
    --ipconfig0 ip=dhcp

  qm resize $id scsi0 +${VM_DISK}G || true

  qm start $id
}

function get_vm_ip() {
  local vmid=$1
  local ip=""

  echo "[...] Attente de l'IP pour VM $vmid..."

  for i in {1..30}; do
    ip=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | jq -r '.[]."ip-addresses"[]."ip-address"' | grep -E '^192\.|^10\.|^172\.' || true)
    if [[ -n "$ip" ]]; then
      echo "[✓] IP détectée pour VM $vmid : $ip"
      echo "$ip"
      return
    fi
    sleep 5
  done

  echo "[x] IP non trouvée pour VM $vmid"
  exit 1
}

function install_k3s_master() {
  local ip=$1
  echo "[+] Installation de k3s (master) sur $ip"
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "curl -sfL https://get.k3s.io | sh -"
  K3S_TOKEN=$(ssh ubuntu@$ip "sudo cat /var/lib/rancher/k3s/server/node-token")
  K3S_MASTER_IP="$ip"
}

function install_k3s_worker() {
  local ip=$1
  echo "[+] Installation de k3s (worker) sur $ip"
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -"
}

function deploy_minio() {
  echo "[+] Déploiement de MinIO dans Kubernetes..."

  ssh ubuntu@$K3S_MASTER_IP <<'EOF'
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: minio
---
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
        args: ["server", "/data"]
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
    - name: api
      port: 9000
      targetPort: 9000
      nodePort: 30090
    - name: console
      port: 9001
      targetPort: 9001
      nodePort: 30091
YAML
EOF
}

### MAIN ###
if ! command -v jq &>/dev/null; then
  echo "[x] La commande 'jq' est requise sur l'hôte Proxmox. Installez-la avec : apt install -y jq"
  exit 1
fi

echo "=== Déploiement K3s + MinIO sur Proxmox ==="

ensure_template_exists

# Créer master
MASTER_ID=$(find_next_vmid)
MASTER_NAME="k3s-master"
create_vm "$MASTER_ID" "$MASTER_NAME"
MASTER_IP=$(get_vm_ip "$MASTER_ID")

# Créer workers
WORKER_IPS=()
WORKER_IDS=()
for i in $(seq 1 $WORKER_COUNT); do
  VMID=$(find_next_vmid)
  WORKER_IDS+=("$VMID")
  create_vm "$VMID" "k3s-worker-$i"
done

# Attendre les IPs
for vmid in "${WORKER_IDS[@]}"; do
  ip=$(get_vm_ip "$vmid")
  WORKER_IPS+=("$ip")
done

# Installer K3s
install_k3s_master "$MASTER_IP"
for ip in "${WORKER_IPS[@]}"; do
  install_k3s_worker "$ip"
done

# Déployer MinIO
deploy_minio

# Fin
echo ""
echo "[✓] Cluster K3s + MinIO déployé avec succès !"
echo "Accès MinIO :"
echo "  Console : http://$MASTER_IP:30091"
echo "  API     : http://$MASTER_IP:30090"
echo "  Login   : minioadmin / minioadmin"
