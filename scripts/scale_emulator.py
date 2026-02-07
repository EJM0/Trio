import http.server
import socketserver
import json
import random
import socket
from urllib.parse import urlparse, parse_qs
import sys
import threading
import asyncio
import time

# Try importing websockets
try:
    import websockets
except ImportError:
    print("Error: 'websockets' library is required for WebSocket support.")
    print("Run: pip install websockets")
    # Continue without WS or exit? Let's try to run without WS or exit.
    # user requested to implement websocket, so better fail if missing
    sys.exit(1)

# Default port 8080, can be overridden by command line arg
PORT = 8080
if len(sys.argv) > 1:
    PORT = int(sys.argv[1])

WS_PORT = PORT + 1

# Shared state
current_weight = 150.0
connected_clients = set()

def update_weight_loop():
    global current_weight
    while True:
        # Simulate small fluctuations
        change = random.uniform(-0.5, 0.5)
        current_weight = max(0, current_weight + change)
        time.sleep(0.1)

class ScaleHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Override to reduce log spam if needed, or keep for visibility
        sys.stderr.write("%s - - [%s] %s\n" %
                         (self.address_string(),
                          self.log_date_time_string(),
                          format%args))

    def do_GET(self):
        parsed_path = urlparse(self.path)
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()

        if parsed_path.path == '/read':
            response = {"weight": round(current_weight, 2)}
            self.wfile.write(json.dumps(response).encode())
            
        elif parsed_path.path == '/battery':
            # Simulate 75% battery
            response = {"percentage": random.randint(0, 100), "voltage": 3.92}
            self.wfile.write(json.dumps(response).encode())

        elif parsed_path.path == '/tare':
            response = {"status": "tared"}
            self.wfile.write(json.dumps(response).encode())
            print("\n>> Scale Tared")

        elif parsed_path.path == '/calibrate':
            query = parse_qs(parsed_path.query)
            weight = query.get('weight', ['0'])[0]
            response = {"new_factor": 450.5}
            self.wfile.write(json.dumps(response).encode())
            print(f"\n>> Calibrated with reference weight: {weight}")

        else:
            self.send_response(404)

def run_http_server():
    try:
        with socketserver.TCPServer(("0.0.0.0", PORT), ScaleHandler) as httpd:
            httpd.serve_forever()
    except OSError as e:
        print(f"HTTP Server Error: {e}")

async def ws_handler(websocket, path):
    connected_clients.add(websocket)
    try:
        print(f"Client connected: {websocket.remote_address}")
        while True:
            await websocket.send(f"{current_weight:.2f}")
            await asyncio.sleep(0.1)
    except Exception as e:
        print(f"Client disconnected: {e}")
    finally:
        connected_clients.remove(websocket)

async def run_ws_server():
    async with websockets.serve(ws_handler, "0.0.0.0", WS_PORT):
        print(f"WebSocket Server running on port {WS_PORT}")
        await asyncio.Future() # run forever

def get_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # doesn't even have to be reachable
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

local_ip = get_ip()

print(f"Scale Emulator running on ports HTTP:{PORT} WS:{WS_PORT}...")
print(f"Local IP: {local_ip}")
print(f"Endpoints available:")
print(f"  GET http://{local_ip}:{PORT}/read")
print(f"  GET http://localhost:{PORT}/battery")
print(f"  GET http://localhost:{PORT}/tare")
print(f"  GET http://localhost:{PORT}/calibrate?weight=100")
print(f"  WS  ws://{local_ip}:{WS_PORT}")
print("Ctrl+C to stop.")

# Start Weight Updater
threading.Thread(target=update_weight_loop, daemon=True).start()

# Start HTTP Server in separate thread
threading.Thread(target=run_http_server, daemon=True).start()

# Run WebSocket Server in main thread (asyncio)
try:
    asyncio.run(run_ws_server())
except KeyboardInterrupt:
    print("\nStopping emulator.")
except OSError as e:
    print(f"\nError starting WS server: {e}")
