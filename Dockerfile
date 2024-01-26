# Container Image
FROM amazon/aws-cli

COPY deploy-scripts /deploy-scripts/

RUN chmod +x /deploy-scripts/deploy.sh
RUN chmod +x /deploy-scripts/create-deploy-role.sh
RUN chmod +x /deploy-scripts/create-s3-bucket.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/deploy-scripts/deploy.sh", "-rbd"]