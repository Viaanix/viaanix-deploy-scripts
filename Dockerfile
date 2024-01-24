# Container Image
FROM amazon/aws-cli

ADD deploy-scripts deploy-scripts

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/deploy-scripts/deploy.sh"]