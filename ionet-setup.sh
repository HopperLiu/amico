#!/bin/bash

set -euxo pipefail

# Detect OS and version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
else
    echo "Your Linux distribution is not supported."
    exit 1
fi

# Detect if an Nvidia GPU is present
NVIDIA_PRESENT=$(lspci | grep -i nvidia || true)

# Only proceed with Nvidia-specific steps if an Nvidia device is detected
if [[ -z "$NVIDIA_PRESENT" ]]; then
    echo "No NVIDIA device detected on this system."
else
    # Check if nvidia-smi is available and working
    if command -v nvidia-smi && nvidia-smi | grep CUDA | grep -vi 'n/a' &>/dev/null; then
        # Extract the CUDA version from the output of `nvidia-smi`.
        cuda_version=$(nvidia-smi | grep "CUDA Version" | sed 's/.*CUDA Version: \([0-9]*\.[0-9]*\).*/\1/')

        # Define the minimum required CUDA version.
        min_version="11.8"

        # Compare the CUDA version extracted with the minimum required version.
        # Here, we sort the two versions and use `head` to get the lowest.
        # If the lowest version is not the minimum version, it means the installed version is lower.
        if [ "$(printf '%s\n%s' "$cuda_version" "$min_version" | sort -V | head -n1)" = "$min_version" ]; then
            echo "CUDA version $cuda_version is installed and meets the minimum requirement of $min_version."
        else
            echo "CUDA version $cuda_version is installed but does not meet the minimum requirement of $min_version. Please upgrade CUDA."
            exit 1
        fi
    else
        # Install NVIDIA drivers and CUDA
        sudo dnf install -y epel-release
        sudo dnf config-manager --add-repo=https://developer.download.nvidia.com/compute/cuda/repos/fedora${VERSION}/x86_64/cuda-fedora${VERSION}.repo
        sudo dnf clean expire-cache
        sudo dnf install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
        sudo dnf install -y nvidia-driver nvidia-settings
        sudo dnf install -y cuda
        sudo dnf install -y nvidia-container-toolkit
        sudo systemctl restart docker
    fi
fi

# For testing purposes, this should output NVIDIA's driver version
if [[ ! -z "$NVIDIA_PRESENT" ]]; then
    nvidia-smi
fi

# Check if Docker is installed
if command -v docker &>/dev/null; then
    echo "Docker is already installed."
else
    echo "Docker is not installed. Proceeding with installations..."
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager --add-repo=https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# Check if docker-compose is installed
if command -v docker-compose &>/dev/null; then
    echo "Docker-compose is already installed."
else
    echo "Docker-compose is not installed. Proceeding with installations..."
    sudo dnf install -y docker-compose
fi

# Test / Install nvidia-docker
if [[ ! -z "$NVIDIA_PRESENT" ]]; then
    if sudo docker run --gpus all nvidia/cuda:11.0.3-base-ubuntu18.04 nvidia-smi &>/dev/null; then
        echo "nvidia-docker is enabled and working. Exiting script."
    else
        echo "nvidia-docker does not seem to be enabled. Proceeding with installations..."
        sudo dnf config-manager --add-repo=https://nvidia.github.io/libnvidia-container/fedora${VERSION}/libnvidia-container.repo
        sudo dnf clean expire-cache
        sudo dnf install -y nvidia-docker2
        sudo systemctl restart docker
        sudo docker run --gpus all nvidia/cuda:11.0.3-base-ubuntu18.04 nvidia-smi
    fi
fi

# Add docker group and user to group docker
sudo groupadd docker || true
sudo usermod -aG docker $USER || true

# Workaround for NVIDIA Docker Issue
echo "Applying workaround for NVIDIA Docker issue as per https://github.com/NVIDIA/nvidia-docker/issues/1730"

# Workaround Steps:
# Disable cgroups for Docker containers to prevent the issue.
# Edit the Docker daemon configuration.
sudo python3 <<END
import json, pathlib, sys
def update_key(dct: dict, key: str, value):
    for item in key.split('.')[:-1]:
        dct = dct.setdefault(item, {})
    dct[key.split('.')[-1]] = value

cfg = pathlib.Path('/etc/docker/daemon.json')
try:
    config = json.loads(cfg.read_text(errors='ignore') if cfg.exists() else '{}')
    update_key(config, 'runtimes.nvidia.path', 'nvidia-container-runtime')
    update_key(config, 'runtimes.nvidia.runtimeArgs', [])
    update_key(config, 'exec-opts', ['native.cgroupdriver=cgroupfs'])
    cfg.write_text(json.dumps(config, sort_keys=True, indent=4))
except Exception as e:
    sys.exit('Cannot modify docker config, reason: ' + str(e))
else:
    print('Docker settings modified successfully')
END

# Restart Docker to apply changes.
sudo systemctl restart docker
echo "Workaround applied. Docker has been configured to use 'cgroupfs' as the cgroup driver."

