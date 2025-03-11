#!/bin/bash

# Script CGI pour le dump de base de données via Teleport avec débogage
echo "Content-Type: text/html"
echo ""

# Activer le mode de trace pour le débogage
set -x

# Créer un fichier de log pour le débogage
DEBUG_LOG="/tmp/db_dump_debug_$(date +%Y%m%d%H%M%S).log"
touch "$DEBUG_LOG"
chmod 644 "$DEBUG_LOG"

echo "<html><head><title>Dump de Base de Données</title>"
echo "<style>"
echo "body { font-family: 'Roboto', sans-serif; margin: 20px; background-color: #f8f9fa; color: #212529; }"
echo "h1, h2 { color: #007bff; }"
echo "form { margin-bottom: 20px; }"
echo "label { font-weight: bold; display: block; margin-bottom: 5px; }"
echo "select, input, button { margin-top: 5px; padding: 10px; font-size: 1em; width: 100%; max-width: 300px; border: 1px solid #ced4da; border-radius: 4px; }"
echo "button { background-color: #007bff; color: white; border: none; cursor: pointer; }"
echo "button:hover { background-color: #0056b3; }"
echo "pre { background-color: #e9ecef; padding: 10px; border: 1px solid #ced4da; border-radius: 4px; white-space: pre-wrap; word-wrap: break-word; }"
echo ".copy-button { background-color: #28a745; color: white; border: none; cursor: pointer; padding: 6px 10px; margin-top: 5px; font-size: 0.9em; border-radius: 4px; }"
echo ".copy-button:hover { background-color: #218838; }"
echo "h2, p { margin-top: 20px; }"
echo ".step { display: none; }"
echo ".step.active { display: block; }"
echo ".summary { background-color: #d4edda; padding: 10px; border-radius: 4px; margin-bottom: 20px; }"
echo ".info-box { background-color: #cce5ff; padding: 10px; border-radius: 4px; margin-bottom: 10px; }"
echo ".warning-box { background-color: #fff3cd; padding: 10px; border-radius: 4px; margin-bottom: 10px; }"
echo ".error-box { background-color: #f8d7da; padding: 10px; border-radius: 4px; margin-bottom: 10px; }"
echo ".debug-box { background-color: #e2e3e5; padding: 10px; border-radius: 4px; margin-bottom: 10px; font-family: monospace; }"
echo "</style>"
echo "</head><body>"
echo "<h1>Dump de Base de Données via Teleport</h1>"

# Fonction pour logger les informations de débogage
log_debug() {
    echo "[DEBUG] $(date): $1" >> "$DEBUG_LOG"
    echo "<div class='debug-box'><p>Debug: $1</p></div>"
}

log_debug "Script démarré"

# Vérifier les dépendances requises
for cmd in tsh expect jq scp; do
    if ! command -v $cmd &> /dev/null; then
        echo "<div class='error-box'><p>❌ Erreur: La commande '$cmd' n'est pas installée. Veuillez l'installer pour continuer.</p></div>"
        log_debug "Commande manquante: $cmd"
        exit 1
    fi
done

# Charger les variables d'environnement depuis le fichier .env
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  log_debug "Fichier .env chargé depuis $ENV_FILE"
else
  echo "<div class='warning-box'>"
  echo "<p>❌ Erreur: Fichier de configuration .env non trouvé à $(dirname "$0")/.env</p>"
  echo "</div>"
  log_debug "Fichier .env non trouvé à $ENV_FILE"
  exit 1
fi

# Vérifier que les variables requises sont définies
if [[ -z "$DB_ROOT_PASSWORD" || -z "$DNS_USER_PASSWORD" ]]; then
  echo "<div class='warning-box'>"
  echo "<p>❌ Erreur: Variables d'environnement requises non définies dans le fichier .env</p>"
  echo "<p>Assurez-vous que DB_ROOT_PASSWORD et DNS_USER_PASSWORD sont définis.</p>"
  echo "</div>"
  log_debug "Variables d'environnement requises non définies"
  exit 1
fi

# Fonction pour décoder les URL
urldecode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

# Extraire tous les paramètres de l'URL
QUERY_STRING=${QUERY_STRING:-""}
log_debug "QUERY_STRING: $QUERY_STRING"

PROXY=$(echo "$QUERY_STRING" | sed -n 's/.*proxy=\([^&]*\).*/\1/p')
PROXY=$(urldecode "$PROXY")
log_debug "PROXY: $PROXY"

USERNAME=$(echo "$QUERY_STRING" | sed -n 's/.*username=\([^&]*\).*/\1/p')
USERNAME=$(urldecode "$USERNAME")
log_debug "USERNAME: $USERNAME"

PASSWORD=$(echo "$QUERY_STRING" | sed -n 's/.*password=\([^&]*\).*/\1/p')
PASSWORD=$(urldecode "$PASSWORD")
log_debug "PASSWORD: $PASSWORD"

MFA_CODE=$(echo "$QUERY_STRING" | sed -n 's/.*mfa=\([^&]*\).*/\1/p')
MFA_CODE=$(urldecode "$MFA_CODE")
log_debug "MFA_CODE: $MFA_CODE"

SELECTED_SERVER=$(echo "$QUERY_STRING" | sed -n 's/.*server=\([^&]*\).*/\1/p')
SELECTED_SERVER=$(urldecode "$SELECTED_SERVER")
log_debug "SELECTED_SERVER: $SELECTED_SERVER"

SELECTED_DB=$(echo "$QUERY_STRING" | sed -n 's/.*db=\([^&]*\).*/\1/p')
SELECTED_DB=$(urldecode "$SELECTED_DB")
log_debug "SELECTED_DB: $SELECTED_DB"

SELECTED_LOGIN=$(echo "$QUERY_STRING" | sed -n 's/.*login=\([^&]*\).*/\1/p')
SELECTED_LOGIN=$(urldecode "$SELECTED_LOGIN")
log_debug "SELECTED_LOGIN: $SELECTED_LOGIN"

STEP=$(echo "$QUERY_STRING" | sed -n 's/.*step=\([^&]*\).*/\1/p')
STEP=${STEP:-1} # Défaut à l'étape 1 si non spécifié
log_debug "STEP: $STEP"

# Tableau de correspondance entre les serveurs de base de données et les serveurs SSH
declare -A DB_SERVER_SSH_MAPPING
DB_SERVER_SSH_MAPPING=(
  ["mariadb-dev"]="client2-dev"
)

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

  if [[ -n "$SELECTED_DB" ]]; then
    echo "<p>🗄️ <strong>Base de données:</strong> $SELECTED_DB</p>"
  fi
  echo "</div>"
fi

# Étape 1: Connexion à Teleport
if [[ $STEP -eq 1 ]]; then
  echo "<div class='step active'>"
  echo "<h2>Étape 1: Connexion à Teleport</h2>"

  # Vérifier si l'utilisateur est déjà connecté à Teleport
  TELEPORT_STATUS=$(tsh status --format=json 2>/dev/null)

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

  echo "<div class='info-box' style='margin-top: 15px;'>"
  echo "<p>Note: Après cette étape, le système exécutera la commande de connexion à Teleport.</p>"
  echo "<p>Si l'authentification MFA est activée, vous recevrez une invite pour saisir votre code.</p>"
  echo "</div>"

  echo "<input type='hidden' name='step' value='2'>"
  echo "<button type='submit'>Se connecter</button>"
  echo "</form>"
  echo "</div>"

# Étape 2: Connexion et sélection du serveur de la base de données
elif [[ $STEP -eq 2 ]]; then
  log_debug "Affichage de l'étape 2"
  echo "<div class='step active'>"
  echo "<h2>Étape 2: Connexion à Teleport et sélection du serveur de base de données</h2>"

  # Vérifier si tsh est installé et accessible
  TSH_PATH=$(which tsh)
  if [[ -z "$TSH_PATH" ]]; then
      echo "<div class='warning-box'><p>❌ Erreur: tsh n'est pas installé ou introuvable.</p></div>"
      log_debug "tsh n'est pas installé ou introuvable"
      exit 1
  fi

  # Création d'un fichier temporaire pour stocker les logs
  DEBUG_LOG_TEMP=$(mktemp)

  # Exécution de la commande avec expect
  LOGIN_OUTPUT=$(expect -d <<EOF 2>&1 | tee "$DEBUG_LOG_TEMP"
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
  echo "<pre>$(cat "$DEBUG_LOG_TEMP")</pre>"
  echo "</div>"

  # Vérification du succès de la connexion
  if [[ $LOGIN_STATUS -ne 0 ]]; then
      echo "<div class='warning-box'>"
      echo "<p>❌ Échec de la connexion à Teleport :</p>"
      echo "<pre>$(cat "$DEBUG_LOG_TEMP")</pre>"
      echo "<p>Vérifiez vos identifiants et réessayez.</p>"
      echo "</div>"
      rm -f "$DEBUG_LOG_TEMP"
      exit 1
  fi

  echo "<div class='info-box'>"
  echo "<p>✅ Connexion à Teleport réussie !</p>"
  echo "</div>"

  # Nettoyage du fichier log temporaire
  rm -f "$DEBUG_LOG_TEMP"

  # Liste des bases de données disponibles
  log_debug "Récupération de la liste des serveurs de base de données..."
  DB_SERVERS_OUTPUT=$(tsh db ls --format=json 2>/dev/null)
  log_debug "DB_SERVERS_OUTPUT brut: $DB_SERVERS_OUTPUT"

  # Extraction plus robuste des noms de serveurs
  DB_SERVERS=$(echo "$DB_SERVERS_OUTPUT" | jq -r '.[].metadata.name')
  log_debug "DB_SERVERS après traitement: $DB_SERVERS"

  if [[ -z "$DB_SERVERS" ]]; then
    echo "<p>❌ Aucun serveur de base de données disponible. Vérifiez votre connexion.</p>"
    log_debug "Aucun serveur de base de données disponible"
    echo "<form method='get'>"
    echo "<input type='hidden' name='step' value='1'>"
    echo "<button type='submit'>Retour à l'étape précédente</button>"
    echo "</form>"
  else
    echo "<form id='dbServerForm' method='get'>"
    echo "<h3>Sélectionner un serveur de base de données</h3>"
    echo "<label for='server'>Serveur :</label>"
    echo "<select name='server' id='server'>"

    for SERVER in $DB_SERVERS; do
      SELECTED=""
      if [[ "$SERVER" == "$SELECTED_SERVER" ]]; then
        SELECTED="selected"
      fi
      echo "<option value='$SERVER' $SELECTED>$SERVER</option>"
      log_debug "Option de serveur ajoutée: $SERVER"
    done

    echo "</select>"

    # Conserver les paramètres précédents
    echo "<input type='hidden' name='proxy' value='$PROXY'>"
    echo "<input type='hidden' name='username' value='$USERNAME'>"
    echo "<input type='hidden' name='step' value='3'>"
    echo "<button type='submit'>Sélectionner</button>"
    echo "</form>"
  fi
  echo "</div>"

# Étape 3: Liste des bases de données
elif [[ $STEP -eq 3 ]]; then
  log_debug "Affichage de l'étape 3 - Liste des bases de données"
  echo "<div class='step active'>"
  echo "<h2>Étape 3: Sélection de la base de données</h2>"

  echo "<p>Connexion au serveur de base de données <strong>$SELECTED_SERVER</strong>...</p>"

  # Ajouter /usr/local/bin au PATH
  export PATH="/usr/local/bin:$PATH"

  # Créer un fichier temporaire pour les logs
  DB_LOG_TEMP=$(mktemp)
  log_debug "Fichier temporaire pour les logs DB: $DB_LOG_TEMP"

  # Version améliorée du script Expect
  cat > "$DB_LOG_TEMP.expect" << 'EXPECTSCRIPT'
#!/usr/bin/expect -f
# Désactiver le buffering de la sortie
log_file -noappend $env(DB_LOG_TEMP)
set timeout 45
set server [lindex $argv 0]

# Informations de débogage
send_user "\nDébut de la connexion à $server\n"

# Connexion au serveur de base de données
spawn tsh db connect $server

# Traiter différents scenarios possibles
expect {
  -re "(MariaDB|MySQL|mysql|mariadb).*>" {
    send_user "\nPrompt MariaDB détecté, envoi de 'SHOW DATABASES;'\n"
    send "SHOW DATABASES;\r"
    expect {
      -re "(MariaDB|MySQL|mysql|mariadb).*>" {
        send_user "\nRésultat obtenu, envoi de 'exit'\n"
        send "exit\r"
        expect eof
      }
      timeout {
        send_user "\nTimeout après SHOW DATABASES\n"
        exit 1
      }
    }
  }
  "Enter password:" {
    send_user "\nDemande de mot de passe détectée\n"
    send "$env(DB_ROOT_PASSWORD)\r"
    exp_continue
  }
  timeout {
    send_user "\nTimeout en attendant le prompt\n"
    exit 1
  }
  eof {
    send_user "\nFin de fichier inattendue\n"
    exit 1
  }
}
EXPECTSCRIPT

  chmod +x "$DB_LOG_TEMP.expect"

  # Exécuter le script Expect avec le nom du serveur en paramètre
  export DB_LOG_TEMP
  export DB_ROOT_PASSWORD
  "$DB_LOG_TEMP.expect" "$SELECTED_SERVER" >> "$DEBUG_LOG" 2>&1
  DB_LIST_STATUS=$?

  # Récupérer la sortie
  DB_LIST_OUTPUT=$(cat "$DB_LOG_TEMP")

  # Logs de debug (script Bash)
  log_debug "Statut de récupération des bases de données: $DB_LIST_STATUS"
  log_debug "Sortie de la récupération (premiers 500 caractères): ${DB_LIST_OUTPUT:0:500}..."

  # Afficher les logs sur la page
  echo "<div class='debug-box'>"
  echo "<p>Logs de débogage:</p>"
  echo "<pre>${DB_LIST_OUTPUT:0:2000}...</pre>"
  echo "</div>"

  # Gestion d'erreur
  if [[ $DB_LIST_STATUS -ne 0 ]]; then
    echo "<div class='warning-box'>"
    echo "<p>❌ Erreur lors de la récupération des bases de données :</p>"
    echo "<pre>${DB_LIST_OUTPUT:0:500}...</pre>"
    echo "</div>"
    echo "<form method='get'>"
    echo "  <input type='hidden' name='proxy' value='$PROXY'>"
    echo "  <input type='hidden' name='username' value='$USERNAME'>"
    echo "  <input type='hidden' name='server' value='$SELECTED_SERVER'>"
    echo "  <input type='hidden' name='step' value='2'>"
    echo "  <button type='submit'>Retour à la sélection du serveur</button>"
    echo "</form>"
  else
    # Si OK, parser le résultat
    echo "<div class='info-box'>"
    echo "<p>✅ Connexion au serveur réussie !</p>"
    echo "</div>"

    # Récupérer les bases de données dans la sortie
    DB_NAMES=$(echo "$DB_LIST_OUTPUT" \
      | grep '^|' \
      | grep -v -E "Database|information_schema|performance_schema|mysql|sys" \
      | sed 's/^[| ]*//; s/[| ]*$//' \
      | awk -F'|' '{print $1}' \
      | sed 's/ //g' \
      | sed '/^$/d')

    log_debug "Bases de données trouvées: $DB_NAMES"

    if [[ -z "$DB_NAMES" ]]; then
      echo "<div class='warning-box'>"
      echo "<p>❌ Aucune base de données utilisateur trouvée sur ce serveur.</p>"
      echo "</div>"
      echo "<form method='get'>"
      echo "  <input type='hidden' name='proxy' value='$PROXY'>"
      echo "  <input type='hidden' name='username' value='$USERNAME'>"
      echo "  <input type='hidden' name='step' value='2'>"
      echo "  <button type='submit'>Retour à la sélection du serveur</button>"
      echo "</form>"
    else
      # Génération du formulaire <select> pour choisir la BDD
      echo "<form id='dbSelectionForm' method='get'>"
      echo "  <h3>Sélectionner une base de données à exporter</h3>"
      echo "  <label for='db'>Base de données :</label>"
      echo "  <select name='db' id='db'>"

      for DB in $DB_NAMES; do
        SELECTED=""
        if [[ "$DB" == "$SELECTED_DB" ]]; then
          SELECTED="selected"
        fi
        echo "    <option value='$DB' $SELECTED>$DB</option>"
        log_debug "Option de base de données ajoutée: $DB"
      done

      echo "  </select>"

      # Conserver les paramètres précédents
      echo "  <input type='hidden' name='proxy' value='$PROXY'>"
      echo "  <input type='hidden' name='username' value='$USERNAME'>"
      echo "  <input type='hidden' name='server' value='$SELECTED_SERVER'>"
      echo "  <input type='hidden' name='step' value='4'>"
      echo "  <button type='submit'>Suivant</button>"
      echo "</form>"
    fi
  fi

  # Nettoyer les fichiers temporaires
  rm -f "$DB_LOG_TEMP" "$DB_LOG_TEMP.expect"

  echo "</div>"

# Étape 4: Sélection du login pour le dump
elif [[ $STEP -eq 4 ]]; then
  log_debug "Affichage de l'étape 4 - Sélection du login"
  echo "<div class='step active'>"
  echo "<h2>Étape 4: Sélection du login pour le dump</h2>"

  # Obtenir les logins disponibles via tsh status
  TELEPORT_STATUS=$(tsh status --format=json 2>/dev/null)
  USER_LOGINS=$(echo "$TELEPORT_STATUS" | jq -r '.active.logins[]' | sort | uniq)
  log_debug "Logins disponibles: $USER_LOGINS"

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
    echo "<label for='login'>Login pour le dump :</label>"
    echo "<select name='login' id='login'>"
    for LOGIN in $USER_LOGINS; do
      SELECTED=""
      if [[ "$LOGIN" == "$SELECTED_LOGIN" ]]; then
        SELECTED="selected"
      fi
      echo "<option value='$LOGIN' $SELECTED>$LOGIN</option>"
    done
    echo "</select>"

    # Conserver les paramètres précédents
    echo "<input type='hidden' name='proxy' value='$PROXY'>"
    echo "<input type='hidden' name='username' value='$USERNAME'>"
    echo "<input type='hidden' name='server' value='$SELECTED_SERVER'>"
    echo "<input type='hidden' name='db' value='$SELECTED_DB'>"
    echo "<input type='hidden' name='step' value='5'>"
    echo "<button type='submit'>Sélectionner le login</button>"
    echo "</form>"
  fi
  echo "</div>"

# Étape 5: Effectuer le dump, transférer vers serveur DNS et proposer téléchargement
elif [[ $STEP -eq 5 ]]; then
  log_debug "Affichage de l'étape 5 - Dump de la base de données"
  echo "<div class='step active'>"
  echo "<h2>Étape 5: Effectuer le dump et transfert vers serveur DNS</h2>"

  SSH_SERVER=${DB_SERVER_SSH_MAPPING[$SELECTED_SERVER]}
  if [[ -z "$SSH_SERVER" ]]; then
    echo "<div class='warning-box'>"
    echo "<p>❌ Aucun serveur SSH trouvé pour le serveur de base de données sélectionné.</p>"
    echo "</div>"
    log_debug "Aucun serveur SSH trouvé pour le serveur de base de données sélectionné"
    exit 1
  fi

  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  DUMP_FILENAME="${SELECTED_DB}_${TIMESTAMP}.sql"
  REMOTE_DUMP_FILE="/tmp/$DUMP_FILENAME"
  LOCAL_DUMP_PATH="/usr/local/bin/static/dumps"

  mkdir -p "$LOCAL_DUMP_PATH"
  chmod 775 "$LOCAL_DUMP_PATH"

  log_debug "Dump distant: $REMOTE_DUMP_FILE, Local: $LOCAL_DUMP_PATH"

  expect <<EOF
    spawn /usr/local/bin/tsh ssh --login=$SELECTED_LOGIN $SSH_SERVER
    expect "*\\$ "
    send "mysqldump -u root -p'$DB_ROOT_PASSWORD' '$SELECTED_DB' > '$REMOTE_DUMP_FILE'\r"
    expect "*\\$ "
    send "scp $REMOTE_DUMP_FILE dns@10.0.0.4:/tmp/\r"
    expect "password:"
    send "$DNS_USER_PASSWORD\r"
    expect "*\\$ "
    send "exit\r"
    expect eof
EOF

  DUMP_STATUS=$?
  log_debug "Statut du dump et transfert DNS: $DUMP_STATUS"

  /usr/local/bin/tsh scp --login=$SELECTED_LOGIN "$SSH_SERVER:$REMOTE_DUMP_FILE" "$LOCAL_DUMP_PATH/"

  # Correction des permissions pour Flask
  sudo chown www-data:www-data "$LOCAL_DUMP_PATH/$DUMP_FILENAME"
  sudo chmod 777 "$LOCAL_DUMP_PATH/$DUMP_FILENAME"

  if [[ $DUMP_STATUS -ne 0 ]]; then
    echo "<div class='warning-box'><p>❌ Échec du dump ou transfert DNS.</p></div>"
    log_debug "Échec du dump ou transfert DNS"
  else
    echo "<div class='info-box'><p>✅ Dump créé et transféré vers DNS avec succès.</p></div>"
    log_debug "Dump transféré avec succès"

    echo "<p>Télécharger le fichier :</p>"
    echo "<a href='/static/dumps/$DUMP_FILENAME' download class='copy-button'>Télécharger le dump</a>"
  fi

  echo "<form method='get'>"
  echo "<input type='hidden' name='step' value='1'>"
  echo "<button type='submit'>Nouveau dump</button>"
  echo "</form>"
  echo "</div>"
fi

# Affichage du lien vers le fichier de log pour le débogage
echo "<div style='margin-top: 30px; border-top: 1px solid #ccc; padding-top: 10px;'>"
echo "<p><strong>Informations de débogage:</strong> <a href='$DEBUG_LOG' target='_blank'>Voir le fichier log</a></p>"
echo "</div>"

echo "</body></html>"
