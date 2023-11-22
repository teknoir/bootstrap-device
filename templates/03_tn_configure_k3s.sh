info "Configure Rancher K3s"

if [ "${USE_GPU_ACCEL}" = true ]; then
    info "Use nvidia container runtime in containerd"
    config_file="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"

    # Check if the file already exists
    if [ -e "$config_file" ]; then
        echo "File already exists at $config_file. Exiting."
        exit 1
    fi

    # Create the file with the specified contents
    cat <<EOL > "$config_file"
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

    nvidia_runtimeclass_file="/etc/teknoir/nvidia-runtimeclass.yaml"

    # Check if the file already exists
    if [ -e "$nvidia_runtimeclass_file" ]; then
        echo "File already exists at $nvidia_runtimeclass_file. Exiting."
        exit 1
    fi

    # Create Kubernetes runtime class yaml with the specified contents
    cat <<EOL > "$nvidia_runtimeclass_file"
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
name: nvidia
handler: nvidia
EOL

    info "Runtime class file created at $nvidia_runtimeclass_file."

    # Apply runtimeclass manifest
    kubectl apply -f "$nvidia_runtimeclass_file"
fi