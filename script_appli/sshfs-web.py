from flask import Flask, Response, request, redirect, url_for, render_template_string, send_from_directory
import subprocess
import os
import tempfile

app = Flask(__name__)

# Assurer que le répertoire de stockage existe
os.makedirs('/usr/local/bin/static/dumps', exist_ok=True)

@app.route("/", methods=["GET"])
def index():
    return render_template_string('''
        <html>
        <head>
            <title>Accueil</title>
            <style>
                body { font-family: 'Roboto', sans-serif; margin: 20px; background-color: #f8f9fa; color: #212529; }
                h1 { color: #007bff; margin-bottom: 30px; }
                .button-container { display: flex; flex-direction: column; gap: 15px; max-width: 300px; }
                button { padding: 12px; font-size: 1em; background-color: #007bff; color: white; 
                       border: none; border-radius: 4px; cursor: pointer; }
                button:hover { background-color: #0056b3; }
            </style>
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

@app.route("/restore", methods=["GET"])
def restore_database():
    query_string = request.query_string.decode('utf-8')
    result = subprocess.run(
        ["/usr/local/bin/restore-db.sh"],
        capture_output=True,
        text=True,
        env={"QUERY_STRING": query_string}
    )
    return Response(result.stdout, mimetype="text/html")

@app.route("/upload", methods=["POST"])
def upload_file():
    if 'sqlfile' not in request.files:
        return redirect(request.url)
    
    file = request.files['sqlfile']
    if file.filename == '':
        return redirect(request.url)
    
    # Sauvegarder le fichier
    filename = file.filename
    file_path = os.path.join('/usr/local/bin/static/dumps', filename)
    file.save(file_path)
    
    # Rediriger vers restore avec le nom du fichier en paramètre
    return redirect(url_for('restore_database', 
                           step=5, 
                           uploaded_file=filename,
                           proxy=request.args.get('proxy', ''),
                           username=request.args.get('username', ''),
                           server=request.args.get('server', ''),
                           db=request.args.get('db', ''),
                           login=request.args.get('login', '')))

@app.route("/sshfs", methods=["GET"])
def mount_sshfs():
    query_string = request.query_string.decode('utf-8')
    result = subprocess.run(
        ["/usr/local/bin/mount-teleport.sh"],
        capture_output=True,
        text=True,
        env={"QUERY_STRING": query_string}
    )
    return Response(result.stdout, mimetype="text/html")

@app.route("/dump", methods=["GET"])
def dump_database():
    query_string = request.query_string.decode('utf-8')
    result = subprocess.run(
        ["/usr/local/bin/dump-db.sh"],
        capture_output=True,
        text=True,
        env={"QUERY_STRING": query_string}
    )
    return Response(result.stdout, mimetype="text/html")

@app.route('/static/dumps/<path:filename>')
def download_dump(filename):
    return send_from_directory('/usr/local/bin/static/dumps', filename, as_attachment=True)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
