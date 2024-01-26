# Container Image
FROM amazon/aws-cli

# Installing the AWS SAM CLI
RUN echo "* Installing the AWS SAM CLI..."; \
    curl -o aws-sam-cli-linux-x86_64.zip -L https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip; \
    unzip aws-sam-cli-linux-x86_64.zip -d sam-installation; \
    sudo ./sam-installation/install; \
    sam --version;

COPY deploy-scripts /deploy-scripts/

RUN chmod +x /deploy-scripts/deploy.sh
RUN chmod +x ./deploy-scripts/create-deploy-role.sh
RUN chmod +x ./deploy-scripts/create-s3-bucket.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/deploy-scripts/deploy.sh", "-rbd"]