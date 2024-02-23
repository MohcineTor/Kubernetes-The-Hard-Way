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

# Function to bootstrap the Kubernetes control plane on a given instance
bootstrap_kubernetes() {
  instance=$1
run_remote "$instance" "cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF"

 run_remote "$instance" "cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF"
}

# Run the script for one controller instance
for instance in controller-0; do
  bootstrap_kubernetes "$instance"
done
echo 
echo "-------------$cl_yellow Verification of cluster public endpoint$cl_df----------------"
# Verification
KUBERNETES_PUBLIC_ADDRESS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${LOAD_BALANCER_ARN} \
  --output text --query 'LoadBalancers[].DNSName')
curl --cacert ca.pem https://${KUBERNETES_PUBLIC_ADDRESS}/version
