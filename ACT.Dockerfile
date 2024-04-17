# Install ACT CLI: https://github.com/nektos/act
# FROM chocolatey/choco:latest-linux
FROM debian:latest

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y wget curl git tar
# RUN choco install act-cli -y && \
#     echo "PATH=\$PATH:/opt/chocolatey/lib/act-cli/tools" >> ~/.bashrc
    # Replace /path/to/act with the actual path to the act executable
    ## choco list --exact act-cli --trace
       ## /opt/chocolatey/lib/act-cli/tools/
RUN wget -qO act.tar.gz https://github.com/nektos/act/releases/latest/download/act_Linux_x86_64.tar.gz
RUN tar xf act.tar.gz -C /usr/local/bin act
RUN rm -rf act.tar.gz
RUN chmod +x /usr/local/bin/act


WORKDIR /github/workspace
CMD 'act -W "/github/workspace/.github/workflows/build-moodle-jfrog.yml"'
# CMD sleep infinity
