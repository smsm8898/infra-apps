FROM summerwind/actions-runner:ubuntu-22.04

ENV DOCKER_API_VERSION=1.44

RUN sudo apt-get update
RUN sudo apt-get install -y ca-certificates curl gnupg unzip
RUN sudo install -m 0755 -d /etc/apt/keyrings
RUN sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
RUN sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
RUN echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN sudo apt-get update

RUN sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io -y \
  && cd /tmp \
  && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
  && unzip awscliv2.zip \
  && sudo ./aws/install \
  && rm -rf awscliv2.zip ./aws \
  && sudo apt-get clean \
  && sudo rm -rf /var/lib/apt/lists/*
