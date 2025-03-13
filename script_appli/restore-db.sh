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

# Fonction pour logger les informations de débogage
log_debug() {
    echo "[DEBUG] $(date): $1" >> "$DEBUG_LOG"
    echo "<div class='debug-box'><p>Debug: $1</p></div>"
}

log_debug "Script démarré"

# Vérifier la méthode de requête
if [[ "$REQUEST_METHOD" == "POST" ]]; then
    log_debug "Requête POST détectée"
    read -r POST_DATA
    log_debug "Données POST reçues: $POST_DATA"

    # Extraire le mot de passe SCP des données POST
    SCP_PASSWORD=$(echo "$POST_DATA" | sed -n 's/.*scp_password=\([^&]*\).*/\1/p')
    log_debug "SCP_PASSWORD extrait: $SCP_PASSWORD"

    # Vérifier si le mot de passe est présent
    if [[ -n "$SCP_PASSWORD" ]]; then
        log_debug "Mot de passe SCP valide"
        # Ajoutez ici le code pour effectuer le transfert SCP et la restauration
        echo "<div class='info-box'><p>Mot de passe SCP soumis avec succès. Début de la restauration...</p></div>"

        # Exemple de commande SCP (à adapter selon votre configuration)
        # scp -P 22 /path/to/local/file.sql user@remote:/path/to/remote/
        # Ajoutez ici la logique pour la restauration de la base de données

    else
        echo "<div class='error-box'><p>Erreur: Mot de passe SCP manquant.</p></div>"
        log_debug "Mot de passe SCP manquant"
    fi
else
    log_debug "Requête GET détectée"

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

# Étape 5: Upload du fichier, transfert vers serveur DB et restauration
elif [[ $STEP -eq 5 ]]; then
  log_debug "==================== DÉBUT ÉTAPE 5 ===================="
  log_debug "Affichage de l'étape 5 - Restauration de la base de données"
  log_debug "SELECTED_DB=$SELECTED_DB"
  log_debug "SELECTED_LOGIN=$SELECTED_LOGIN"
  log_debug "REQUEST_METHOD=$REQUEST_METHOD"
  log_debug "CONTENT_TYPE=$CONTENT_TYPE"

  # Récupération du mot de passe SCP depuis le fichier .env
  if [[ -n "$SELECTED_LOGIN" ]]; then
    SCP_PASSWORD_VAR="${SELECTED_LOGIN^^}_PASSWORD"
    SCP_PASSWORD=${!SCP_PASSWORD_VAR}

    log_debug "Login sélectionné: $SELECTED_LOGIN, variable de mot de passe: $SCP_PASSWORD_VAR"

    if [[ -z "$SCP_PASSWORD" ]]; then
      log_debug "ATTENTION: Mot de passe SCP non trouvé pour $SELECTED_LOGIN"
    else
      log_debug "Mot de passe SCP récupéré pour $SELECTED_LOGIN"
    fi
  else
    log_debug "ERREUR: Aucun login sélectionné à l'étape précédente"
  fi

  # Enregistrer les variables dans un fichier temporaire
  TEMP_FILE="/tmp/db_restore_temp.txt"
  echo "SELECTED_DB=$SELECTED_DB" > "$TEMP_FILE"
  echo "PROXY=$PROXY" >> "$TEMP_FILE"
  echo "USERNAME=$USERNAME" >> "$TEMP_FILE"
  echo "SELECTED_SERVER=$SELECTED_SERVER" >> "$TEMP_FILE"
  echo "SELECTED_LOGIN=$SELECTED_LOGIN" >> "$TEMP_FILE"

  # Vérification et création du répertoire d'upload avec les bons droits
  UPLOAD_DIR="/usr/local/bin/static/uploads/"
  if [[ ! -d "$UPLOAD_DIR" ]]; then
    log_debug "Répertoire $UPLOAD_DIR inexistant. Création en cours."
    sudo mkdir -p "$UPLOAD_DIR"
    sudo chmod 777 "$UPLOAD_DIR"
  fi
  sudo chown $(whoami):$(whoami) "$UPLOAD_DIR"
  log_debug "Permissions du répertoire $UPLOAD_DIR mises à jour."

  # Vérifier si un fichier est déjà présent dans le répertoire d'upload
  UPLOADED_FILE=$(ls -1 "$UPLOAD_DIR" | head -n 1)
  log_debug "Fichier trouvé dans le répertoire d'upload: $UPLOADED_FILE"

  # Partie HTML pour l'affichage du formulaire d'upload
  echo "<div class='step active'>"
  echo "<h2>Étape 5: Upload du fichier et restauration</h2>"

  # Vérifier si un message d'erreur ou de succès existe déjà
  if [[ -n "$ERROR_MESSAGE" ]]; then
    echo "<div class='warning-box'><p>❌ $ERROR_MESSAGE</p></div>"
    log_debug "Affichage message d'erreur: $ERROR_MESSAGE"
  fi

  if [[ -n "$SUCCESS_MESSAGE" ]]; then
    echo "<div class='info-box'><p>✅ $SUCCESS_MESSAGE</p></div>"
    log_debug "Affichage message de succès: $SUCCESS_MESSAGE"
  fi

  # Formulaire d'upload avec conservation du contexte
  echo "<form id='uploadForm' enctype='multipart/form-data'>"
  echo "<input type='hidden' name='step' value='5'>"
  echo "<input type='hidden' name='db' value='$SELECTED_DB'>"
  echo "<input type='hidden' name='login' value='$SELECTED_LOGIN'>"
  echo "<div class='form-group'>"
  echo "<label for='sqlfile'>Fichier SQL à restaurer:</label>"
  echo "<input type='file' id='sqlfile' name='sqlfile' accept='.sql' required>"
  echo "</div>"
  echo "<button type='button' onclick='uploadFile()'>Uploader le fichier</button>"
  echo "</form>"
  echo "<div id='uploadStatus'></div>"

  # Ajout du script JavaScript pour AJAX
  echo "<script>
  function uploadFile() {
      var formData = new FormData(document.getElementById('uploadForm'));
      var xhr = new XMLHttpRequest();
      xhr.open('POST', '/upload', true);
      xhr.onreadystatechange = function () {
          if (xhr.readyState === 4) {
              document.getElementById('uploadStatus').innerHTML = xhr.responseText;
              if (xhr.status === 200) {
                  document.getElementById('passwordForm').style.display = 'block';
              }
          }
      };
      xhr.send(formData);
  }

  function submitPassword() {
      var formData = new FormData(document.getElementById('passwordForm'));
      var xhr = new XMLHttpRequest();
      xhr.open('POST', '/cgi-bin/script.sh?submit_password', true);
      xhr.onreadystatechange = function () {
          if (xhr.readyState === 4) {
              document.getElementById('uploadStatus').innerHTML = xhr.responseText;
          }
      };
      xhr.send(formData);
  }
  </script>"

  # Vérification de l'upload et traitement
  log_debug "Vérification de l'upload: UPLOADED_FILE='$UPLOADED_FILE'"

  # Si nous sommes dans le contexte post-upload
  if [[ -n "$UPLOADED_FILE" ]]; then
    log_debug "Fichier uploadé détecté: $UPLOADED_FILE"
    LOCAL_FILE_PATH="$UPLOAD_DIR$UPLOADED_FILE"
    REMOTE_RESTORE_FILE="/home/$SELECTED_LOGIN/$UPLOADED_FILE"
    SSH_SERVER="${SELECTED_LOGIN}-dev"

    # Vérification du fichier local
    log_debug "Vérification de l'existence du fichier local: $LOCAL_FILE_PATH"
    if [[ -f "$LOCAL_FILE_PATH" ]]; then
      FILE_SIZE=$(du -h "$LOCAL_FILE_PATH" | cut -f1)
      log_debug "Fichier local existe, taille: $FILE_SIZE"
      echo "<div class='info-box'><p>Fichier '$UPLOADED_FILE' ($FILE_SIZE) uploadé avec succès. Transfert vers le serveur de base de données...</p></div>"

      # Transfert du fichier vers le serveur DB
      log_debug "Transfert du fichier vers le serveur DB: $SSH_SERVER:$REMOTE_RESTORE_FILE"
      echo "<div class='info-box'><p>Transfert du fichier vers le serveur de base de données...</p></div>"

      # Création d'un fichier temporaire pour capturer la sortie SCP
      SCP_LOG=$(mktemp)

      # Utiliser le mot de passe récupéré du .env pour le transfert SCP
      if [[ -n "$SCP_PASSWORD" ]]; then
        log_debug "Transfert avec sshpass et le mot de passe du .env"
        sshpass -p "$SCP_PASSWORD" scp -v "$LOCAL_FILE_PATH" "${SELECTED_LOGIN}@10.0.1.4:$REMOTE_RESTORE_FILE" > "$SCP_LOG" 2>&1
      else
        log_debug "Transfert standard sans mot de passe explicite"
        scp -v "$LOCAL_FILE_PATH" "${SELECTED_LOGIN}@10.0.1.4:$REMOTE_RESTORE_FILE" > "$SCP_LOG" 2>&1
      fi

      SCP_STATUS=$?
      cat "$SCP_LOG" | while read line; do log_debug "SCP: $line"; done
      rm -f "$SCP_LOG"

      log_debug "Statut SCP: $SCP_STATUS"

      if [[ $SCP_STATUS -ne 0 ]]; then
        log_debug "ERREUR: Échec du transfert SCP"
        echo "<div class='warning-box'><p>❌ Échec du transfert de fichier vers le serveur de base de données.</p></div>"
      else
        log_debug "Transfert réussi, vérification du fichier sur le serveur distant"
        echo "<div class='info-box'><p>Fichier transféré. Lancement de la restauration...</p></div>"

        # Vérification du fichier sur le serveur distant
        FILE_CHECK_LOG=$(mktemp)

        if [[ -n "$SCP_PASSWORD" ]]; then
          sshpass -p "$SCP_PASSWORD" ssh ${SELECTED_LOGIN}@10.0.1.4 "if [[ -f '$REMOTE_RESTORE_FILE' ]]; then echo 'exists'; else echo 'missing'; fi" > "$FILE_CHECK_LOG" 2>&1
        else
          ssh ${SELECTED_LOGIN}@10.0.1.4 "if [[ -f '$REMOTE_RESTORE_FILE' ]]; then echo 'exists'; else echo 'missing'; fi" > "$FILE_CHECK_LOG" 2>&1
        fi

        REMOTE_FILE_CHECK=$(cat "$FILE_CHECK_LOG")
        rm -f "$FILE_CHECK_LOG"

        log_debug "Vérification du fichier distant: $REMOTE_FILE_CHECK"

        if [[ "$REMOTE_FILE_CHECK" != "exists" ]]; then
          log_debug "ERREUR: Fichier distant non trouvé après transfert"
          echo "<div class='warning-box'><p>❌ Le fichier n'a pas été correctement transféré sur le serveur de base de données.</p></div>"
        else
          # Préparation de la restauration
          log_debug "Exécution de la restauration avec expect"
          DB_COMMAND="mysql -u root -p'$DB_ROOT_PASSWORD' '$SELECTED_DB' < '$REMOTE_RESTORE_FILE'"
          log_debug "Commande mysql qui sera exécutée: $DB_COMMAND"

          # Fichier temporaire pour la sortie d'expect
          EXPECT_LOG=$(mktemp)
          MYSQL_STATUS_FILE="/tmp/mysql_status_${SELECTED_LOGIN}.txt"

          # Script simple pour exécuter la commande et capturer le statut
          # Approche simplifiée pour éviter les problèmes d'expect
          expect <<EOF > "$EXPECT_LOG" 2>&1
spawn /usr/local/bin/tsh ssh --login=${SELECTED_LOGIN} ${SSH_SERVER}
expect "*\\$ "
send "echo 'Début de la restauration pour $SELECTED_DB'\r"
expect "*\\$ "
send "$DB_COMMAND\r"
expect "*\\$ "
send "echo \\\$? > $MYSQL_STATUS_FILE\r"
expect "*\\$ "
send "cat $MYSQL_STATUS_FILE\r"
expect "*\\$ "
send "rm -fv '$REMOTE_RESTORE_FILE'\r"
expect "*\\$ "
send "exit\r"
expect eof
EOF

          # Capture et log du résultat
          EXPECT_STATUS=$?
          cat "$EXPECT_LOG" | while read line; do log_debug "EXPECT: $line"; done

          # Récupération du statut MySQL depuis le fichier distant
          MYSQL_STATUS_LOG=$(mktemp)
          
          if [[ -n "$SCP_PASSWORD" ]]; then
            sshpass -p "$SCP_PASSWORD" ssh ${SELECTED_LOGIN}@10.0.1.4 "cat $MYSQL_STATUS_FILE 2>/dev/null || echo -1" > "$MYSQL_STATUS_LOG" 2>&1
          else
            ssh ${SELECTED_LOGIN}@10.0.1.4 "cat $MYSQL_STATUS_FILE 2>/dev/null || echo -1" > "$MYSQL_STATUS_LOG" 2>&1
          fi
          
          MYSQL_STATUS=$(cat "$MYSQL_STATUS_LOG")
          rm -f "$MYSQL_STATUS_LOG"
          
          log_debug "Statut MySQL récupéré: $MYSQL_STATUS"
          
          # Nettoyage du fichier temporaire sur le serveur distant
          if [[ -n "$SCP_PASSWORD" ]]; then
            sshpass -p "$SCP_PASSWORD" ssh ${SELECTED_LOGIN}@10.0.1.4 "rm -f $MYSQL_STATUS_FILE" &>/dev/null
          else
            ssh ${SELECTED_LOGIN}@10.0.1.4 "rm -f $MYSQL_STATUS_FILE" &>/dev/null
          fi
          
          rm -f "$EXPECT_LOG"

          # Affichage du résultat basé uniquement sur le statut MySQL
          # Ne pas se fier au statut de expect qui peut échouer pour d'autres raisons
          if [[ "$MYSQL_STATUS" == "0" ]]; then
            echo "<div class='info-box'><p>✅ Base de données '$SELECTED_DB' restaurée avec succès.</p></div>"
            log_debug "Restauration terminée avec succès, statut MySQL=$MYSQL_STATUS"
          else
            echo "<div class='warning-box'><p>❌ Échec de la restauration. Vérifiez les logs pour plus de détails.</p></div>"
            log_debug "Échec de la restauration, statut expect=$EXPECT_STATUS, statut mysql=$MYSQL_STATUS"
          fi
        fi
      fi
    else
      log_debug "ERREUR CRITIQUE: Fichier local n'existe pas malgré UPLOADED_FILE défini!"
      echo "<div class='warning-box'><p>❌ Erreur lors du traitement du fichier uploadé. Le fichier n'a pas été trouvé.</p></div>"
    fi
  else
    # Vérification du traitement des fichiers uploadés
    log_debug "Aucun fichier uploadé détecté."

    # Tester l'accès en écriture au répertoire de destination
    WRITE_TEST=$(mktemp -p /usr/local/bin/static/uploads/ test_XXXXXX 2>&1) || true
    if [[ -f "$WRITE_TEST" ]]; then
      rm -f "$WRITE_TEST"
      log_debug "Test d'écriture dans le répertoire de destination réussi"
    else
      log_debug "ERREUR: Impossible d'écrire dans le répertoire de destination"
      echo "<div class='warning-box'><p>❌ Le répertoire de destination n'est pas accessible en écriture. Contactez l'administrateur.</p></div>"
    fi

    # Vérifier si nous sommes dans un POST d'upload
    if [[ "$REQUEST_METHOD" == "POST" && "$CONTENT_TYPE" == *"multipart/form-data"* ]]; then
      log_debug "POST détecté avec multipart/form-data mais UPLOADED_FILE non défini!"
      echo "<div class='warning-box'><p>❌ Erreur lors de l'upload du fichier. Vérifiez que le fichier n'est pas trop volumineux (max 100MB) et que son format est valide (.sql).</p></div>"
    fi
  fi

  # Boutons de navigation
  echo "<div class='navigation-buttons'>"
  echo "<form method='get'>"
  echo "<input type='hidden' name='step' value='4'>"
  echo "<input type='hidden' name='db' value='$SELECTED_DB'>"
  echo "<button type='submit'>Retour</button>"
  echo "</form>"

  echo "<form method='get'>"
  echo "<input type='hidden' name='step' value='1'>"
  echo "<button type='submit'>Nouvelle restauration</button>"
  echo "</form>"
  echo "</div>"

  echo "</div>"
  log_debug "==================== FIN ÉTAPE 5 ===================="
fi
fi
