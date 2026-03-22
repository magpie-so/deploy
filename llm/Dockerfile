# Dockerfile for vLLM inference server
# Requires NVIDIA GPU with CUDA support

FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/models/.cache \
    CUDA_VISIBLE_DEVICES=0

WORKDIR /app

# Install Python and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 \
    python3-pip \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN pip3 install --no-cache-dir --upgrade pip

# Install vLLM with CUDA support
# Pin version for stability
RUN pip3 install --no-cache-dir \
    vllm==0.6.4.post1 \
    torch==2.4.0

# Model selection via build arg
# Local dev: qwen2.5-1.5b-instruct (default, runs on CPU/Apple Silicon)
# Production L4: Qwen2.5-7B-Instruct (FP16, ~15GB VRAM)
ARG VLLM_MODEL=qwen3-1.7b
ENV VLLM_MODEL=${VLLM_MODEL}

# Pre-download model weights (optional, reduces startup time)
# Uncomment if you want to bake model into image
# RUN python3 -c "from huggingface_hub import snapshot_download; \
#     snapshot_download('${VLLM_MODEL}', cache_dir='/models/.cache')"

# Create cache directory
RUN mkdir -p /models/.cache && chmod 777 /models/.cache

# Expose vLLM port (internal only)
EXPOSE 1234

# Health check - vLLM takes time to start
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:1234/v1/models || exit 1

# Start vLLM server
# Uses VLLM_MODEL env var set from build arg
# Override gpu-memory-utilization and max-model-len via docker-compose environment
CMD vllm serve ${VLLM_MODEL} \
    --host 0.0.0.0 \
    --port 1234 \
    --trust-remote-code \
    --max-model-len ${VLLM_MAX_MODEL_LEN:-4096} \
    --gpu-memory-utilization ${VLLM_GPU_MEM_UTIL:-0.9} \
    --dtype auto \
    --tensor-parallel-size 1 \
    --enable-prefix-caching \
    --disable-log-requests
