#!/usr/bin/sh

# Variables de couleur pour l'affichage
cl_red="\033[1;31m"
cl_green="\033[1;32m"
cl_blue="\033[1;34m"
cl_yellow="\033[1;33m"
cl_grey="\033[1;37m"
cl_df="\033[0;m"

install_package() {
    # Run the provided commands
    "$@"
    # Check the exit status of the last command
    if [ $? -eq 0 ]; then
        echo "$cl_green [+] Installation successful$cl_df of $cl_yellow$cl_cyan $1 $cl_d"
    else
        echo "$cl_red [-] Installation failed$cl_df of $cl_yellow$cl_cyan $1 $cl_d"
    fi
}
echo 
echo "-------------$cl_blue Bootstrapping the etcd Cluster$cl_df---------------"
echo "-------------$cl_yellow Bootstrapping an etcd Cluster Member$cl_df----------------"
# Function to run commands on a remote server via SSH
run_remote() {
  instance=$1
  external_ip=$(aws ec2 describe-instances --filters \
    "Name=tag:Name,Values=${instance}" \
    "Name=instance-state-name,Values=running" \
    --output text --query 'Reservations[].Instances[].PublicIpAddress')
  echo "Executing commands on ${instance}..."
  ssh -i kubernetes.id_rsa "ubuntu@$external_ip" "$2"
}

# Function to bootstrap an etcd cluster member on a given instance
bootstrap_etcd() {
  instance=$1
  # Download and Install etcd binaries
  run_remote "$instance" "wget -q --show-progress --https-only --timestamping \
    'https://github.com/etcd-io/etcd/releases/download/v3.4.15/etcd-v3.4.15-linux-amd64.tar.gz'"

  run_remote "$instance" "tar -xvf etcd-v3.4.15-linux-amd64.tar.gz"
  run_remote "$instance" "sudo mv etcd-v3.4.15-linux-amd64/etcd* /usr/local/bin/"

  # Configure etcd
  run_remote "$instance" "sudo mkdir -p /etc/etcd /var/lib/etcd"
  run_remote "$instance" "sudo chmod 700 /var/lib/etcd"
  run_remote "$instance" "sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/"

  INTERNAL_IP=$(run_remote "$instance" "curl -s http://169.254.169.254/latest/meta-data/local-ipv4")
  ETCD_NAME=$(run_remote "$instance" "curl -s http://169.254.169.254/latest/user-data/ | tr '|' '\n' | grep '^name' | cut -d'=' -f2")

  run_remote "$instance" "cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster controller-0=https://10.0.1.10:2380,controller-1=https://10.0.1.11:2380,controller-2=https://10.0.1.12:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

  # Start etcd
  run_remote "$instance" "sudo systemctl daemon-reload"
  run_remote "$instance" "sudo systemctl enable etcd"
  run_remote "$instance" "sudo systemctl start etcd"
}

# Verification
verify_etcd() {
  instance=$1
  run_remote "$instance" "sudo ETCDCTL_API=3 etcdctl member list \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/ca.pem \
    --cert=/etc/etcd/kubernetes.pem \
    --key=/etc/etcd/kubernetes-key.pem"
}

# Loop through each controller instance
for instance in controller-0 controller-1 controller-2; do
  bootstrap_etcd "$instance"
  verify_etcd "$instance"
done
echo 
echo "-------------$cl_blue Bootstrapping the Kubernetes Control Plane$cl_df---------------"
echo "-------------$cl_yellow Provision the Kubernetes Control Plane$cl_df----------------"
# Function to bootstrap the Kubernetes control plane on a given instance
bootstrap_kubernetes() {
  instance=$1

  # Create Kubernetes configuration directory
  run_remote "$instance" "sudo mkdir -p /etc/kubernetes/config"

  # Download and install Kubernetes Controller Binaries
  run_remote "$instance" "wget -q --show-progress --https-only --timestamping \
    \"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-apiserver\" \
    \"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-controller-manager\" \
    \"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kube-scheduler\" \
    \"https://storage.googleapis.com/kubernetes-release/release/v1.21.0/bin/linux/amd64/kubectl\""

  run_remote "$instance" "chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl"
  run_remote "$instance" "sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/"

  # Configure Kubernetes API Server
  run_remote "$instance" "sudo mkdir -p /var/lib/kubernetes/"
  run_remote "$instance" "sudo mv ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
    service-account-key.pem service-account.pem \
    encryption-config.yaml /var/lib/kubernetes/"

  INTERNAL_IP=$(run_remote "$instance" "curl -s http://169.254.169.254/latest/meta-data/local-ipv4")

  # Create kube-apiserver.service systemd unit file
  run_remote "$instance" "cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://10.0.1.10:2379,https://10.0.1.11:2379,https://10.0.1.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://${KUBERNETES_PUBLIC_ADDRESS}:443 \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

  # Configure Kubernetes Controller Manager
  run_remote "$instance" "sudo mv kube-controller-manager.kubeconfig /var/lib/kubernetes/"

  # Create kube-controller-manager.service systemd unit file
  run_remote "$instance" "cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

  # Configure Kubernetes Scheduler
  run_remote "$instance" "sudo mv kube-scheduler.kubeconfig /var/lib/kubernetes/"

  # Create kube-scheduler.yaml configuration file
  run_remote "$instance" "cat <<EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1beta1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: \"/var/lib/kubernetes/kube-scheduler.kubeconfig\"
leaderElection:
  leaderElect: true
EOF"

  # Create kube-scheduler.service systemd unit file
  run_remote "$instance" "cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

  # Start the Controller Services
  run_remote "$instance" "sudo systemctl daemon-reload"
  run_remote "$instance" "sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler"
  run_remote "$instance" "sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler"
  # Add Host File Entries
  run_remote "$instance" "cat <<EOF | sudo tee -a /etc/hosts
10.0.1.20 ip-10-0-1-20
10.0.1.21 ip-10-0-1-21
10.0.1.22 ip-10-0-1-22
EOF"
}

# Run the script for each controller instance
for instance in controller-0 controller-1 controller-2; do
  bootstrap_kubernetes "$instance"
done

# Verification
echo "Allow up to 10 seconds for the Kubernetes API Server to fully initialize."
run_remote "controller-0" "kubectl cluster-info --kubeconfig admin.kubeconfig"
