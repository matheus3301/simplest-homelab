# Install k3s

# 1. Copy config
sudo mkdir -p /etc/rancher/k3s
sudo cp setup/config.yaml /etc/rancher/k3s/config.yaml

# 2. Enable IPv6 forwarding (required for flannel)
sudo sysctl -w net.ipv6.conf.all.forwarding=1
sudo sysctl -w net.ipv6.conf.default.forwarding=1
echo -e "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.default.forwarding=1" | sudo tee /etc/sysctl.d/99-ipv6-forward.conf

# 3. Install k3s
curl -sfL https://get.k3s.io | sh -

# 4. Setup kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
