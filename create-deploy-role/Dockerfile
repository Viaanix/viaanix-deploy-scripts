# Container Image
FROM ubuntu

COPY create-deploy-role.sh /create-deploy-role.sh
COPY deploy.sh /deploy.sh

RUN chmod +x /create-deploy-role.sh
RUN chmod +x /deploy.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/deploy.sh", "-r"]