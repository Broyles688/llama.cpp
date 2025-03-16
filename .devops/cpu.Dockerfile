ARG UBUNTU_VERSION=22.04

# Build stage
FROM ubuntu:$UBUNTU_VERSION AS build

ARG TARGETARCH
ARG GGML_CPU_ARM_ARCH=armv8-a

RUN apt-get update && \
    apt-get install -y build-essential git cmake libcurl4-openssl-dev

WORKDIR /app

COPY . .

RUN if [ "$TARGETARCH" = "amd64" ]; then \
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=${GGML_CPU_ARM_ARCH}; \
    else \
        echo "Unsupported architecture"; \
        exit 1; \
    fi && \
    cmake --build build -j $(nproc)

RUN mkdir -p /app/lib && \
    find build -name "*.so" -exec cp {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

# Base image (with numactl added)
FROM ubuntu:$UBUNTU_VERSION AS base

RUN apt-get update \
    && apt-get install -y libgomp1 curl numactl \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app

# Full stage (optional, for reference)
FROM base AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3 \
    python3-pip \
    && pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

# Light stage (optional, for reference)
FROM base AS light

COPY --from=build /app/full/llama-cli /app

WORKDIR /app

ENTRYPOINT ["/app/llama-cli"]

# Server stage (now the default final stage)
FROM base

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app

WORKDIR /app

HEALTHCHECK CMD ["curl", "-f", "http://localhost:8080/health"]

ENTRYPOINT ["/app/llama-server"]
