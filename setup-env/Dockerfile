# Container Image
FROM ghcr.io/viaanix/self-hosted-runner:dev

COPY setup-env.sh /setup-env.sh

RUN chmod +x /setup-env.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/setup-env.sh"]