#!/bin/bash

# CONFIGURATION GÉNÉRALE
VM_IMAGE_ID=9000              # ID du template cloud-init Ubuntu
STORAGE="local-lvm"           # Nom du stockage Proxmox
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
BRIDGE="vmbr0"
CPUS=2
RAM_MB=4096
DISK_GB=20

MASTER_ID=100
WORKER_BASE_ID=110
WORKER_COUNT=2

K3S_TOKEN=""
K3S_MASTER_IP=""

function create_vm() {
  local vmid=$1
  local hostname=$2

  echo "[+] Création VM $hostname (ID: $vmid)"

  qm clone $VM_IMAGE_ID $vmid --name $hostname --full true --storage $STORAGE
  qm set $vmid --memory $RAM_MB --cores $CPUS --net0 virtio,bridge=$BRIDGE
  qm resize $vmid scsi0 ${DISK_GB}G
  qm set $vmid --ciuser ubuntu --sshkey $SSH_KEY_PATH
  qm set $vmid --ipconfig0 ip=dhcp
  qm start $vmid
}

function get_ip() {
  local vmid=$1
  local ip=""

  echo "[...] Attente de l'IP de la VM $vmid..."
  for i in {1..30}; do
    ip=$(qm guest cmd $vmid network-get-interfaces | jq -r '.[0]."ip-addresses"[0]."ip-address"' | grep -E '^192\.168|10\.|172\.')
    if [[ -n "$ip" ]]; then
      echo "[✓] IP trouvée: $ip"
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
  echo "[+] Installation de k3s sur le master ($ip)..."
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "curl -sfL https://get.k3s.io | sh -"
  K3S_TOKEN=$(ssh ubuntu@$ip "sudo cat /var/lib/rancher/k3s/server/node-token")
  K3S_MASTER_IP=$ip
}

function install_k3s_worker() {
  local ip=$1
  echo "[+] Installation de k3s sur worker ($ip)..."
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -"
}

function deploy_minio() {
  echo "[+] Déploiement de MinIO dans Kubernetes..."

  cat <<EOF | ssh ubuntu@$K3S_MASTER_IP "cat > /tmp/minio.yaml"
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
        - name: data
          mountPath: /data
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
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
  type: NodePort
EOF

  ssh ubuntu@$K3S_MASTER_IP "kubectl apply -f /tmp/minio.yaml"
}

### MAIN SCRIPT ###

create_vm $MASTER_ID "k3s-master"
MASTER_IP=$(get_ip $MASTER_ID)

for i in $(seq 1 $WORKER_COUNT); do
  VMID=$(($WORKER_BASE_ID + $i))
  create_vm $VMID "k3s-worker-$i"
done

sleep 30

install_k3s_master "$MASTER_IP"

for i in $(seq 1 $WORKER_COUNT); do
  VMID=$(($WORKER_BASE_ID + $i))
  WORKER_IP=$(get_ip $VMID)
  install_k3s_worker "$WORKER_IP"
done

deploy_minio

echo "[✓] Cluster K3s + MinIO prêt."
echo "Accès MinIO: http://$K3S_MASTER_IP:<NodePort>"
