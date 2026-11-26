# The only container with a route to the internet. It forwards SSH to the agent and proxies HTTPS
# CONNECT to the hostnames in `allowlist` (default: pypi) and nothing else.
FROM alpine:3.22
RUN apk add --no-cache tinyproxy socat
COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY allowlist /etc/tinyproxy/allowlist
CMD ["sh", "-c", "socat TCP-LISTEN:2222,fork,reuseaddr TCP:agent:22 & exec tinyproxy -d"]
