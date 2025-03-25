#!/bin/bash

# Script CGI pour la connexion, la sélection du serveur, du login et du dossier via Teleport
echo "Content-Type: text/html"
echo ""
echo "<!DOCTYPE html>"
echo "<html>"
echo "<head>"
echo "<meta charset='UTF-8'>"
echo "<title>SSHFS Mount</title>"
echo "<link rel='stylesheet' type='text/css' href='/static/styles.css'>"
echo "</head>"
echo "<body>"
echo "<h1>Connexion et sélection de serveur/login/dossier via Teleport</h1>"

# Fonction pour décoder les URL
urldecode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

# Extraire tous les paramètres de l'URL
PROXY=$(echo "$QUERY_STRING" | sed -n 's/.*proxy=\([^&]*\).*/\1/p')
PROXY=$(urldecode "$PROXY")

USERNAME=$(echo "$QUERY_STRING" | sed -n 's/.*username=\([^&]*\).*/\1/p')
USERNAME=$(urldecode "$USERNAME")

PASSWORD=$(echo "$QUERY_STRING" | sed -n 's/.*password=\([^&]*\).*/\1/p')
PASSWORD=$(urldecode "$PASSWORD")

MFA_CODE=$(echo "$QUERY_STRING" | sed -n 's/.*mfa=\([^&]*\).*/\1/p')
MFA_CODE=$(urldecode "$MFA_CODE")

SELECTED_SERVER=$(echo "$QUERY_STRING" | sed -n 's/.*server=\([^&]*\).*/\1/p')
SELECTED_SERVER=$(urldecode "$SELECTED_SERVER")

SELECTED_LOGIN=$(echo "$QUERY_STRING" | sed -n 's/.*login=\([^&]*\).*/\1/p')
SELECTED_LOGIN=$(urldecode "$SELECTED_LOGIN")

SELECTED_DIR=$(echo "$QUERY_STRING" | sed -n 's/.*dir=\([^&]*\).*/\1/p')
SELECTED_DIR=$(urldecode "$SELECTED_DIR")

STEP=$(echo "$QUERY_STRING" | sed -n 's/.*step=\([^&]*\).*/\1/p')
STEP=${STEP:-1} # Défaut à l'étape 1 si non spécifié

# Afficher le résumé des sélections faites
if [[ $STEP -gt 1 ]]; then
  echo "<div class='summary'>"
  if [[ -n "$PROXY" ]]; then
    echo "<p>🌐 <strong>Proxy:</strong> $PROXY</p>"
  fi

  if [[ -n "$USERNAME" ]]; then
    echo "<p>👤 <strong>Nom d'utilisateur:</strong> $USERNAME</p>"
  fi

  if [[ -n "$SELECTED_SERVER" ]]; then
    echo "<p>🖥️ <strong>Serveur:</strong> $SELECTED_SERVER</p>"
  fi

  if [[ -n "$SELECTED_LOGIN" ]]; then
    echo "<p>👤 <strong>Login:</strong> $SELECTED_LOGIN</p>"
  fi

  if [[ -n "$SELECTED_DIR" ]]; then
    echo "<p>📂 <strong>Dossier:</strong> $SELECTED_DIR</p>"
  fi
  echo "</div>"
fi

# Étape 1: Connexion à Teleport
if [[ $STEP -eq 1 ]]; then
  echo "<div class='step active'>"
  echo "<h2>Étape 1: Connexion à Teleport</h2>"

  # Vérifier si l'utilisateur est déjà connecté à Teleport
  TELEPORT_STATUS=$(tsh status --format=json 2> /dev/null)

  if [[ -n "$TELEPORT_STATUS" ]]; then
    TELEPORT_USER=$(echo "$TELEPORT_STATUS" | jq -r '.active.username')
    TELEPORT_CLUSTER=$(echo "$TELEPORT_STATUS" | jq -r '.active.cluster')

    echo "<div class='warning-box'>"
    echo "<p>⚠️ Vous semblez déjà connecté en tant que : $TELEPORT_USER sur $TELEPORT_CLUSTER</p>"
    echo "<p>Pour assurer un fonctionnement optimal, nous allons tout de même vous reconnecter.</p>"
    echo "</div>"
  fi

  echo "<p>Veuillez saisir vos informations de connexion :</p>"
  echo "<form id='loginForm' method='get'>"

  echo "<label for='proxy'>Proxy Teleport :</label>"
  echo "<input type='text' id='proxy' name='proxy' value='teleport.teleport.com' required>"

  echo "<label for='username'>Nom d'utilisateur :</label>"
  echo "<input type='text' id='username' name='username' placeholder='votre.nom' required>"

  echo "<label for='password'>Mot de passe :</label>"
  echo "<input type='password' id='password' name='password' required>"

  echo "<label for='mfa'>Code MFA :</label>"
  echo "<input type='text' id='mfa' name='mfa' placeholder='Code MFA' required>"

  echo "<input type='hidden' name='step' value='2'>"
  echo "<button type='submit'>Se connecter</button>"
  echo "</form>"
  echo "</div>"

# Étape 2: Exécution de la connexion et sélection du serveur
elif [[ $STEP -eq 2 ]]; then
  echo "<div class='step active'>"
  echo "<h2>Étape 2: Connexion à Teleport et sélection du serveur</h2>"

  # Vérifier si tsh est installé et accessible
  TSH_PATH=$(which tsh)
  if [[ -z "$TSH_PATH" ]]; then
    echo "<div class='warning-box'><p>❌ Erreur: tsh n'est pas installé ou introuvable.</p></div>"
    exit 1
  fi

  # Création d'un fichier temporaire pour stocker les logs
  DEBUG_LOG=$(mktemp)

  # Exécution de la commande avec expect
  LOGIN_OUTPUT=$(
    expect -d << EOF 2>&1 | tee "$DEBUG_LOG"
      log_user 1
      exp_internal 1
      spawn $TSH_PATH login --proxy=$PROXY --user=$USERNAME
      expect {
          "Enter password for Teleport user*" {
              send "$PASSWORD\r"
              exp_continue
          }
          "Enter an OTP code from a device:*" {
              send "$MFA_CODE\r"
              exp_continue
          }
          eof
      }
EOF
  )

  LOGIN_STATUS=$?

  # Affichage des logs sur la page web
  echo "<div class='info-box'>"
  echo "<p>🔍 Logs de connexion (Debug Mode) :</p>"
  echo "<pre>$(cat "$DEBUG_LOG")</pre>"
  echo "</div>"

  # Vérification du succès de la connexion
  if [[ $LOGIN_STATUS -ne 0 ]]; then
    echo "<div class='warning-box'>"
    echo "<p>❌ Échec de la connexion à Teleport :</p>"
    echo "<pre>$(cat "$DEBUG_LOG")</pre>"
    echo "<p>Vérifiez vos identifiants et réessayez.</p>"
    echo "</div>"
    exit 1
  fi

  echo "<div class='info-box'>"
  echo "<p>✅ Connexion à Teleport réussie !</p>"
  echo "</div>"

  # Nettoyage du fichier log
  rm -f "$DEBUG_LOG"

  # Vérifier les serveurs disponibles
  SERVERS_JSON=$(tsh ls --format=json 2> /dev/null)

  if [[ -z "$SERVERS_JSON" ]]; then
    echo "<p>❌ Aucun serveur disponible. Vérifiez votre connexion.</p>"
    echo "<form method='get'>"
    echo "<input type='hidden' name='step' value='1'>"
    if [[ -n "$PROXY" ]]; then
      echo "<input type='hidden' name='proxy' value='$PROXY'>"
    fi
    if [[ -n "$USERNAME" ]]; then
      echo "<input type='hidden' name='username' value='$USERNAME'>"
    fi
    echo "<button type='submit'>Retour à l'étape précédente</button>"
    echo "</form>"
  else
    # Génération du formulaire pour la sélection du serveur
    echo "<h3>Sélection du serveur</h3>"
    echo "<form id='serverForm' method='get'>"
    echo "<label for='server'>Serveur :</label>"
    echo "<select name='server' id='server'>"

    echo "$SERVERS_JSON" | jq -r '.[].spec.hostname' | while read -r SERVER; do
      if [[ -n "$SERVER" && "$SERVER" != "null" ]]; then
        SELECTED=""
        if [[ "$SERVER" == "$SELECTED_SERVER" ]]; then
          SELECTED="selected"
        fi
        echo "<option value='$SERVER' $SELECTED>$SERVER</option>"
      fi
    done

    echo "</select>"

    # Préserver les autres paramètres
    if [[ -n "$PROXY" ]]; then
      echo "<input type='hidden' name='proxy' value='$PROXY'>"
    fi
    if [[ -n "$USERNAME" ]]; then
      echo "<input type='hidden' name='username' value='$USERNAME'>"
    fi
    echo "<input type='hidden' name='step' value='3'>"
    echo "<button type='submit'>Continuer</button>"
    echo "</form>"
  fi
  echo "</div>"

# Étape 3: Sélection du login
elif [[ $STEP -eq 3 ]]; then
  echo "<div class='step active'>"
  echo "<h2>Étape 3: Sélection du login</h2>"

  # Obtenir les logins disponibles
  TELEPORT_STATUS=$(tsh status --format=json 2> /dev/null)
  USER_LOGINS=$(echo "$TELEPORT_STATUS" | jq -r '.active.logins[]' | sort | uniq)

  if [[ -z "$USER_LOGINS" ]]; then
    echo "<p>❌ Aucun login disponible. Vérifiez votre connexion.</p>"
    echo "<div class='warning-box'>"
    echo "<p>La connexion à Teleport a peut-être échoué ou expiré. Essayez de vous reconnecter.</p>"
    echo "</div>"

    echo "<form method='get'>"
    echo "<input type='hidden' name='step' value='1'>"
    echo "<button type='submit'>Retour à l'étape de connexion</button>"
    echo "</form>"
  else
    echo "<form id='loginForm' method='get'>"
    echo "<label for='login'>Login :</label>"
    echo "<select name='login' id='login'>"

    for LOGIN in $USER_LOGINS; do
      SELECTED=""
      if [[ "$LOGIN" == "$SELECTED_LOGIN" ]]; then
        SELECTED="selected"
      fi
      echo "<option value='$LOGIN' $SELECTED>$LOGIN</option>"
    done

    echo "</select>"

    # Préserver les autres paramètres
    if [[ -n "$PROXY" ]]; then
      echo "<input type='hidden' name='proxy' value='$PROXY'>"
    fi
    if [[ -n "$USERNAME" ]]; then
      echo "<input type='hidden' name='username' value='$USERNAME'>"
    fi
    if [[ -n "$SELECTED_SERVER" ]]; then
      echo "<input type='hidden' name='server' value='$SELECTED_SERVER'>"
    fi
    echo "<input type='hidden' name='step' value='4'>"
    echo "<button type='submit'>Continuer</button>"
    echo "</form>"
  fi

  # Bouton pour retourner à l'étape précédente
  echo "<form method='get' style='margin-top: 10px;'>"
  echo "<input type='hidden' name='step' value='2'>"
  if [[ -n "$PROXY" ]]; then
    echo "<input type='hidden' name='proxy' value='$PROXY'>"
  fi
  if [[ -n "$USERNAME" ]]; then
    echo "<input type='hidden' name='username' value='$USERNAME'>"
  fi
  echo "<button type='submit' style='background-color: #fd7e14;'>Retour</button>"
  echo "</form>"
  echo "</div>"

# Étape 4: Sélection du dossier
elif [[ $STEP -eq 4 ]]; then
  echo "<div class='step active'>"
  echo "<h2>Étape 4: Sélection du dossier</h2>"

  # Récupérer le répertoire home de l'utilisateur
  HOME_PATH=$(tsh ssh --proxy=$PROXY $SELECTED_LOGIN@$SELECTED_SERVER -- getent passwd $SELECTED_LOGIN | cut -d: -f6 2> /dev/null)

  if [[ -z "$HOME_PATH" ]]; then
    echo "<p>❌ Impossible de récupérer le home directory de <b>$SELECTED_LOGIN</b>.</p>"
    echo "<div class='warning-box'>"
    echo "<p>La connexion à Teleport a peut-être expiré. Essayez de vous reconnecter.</p>"
    echo "</div>"

    echo "<form method='get'>"
    echo "<input type='hidden' name='step' value='1'>"
    echo "<button type='submit'>Retour à l'étape de connexion</button>"
    echo "</form>"
  else
    echo "<p>🏠 Home directory : $HOME_PATH</p>"

    # Récupérer les dossiers
    DIRECTORIES=$(tsh ssh --proxy=$PROXY $SELECTED_LOGIN@$SELECTED_SERVER -- bash -c "ls -d $HOME_PATH/*/ 2>/dev/null")

    echo "<form id='directoryForm' method='get'>"
    echo "<label for='dir'>Dossier :</label>"
    echo "<select name='dir' id='dir'>"

    # Ajouter l'option pour le home directory lui-même
    HOME_SELECTED=""
    if [[ "$SELECTED_DIR" == "$HOME_PATH" || -z "$SELECTED_DIR" ]]; then
      HOME_SELECTED="selected"
    fi
    echo "<option value='$HOME_PATH' $HOME_SELECTED>$HOME_PATH (Home Directory)</option>"

    # Ajouter les sous-dossiers
    if [[ -n "$DIRECTORIES" ]]; then
      for DIR in $DIRECTORIES; do
        SELECTED=""
        if [[ "$DIR" == "$SELECTED_DIR" ]]; then
          SELECTED="selected"
        fi
        echo "<option value='$DIR' $SELECTED>$DIR</option>"
      done
    fi

    echo "</select>"

    # Préserver les autres paramètres
    if [[ -n "$PROXY" ]]; then
      echo "<input type='hidden' name='proxy' value='$PROXY'>"
    fi
    if [[ -n "$USERNAME" ]]; then
      echo "<input type='hidden' name='username' value='$USERNAME'>"
    fi
    if [[ -n "$SELECTED_SERVER" ]]; then
      echo "<input type='hidden' name='server' value='$SELECTED_SERVER'>"
    fi
    if [[ -n "$SELECTED_LOGIN" ]]; then
      echo "<input type='hidden' name='login' value='$SELECTED_LOGIN'>"
    fi
    echo "<input type='hidden' name='step' value='5'>"
    echo "<button type='submit'>Continuer</button>"
    echo "</form>"
  fi

  # Bouton pour retourner à l'étape précédente
  echo "<form method='get' style='margin-top: 10px;'>"
  echo "<input type='hidden' name='step' value='3'>"
  if [[ -n "$PROXY" ]]; then
    echo "<input type='hidden' name='proxy' value='$PROXY'>"
  fi
  if [[ -n "$USERNAME" ]]; then
    echo "<input type='hidden' name='username' value='$USERNAME'>"
  fi
  if [[ -n "$SELECTED_SERVER" ]]; then
    echo "<input type='hidden' name='server' value='$SELECTED_SERVER'>"
  fi
  if [[ -n "$SELECTED_LOGIN" ]]; then
    echo "<input type='hidden' name='login' value='$SELECTED_LOGIN'>"
  fi
  echo "<button type='submit' style='background-color: #fd7e14;'>Retour</button>"
  echo "</form>"
  echo "</div>"

  # Étape 5: Résumé et commandes SSHFS
  DECONNECTED=$(tsh logout)
elif [[ $STEP -eq 5 ]]; then
  echo "<div class='step active'>"
  echo "<h2>Étape 5: Commandes SSHFS</h2>"

  echo "<h3>Résumé :</h3>"
  echo "<p>🌐 Proxy : <b>$PROXY</b></p>"
  echo "<p>👤 Utilisateur Teleport : <b>$USERNAME</b></p>"
  echo "<p>🖥️ Serveur : <b>$SELECTED_SERVER</b></p>"
  echo "<p>👤 Login : <b>$SELECTED_LOGIN</b></p>"
  echo "<p>📂 Dossier : <b>$SELECTED_DIR</b></p>"

  echo "<div class='info-box'>"
  echo "<p>✅ <strong>Connecté à Teleport !</strong> Vous êtes maintenant prêt à utiliser le montage SSHFS.</p>"
  echo "</div>"

  echo "<h3>📋 Instructions :</h3>"

  echo "<h3>🔑 Connexion Teleport</h3>"
  echo "<p>Assurez-vous d'être connecté à Teleport en exécutant cette commande dans votre terminal :</p>"
  echo "<div><pre id='teleport-login-command'>tsh login --proxy=$PROXY --user=$USERNAME</pre><button class='copy-button' onclick='copyCommand(\"teleport-login-command\")'>Copier</button></div>"

  echo "<h3>🚀 Création du point de montage</h3>"
  echo "<p>1. Créez un répertoire pour le montage :</p>"
  echo "<div><pre id='mount-command'>mkdir -p ~/mnt/sshfs</pre><button class='copy-button' onclick='copyCommand("mount-command")'>Copier</button></div>"

  echo "<h3>🔗 Montage SSHFS</h3>"
  echo "<p>2. Montez le dossier distant avec cette commande :</p>"
  echo "<div><pre id='sshfs-command'>sshfs -o ssh_command='ssh -J dns@10.0.0.4' $SELECTED_LOGIN@$SELECTED_SERVER:$SELECTED_DIR ~/mnt/sshfs</pre><button class='copy-button' onclick='copyCommand("sshfs-command")'>Copier</button></div>"

  echo "<h3>📤 Démontage</h3>"
  echo "<p>3. Pour démonter quand vous avez terminé :</p>"
  echo "<div><pre id='umount-command'>umount ~/mnt/sshfs</pre><button class='copy-button' onclick='copyCommand(\"umount-command\")'>Copier</button></div>"

  echo "<h3>🚪 Déconnexion</h3>"
  echo "<p>4. Pour vous déconnecter de Teleport quand vous avez terminé :</p>"
  echo "<div><pre id='logout-command'>tsh logout</pre><button class='copy-button' onclick='copyCommand(\"logout-command\")'>Copier</button></div>"

  # Bouton pour recommencer
  echo "<form method='get' style='margin-top: 20px;'>"
  echo "<input type='hidden' name='step' value='1'>"
  echo "<button type='submit'>Recommencer</button>"
  echo "</form>"

  # Bouton pour retourner à l'étape précédente
  echo "<form method='get' style='margin-top: 10px;'>"
  echo "<input type='hidden' name='step' value='4'>"
  if [[ -n "$PROXY" ]]; then
    echo "<input type='hidden' name='proxy' value='$PROXY'>"
  fi
  if [[ -n "$USERNAME" ]]; then
    echo "<input type='hidden' name='username' value='$USERNAME'>"
  fi
  if [[ -n "$SELECTED_SERVER" ]]; then
    echo "<input type='hidden' name='server' value='$SELECTED_SERVER'>"
  fi
  if [[ -n "$SELECTED_LOGIN" ]]; then
    echo "<input type='hidden' name='login' value='$SELECTED_LOGIN'>"
  fi
  echo "<button type='submit' style='background-color: #fd7e14;'>Retour</button>"
  echo "</form>"
  echo "</div>"
fi

echo "<script>"
echo "function copyCommand(commandId) {"
echo "  const commandText = document.getElementById(commandId).innerText;"
echo "  navigator.clipboard.writeText(commandText).then(() => {"
echo "    alert('Commande copiée : ' + commandText);"
echo "  }).catch(err => {"
echo "    console.error('Erreur lors de la copie : ', err);"
echo "  });"
echo "}"
echo "</script>"

echo "</body></html>"
