# Container Image
FROM ubuntu

COPY ./setupenv.sh /setupenv.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/setupenv.sh"]