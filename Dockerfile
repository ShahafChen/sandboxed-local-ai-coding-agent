FROM ollama/ollama:0.40.15

# 8gb -> qwen2.5-coder:7b (~4.7GB), 16gb -> qwen2.5-coder:14b (~9GB). OLLAMA_MODEL overrides both.
ARG MODEL_PROFILE=8gb
ARG OLLAMA_MODEL=

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server tinyproxy iptables git python3 python3-venv python3-pip zip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The model is baked in at build time: at runtime the firewall blocks the Ollama registry.
RUN MODEL="${OLLAMA_MODEL:-$([ "$MODEL_PROFILE" = 16gb ] && echo qwen2.5-coder:14b || echo qwen2.5-coder:7b)}" \
    && echo "$MODEL" > /etc/agent-model \
    && (OLLAMA_HOST=127.0.0.1:11434 ollama serve >/dev/null 2>&1 &) \
    && for i in $(seq 30); do ollama list >/dev/null 2>&1 && break; sleep 1; done \
    && OLLAMA_HOST=127.0.0.1:11434 ollama pull "$MODEL"

ENV OLLAMA_HOST=127.0.0.1:11434 \
    OLLAMA_CONTEXT_LENGTH=8192

RUN useradd -m -s /bin/bash dev && usermod -p '*' dev \
    && ssh-keygen -A && mkdir -p /run/sshd

COPY config/sshd.conf /etc/ssh/sshd_config.d/agent.conf
COPY config/tinyproxy.conf /etc/tinyproxy/agent.conf
COPY config/allowlist /etc/tinyproxy/allowlist
COPY config/pip.conf /etc/pip.conf
COPY scripts/firewall.sh scripts/entrypoint.sh scripts/test-firewall.sh /usr/local/bin/
COPY agent/ /opt/agent/
COPY extension/ /opt/agent/extension/
COPY scripts/build-vsix.sh /tmp/build-vsix.sh
RUN ln -s /opt/agent/review.py /usr/local/bin/agent-review \
    && /tmp/build-vsix.sh /opt/agent/extension /opt/agent/local-agent-chat.vsix

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
