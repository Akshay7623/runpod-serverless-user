# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.6.3-base-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# =======================================================
# NEW: Globally disable pip and uv caches to save ~2.5GB
# =======================================================
ENV PIP_NO_CACHE_DIR=1
ENV UV_NO_CACHE=1

# Install Python, git and other necessary tools
# NEW: Added --no-install-recommends to block Ubuntu bloatware
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies
RUN uv pip install comfy-cli pip setuptools wheel
RUN uv pip install alembic==1.18.4 SQLAlchemy==2.0.49 comfy_aimdo==0.2.12 comfy-kitchen safetensors

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

RUN download() { mkdir -p "$1" && wget -q --show-progress -O "$1/$2" "$3"; } && \
    \
    # text_encoders
    download /comfyui/models/text_encoders \
      umt5_xxl_fp8_e4m3fn_scaled.safetensors \
      "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" && \
    \
    # vae
    download /comfyui/models/vae \
      wan_2.1_vae.safetensors \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" && \
    \
    # diffusion_models
    download /comfyui/models/diffusion_models \
      wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors" && \
    download /comfyui/models/diffusion_models \
      wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors" && \
    \
    # loras
    download /comfyui/models/loras \
      wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" && \
    download /comfyui/models/loras \
      wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors \
      "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
      

# Change working directory to ComfyUI
# WORKDIR /comfyui

# Support for the network volume
# ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation
ENV PIP_NO_INPUT=1

# Copy helper script
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]