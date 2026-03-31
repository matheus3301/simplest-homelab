# UDP buffer sizes for QUIC (cloudflare tunnels, etc)
# Cilium VXLAN reduces pod MTU to ~1280, which breaks QUIC handshakes
# For now we use --protocol http2 as workaround, but if you want QUIC:

sudo sysctl -w net.core.rmem_max=7340032
sudo sysctl -w net.core.wmem_max=7340032

# To persist across reboots:

echo -e "net.core.rmem_max=7340032\nnet.core.wmem_max=7340032" | sudo tee /etc/sysctl.d/99-udp-buffers.conf
