FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Installer les dépendances
RUN apt-get update && apt-get install -y \
    openssh-server \
    curl \
    mariadb-server \
    sudo

# Ajouter un utilisateur "admin" avec des droits sudo
RUN useradd -m admin && echo "admin:admin" | chpasswd && adduser admin sudo

# Installer Teleport 16.4.12
RUN curl -LO https://get.gravitational.com/teleport_16.4.12_amd64.deb \
    && dpkg -i teleport_16.4.12_amd64.deb \
    && rm teleport_16.4.12_amd64.deb

# Préparer le serveur SSH
RUN mkdir -p /var/run/sshd

# Exposer les ports nécessaires
EXPOSE 3022 3306

# Commande pour démarrer les services
CMD service ssh start && \
    service mariadb start && \
    teleport start --config=/etc/teleport/teleport.yaml
