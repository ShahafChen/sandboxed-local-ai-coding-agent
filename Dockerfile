FROM ollama/ollama:0.40.15

# Model = config/models[MODEL_FAMILY, MODEL_PROFILE]; OLLAMA_MODEL overrides with any Ollama tag.
ARG MODEL_FAMILY=qwen
ARG MODEL_PROFILE=8gb
ARG OLLAMA_MODEL=

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server tinyproxy iptables git python3 python3-venv python3-pip zip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The model is baked in at build time: at runtime the firewall blocks the Ollama registry.
COPY config/models /etc/agent-models
RUN MODEL="${OLLAMA_MODEL:-$(awk -v k="$MODEL_FAMILY $MODEL_PROFILE" '$1" "$2==k{print $3}' /etc/agent-models)}" \
    && { [ -n "$MODEL" ] || { echo "no model for MODEL_FAMILY=$MODEL_FAMILY MODEL_PROFILE=$MODEL_PROFILE; see config/models" >&2; exit 1; }; } \
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
