info "Configure Rancher K3s"

if [ "${USE_GPU_ACCEL}" = true ]; then
    info "Use nvidia container runtime in containerd"
    config_file="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"

    # Check if the file already exists
    if [ -e "$config_file" ]; then
        echo "File already exists at $config_file. Deleting and recreating."
        $SUDO rm -f "$config_file"
    fi

    # Create the file with the specified contents
    $SUDO tee "$config_file" > /dev/null << EOL
version = 2
[plugins]
    [plugins."io.containerd.grpc.v1.cri"]
        [plugins."io.containerd.grpc.v1.cri".containerd]
        default_runtime_name = "nvidia"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
            privileged_without_host_devices = false
            runtime_engine = ""
            runtime_root = ""
            runtime_type = "io.containerd.runc.v2"
            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
                BinaryName = "/usr/bin/nvidia-container-runtime"
EOL

    info "Containerd configuration file created at $config_file."

    nvidia_runtimeclass_dir="/etc/teknoir"

    # Check if the directory already exists
    if [ ! -d "$nvidia_runtimeclass_dir" ]; then
        $SUDO mkdir -p "$nvidia_runtimeclass_dir"
    fi

    nvidia_runtimeclass_file="$nvidia_runtimeclass_dir/nvidia-runtimeclass.yaml"

    # Check if the file already exists
    if [ -e "$nvidia_runtimeclass_file" ]; then
        echo "File already exists at $nvidia_runtimeclass_file. Deleting and recreating."
        $SUDO rm -f "$nvidia_runtimeclass_file"
    fi

    # Create Kubernetes runtime class yaml with the specified contents
    $SUDO tee "$nvidia_runtimeclass_file" > /dev/null << EOL
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOL

    info "Runtime class file created at $nvidia_runtimeclass_file."

    # Apply runtimeclass manifest
    $SUDO kubectl apply -f "$nvidia_runtimeclass_file"
fi
