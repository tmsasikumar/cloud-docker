from flask import Flask, jsonify, render_template
from flask_cors import CORS

app = Flask(__name__, template_folder=".")
CORS(app)


@app.route('/')
def index():
    return render_template('index.html', title='Home')


@app.route('/about')
def about():
    return render_template('index.html', title='About')


@app.route('/api/data', methods=['GET'])
def get_data():
    return jsonify({'message': 'Hello, World!'})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)