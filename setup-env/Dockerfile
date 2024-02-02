# Container Image
FROM ghcr.io/viaanix/self-hosted-runner:dev

COPY setup-env.sh /setup-env.sh

RUN chmod +x /setup-env.sh

# Code File to Execute When the Docker Container Starts Up
ENTRYPOINT ["/setup-env.sh"]