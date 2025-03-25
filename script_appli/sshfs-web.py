from flask import Flask, Response, request, redirect, url_for, render_template_string, send_from_directory
import subprocess
import os

app = Flask(__name__)

UPLOAD_DIR = '/usr/local/bin/static/uploads'
DUMP_DIR = '/usr/local/bin/static/dumps'

os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(DUMP_DIR, exist_ok=True)

@app.route("/", methods=["GET"])
def index():
    return render_template_string('''
        <html>
        <head>
            <title>Accueil</title>
            <!-- Chargement du CSS externe -->
            <link rel="stylesheet" href="{{ url_for('static', filename='styles.css') }}">
        </head>
        <body>
            <h1>Bienvenue sur l'outil de gestion Teleport</h1>
            <div class="button-container">
                <form action="{{ url_for('mount_sshfs') }}" method="get">
                    <button type="submit">Monter SSHFS</button>
                </form>
                <form action="{{ url_for('dump_database') }}" method="get">
                    <button type="submit">Dump de Base de Données</button>
                </form>
                <form action="{{ url_for('restore_database') }}" method="get">
                    <button type="submit">Restauration de Base de Données</button>
                </form>
            </div>
        </body>
        </html>
    ''')

@app.route("/restore", methods=["GET", "POST"])
def restore_database():
    if request.method == "POST":
        scp_password = request.form.get('scp_password')
        if scp_password:
            return "<div class='info-box'><p>Mot de passe SCP soumis avec succès. Début de la restauration...</p></div>"
        else:
            return "<div class='error-box'><p>Erreur: Mot de passe SCP manquant.</p></div>"
    else:
        query_string = request.query_string.decode('utf-8', errors='ignore')
        try:
            result = subprocess.run(
                ["/usr/local/bin/restore-db.sh"],
                capture_output=True,
                text=True,
                env={"QUERY_STRING": query_string},
                check=True,
                encoding='utf-8',
                errors='ignore'
            )
            return Response(result.stdout, mimetype="text/html")
        except subprocess.CalledProcessError as e:
            return Response(f"Error: {e.stderr}", mimetype="text/html", status=500)

@app.route("/upload", methods=["POST"])
def upload_file():
    if 'sqlfile' not in request.files:
        return "<div class='warning-box'><p>❌ Aucun fichier détecté.</p></div>"

    file = request.files['sqlfile']
    if file.filename == '':
        return "<div class='warning-box'><p>❌ Aucun fichier sélectionné.</p></div>"

    file_path = os.path.join(UPLOAD_DIR, file.filename)
    file.save(file_path)

    return redirect(url_for('restore_database',
                           step=5,
                           uploaded_file=file.filename,
                           proxy=request.args.get('proxy', ''),
                           username=request.args.get('username', ''),
                           server=request.args.get('server', ''),
                           db=request.args.get('db', ''),
                           login=request.args.get('login', '')))

@app.route("/sshfs", methods=["GET"])
def mount_sshfs():
    query_string = request.query_string.decode('utf-8', errors='ignore')
    try:
        result = subprocess.run(
            ["/usr/local/bin/mount-teleport.sh"],
            capture_output=True,
            text=True,
            env={"QUERY_STRING": query_string},
            check=True,
            encoding='utf-8',
            errors='ignore'
        )
        return Response(result.stdout, mimetype="text/html")
    except subprocess.CalledProcessError as e:
        return Response(f"Error: {e.stderr}", mimetype="text/html", status=500)

@app.route("/dump", methods=["GET"])
def dump_database():
    query_string = request.query_string.decode('utf-8', errors='ignore')
    try:
        result = subprocess.run(
            ["/usr/local/bin/dump-db.sh"],
            capture_output=True,
            text=True,
            env={"QUERY_STRING": query_string},
            check=True,
            encoding='utf-8',
            errors='ignore'
        )
        return Response(result.stdout, mimetype="text/html")
    except subprocess.CalledProcessError as e:
        return Response(f"Error: {e.stderr}", mimetype="text/html", status=500)

@app.route("/static/uploads/<path:filename>")
def download_upload(filename):
    return send_from_directory(UPLOAD_DIR, filename, as_attachment=True)

@app.route("/static/dumps/<path:filename>")
def download_dump(filename):
    return send_from_directory(DUMP_DIR, filename, as_attachment=True)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
