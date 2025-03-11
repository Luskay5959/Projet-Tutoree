FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 1) Mise à jour + installation de paquets de base (openssh, sudo, apache…)
RUN apt-get update && apt-get install -y \
    openssh-server \
    curl \
    apache2 \
    sudo

# 2) Créer un utilisateur admin avec mot de passe (pour SSH)
RUN useradd -m admin && echo "admin:admin" | chpasswd && adduser admin sudo

# 3) Installer Teleport (exemple : version 10.3.7)
#    Vérifiez la dernière version ici : https://goteleport.com/docs/setup/
RUN curl -LO https://get.gravitational.com/teleport_16.4.12_amd64.deb \
    && dpkg -i teleport_16.4.12_amd64.deb \
    && rm teleport_16.4.12_amd64.deb

# 4) Préparer le SSH
RUN mkdir -p /var/run/sshd

# 5) Expose les ports pour SSH et Apache
EXPOSE 3023 80

# 6) Au démarrage :
#    - Lancer SSH
#    - Lancer Apache
#    - Démarrer Teleport avec la config /etc/teleport/teleport.yaml
CMD service ssh start && \
    service apache2 start && \
    teleport start --config=/etc/teleport/teleport.yaml
