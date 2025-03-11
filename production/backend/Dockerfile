FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    curl \
    php \
    php-cli \
    php-fpm \
    sudo

RUN useradd -m admin && echo "admin:admin" | chpasswd && adduser admin sudo

RUN curl -LO https://get.gravitational.com/teleport_16.4.12_amd64.deb \
    && dpkg -i teleport_16.4.12_amd64.deb \
    && rm teleport_16.4.12_amd64.deb

RUN mkdir -p /var/run/sshd

EXPOSE 3024

CMD service ssh start && \
    service php7.4-fpm start || service php8.1-fpm start && \
    teleport start --config=/etc/teleport/teleport.yaml

