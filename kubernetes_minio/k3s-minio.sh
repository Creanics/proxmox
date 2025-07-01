#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

### CONFIGURATION ###
TEMPLATE_ID=9000                 # ID du template Cloud-Init (Ubuntu 22.04)
STORAGE="local-lvm"
BRIDGE="vmbr0"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"

MASTER_ID=100
MASTER_NAME="k3s-master"
WORKER_BASE_ID=110
WORKER_COUNT=2

VM_CPUS=2
VM_RAM=4096        # en MB
VM_DISK=20         # en GB

K3S_MASTER_IP=""
K3S_TOKEN=""

function create_vm() {
  local id=$1
  local name=$2

  echo "[+] Création de la VM $name (ID: $id)..."

  if ! qm status $TEMPLATE_ID &>/dev/null; then
    echo "[x] Le template avec l'ID $TEMPLATE_ID est introuvable."
    exit 1
  fi

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

# 1. Créer master
create_vm "$MASTER_ID" "$MASTER_NAME"
MASTER_IP=$(get_vm_ip "$MASTER_ID")

# 2. Créer workers
WORKER_IPS=()
for i in $(seq 1 $WORKER_COUNT); do
  ID=$((WORKER_BASE_ID + i))
  NAME="k3s-worker-$i"
  create_vm "$ID" "$NAME"
done

# 3. Attendre IPs des workers
for i in $(seq 1 $WORKER_COUNT); do
  ID=$((WORKER_BASE_ID + i))
  IP=$(get_vm_ip "$ID")
  WORKER_IPS+=("$IP")
done

# 4. Installer K3s
install_k3s_master "$MASTER_IP"
for ip in "${WORKER_IPS[@]}"; do
  install_k3s_worker "$ip"
done

# 5. Déployer MinIO
deploy_minio

# 6. Fin
echo ""
echo "[✓] Cluster K3s + MinIO déployé avec succès !"
echo "Accès MinIO :"
echo "  Console : http://$K3S_MASTER_IP:30091"
echo "  API     : http://$K3S_MASTER_IP:30090"
echo "  Login   : minioadmin / minioadmin"
