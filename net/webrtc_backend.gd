class_name WebRTCBackend
extends NetworkBackend
## Backend WebRTC: salas con CÓDIGO para la versión web (navegador).
##
## Los navegadores se conectan entre sí directamente (WebRTC, host autoritativo = peer 1, igual que ENet).
## Para ENCONTRARSE usan el servidor público y gratuito de PeerJS (0.peerjs.com) solo como "buzón" de
## señalización: por él pasan los mensajes para abrir la conexión, nunca la partida.
##
## Ids en PeerJS: el host es ID_PREFIX + código ("maxijuegos-v1-K7QF"); cada cliente, ese id + un sufijo
## aleatorio. Protocolo (campo `payload` de los mensajes OFFER/ANSWER/CANDIDATE de PeerJS):
##   c→h hello {id}                 el cliente pide entrar con su peer id de Godot (aleatorio)
##   h→c sdp {type:"offer", sdp}    el host abre la conexión WebRTC con ese cliente
##   c→h sdp {type:"answer", sdp}
##   ambos ice {mid, index, name}   candidatos de red
##   h→c reject {reason}            sala llena o id repetido
## Si el host no existe, PeerJS devuelve EXPIRE al cliente → "no existe esa sala".

const SIGNAL_PATH := "/peerjs?key=peerjs&id=%s&token=%s&version=1.5.4"
const ID_PREFIX := "maxijuegos-v1-"
## Sin I/O/0/1 para que el código se lea y dicte sin dudas.
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LENGTH := 4
const ICE_SERVERS := [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]}]
const HEARTBEAT_S := 5.0
## (cliente) Tiempo máximo hasta conectar con el host.
const JOIN_TIMEOUT_S := 20.0
## (host) Una conexión que no termina de abrirse en este tiempo se descarta.
const PENDING_TIMEOUT_S := 25.0
const RECONNECT_S := 3.0

## Servidor PeerJS. Las pruebas usan uno local (DevCli --signal=ws://localhost:9000).
var signal_server: String = "wss://0.peerjs.com"

var _ws: WebSocketPeer
var _rtc: WebRTCMultiplayerPeer
var _is_host := false
var _code := ""
var _my_sig_id := ""
var _host_sig_id := ""
var _open := false
var _heartbeat := 0.0
var _reconnect := 0.0
var _elapsed := 0.0
var _max_clients := 7
var _local_peer_id := 0
var _connected := false
var _outbox: Array[Dictionary] = []
## (host) id PeerJS del cliente -> peer id de Godot, y peer id -> segundos esperando a conectar.
var _sig_to_peer: Dictionary = {}
var _pending: Dictionary = {}

func get_backend_name() -> String:
	return "Sala con código"

func get_join_hint() -> String:
	return _code if _is_host else ""

func get_join_hint_label() -> String:
	return "Código de sala"

## Normaliza lo que escribe el jugador: mayúsculas, sin espacios ni guiones; "" si no parece un código.
static func normalize_code(text: String) -> String:
	var code := ""
	for ch in text.to_upper():
		if CODE_CHARS.contains(ch):
			code += ch
	return code if code.length() == CODE_LENGTH else ""

func create_host(_port: int, max_clients: int) -> MultiplayerPeer:
	close()
	_is_host = true
	_max_clients = max_clients
	_rtc = WebRTCMultiplayerPeer.new()
	if _rtc.create_server() != OK:
		push_error("WebRTCBackend: no se pudo crear el servidor")
		return null
	_local_peer_id = 1
	_code = _random_code()
	_connect_signaling(ID_PREFIX + _code)
	return _rtc

func create_client(address: String, _port: int) -> MultiplayerPeer:
	close()
	var code := normalize_code(address)
	if code.is_empty():
		return null
	_is_host = false
	_code = code
	_host_sig_id = ID_PREFIX + code
	_rtc = WebRTCMultiplayerPeer.new()
	_local_peer_id = randi_range(2, 0x7fffffff)
	if _rtc.create_client(_local_peer_id) != OK:
		push_error("WebRTCBackend: no se pudo crear el cliente")
		return null
	_connect_signaling("%s-%s" % [_host_sig_id, _random_token(8)])
	_send({"type": "OFFER", "dst": _host_sig_id, "payload": {"op": "hello", "id": _local_peer_id}})
	return _rtc

func poll(delta: float) -> void:
	if _rtc == null:
		return
	_elapsed += delta
	if _ws != null:
		_ws.poll()
		match _ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while _ws.get_available_packet_count() > 0:
					_on_signal(_ws.get_packet().get_string_from_utf8())
				_heartbeat -= delta
				if _open and _heartbeat <= 0.0:
					_heartbeat = HEARTBEAT_S
					_ws.send_text(JSON.stringify({"type": "HEARTBEAT"}))
			WebSocketPeer.STATE_CLOSED:
				_ws = null
				_open = false
				if _is_host:
					_reconnect = RECONNECT_S   # el host sigue aceptando gente: se reconecta
				elif not _connected:
					_fail("No se pudo contactar con el servidor de salas.")
	elif _is_host and _reconnect > 0.0:
		_reconnect -= delta
		if _reconnect <= 0.0:
			_connect_signaling(ID_PREFIX + _code)
	if _is_host:
		_expire_pending(delta)
	elif not _connected:
		if _rtc.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_connected = true
			_close_signaling(false)   # ya estamos dentro: la partida no usa la señalización
		elif _elapsed > JOIN_TIMEOUT_S:
			_fail("No se pudo conectar con la sala.")

func close() -> void:
	_close_signaling()
	if _rtc != null:
		_rtc.close()
	_rtc = null
	_code = ""
	_open = false
	_connected = false
	_elapsed = 0.0
	_reconnect = 0.0
	_outbox.clear()
	_sig_to_peer.clear()
	_pending.clear()

# ----------------------------------------------------------------------------
# Señalización (PeerJS)
# ----------------------------------------------------------------------------

func _connect_signaling(sig_id: String) -> void:
	_my_sig_id = sig_id
	_open = false
	_ws = WebSocketPeer.new()
	if _ws.connect_to_url(signal_server + SIGNAL_PATH % [sig_id, _random_token(12)]) != OK:
		_ws = null
		if not _is_host:
			_fail("No se pudo contactar con el servidor de salas.")

## `leave`: (cliente) avisa al host de que dejamos de intentarlo, para que descarte la conexión a medias.
func _close_signaling(leave: bool = true) -> void:
	if _ws != null:
		if leave and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and not _is_host and not _host_sig_id.is_empty():
			_ws.send_text(JSON.stringify({"type": "LEAVE", "dst": _host_sig_id}))
		_ws.close()
	_ws = null
	_open = false

func _send(msg: Dictionary) -> void:
	if _open and _ws != null:
		_ws.send_text(JSON.stringify(msg))
	else:
		_outbox.append(msg)

func _on_signal(text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if not msg is Dictionary:
		return
	var src := String(msg.get("src", ""))
	var payload: Variant = msg.get("payload", {})
	match String(msg.get("type", "")):
		"OPEN":
			_open = true
			_heartbeat = HEARTBEAT_S
			for m in _outbox:
				_ws.send_text(JSON.stringify(m))
			_outbox.clear()
			if _is_host:
				DevCli.log_event("room_open code=%s" % _code)
		"ID-TAKEN":
			_close_signaling()
			if _is_host:
				# Ese código ya lo usa otra sala: se sortea otro.
				_code = _random_code()
				hint_changed.emit()
				_connect_signaling(ID_PREFIX + _code)
			else:
				_connect_signaling("%s-%s" % [_host_sig_id, _random_token(8)])
		"EXPIRE":
			if not _is_host and src == _host_sig_id:
				_fail("No existe ninguna sala con el código %s." % _code)
		"ERROR", "INVALID-KEY":
			push_warning("WebRTCBackend: error de señalización: %s" % text)
		"LEAVE":
			if _is_host:
				_drop_pending_sig(src)
		"OFFER", "ANSWER", "CANDIDATE":
			if payload is Dictionary:
				if _is_host:
					_host_message(src, payload)
				else:
					_client_message(src, payload)

# ----------------------------------------------------------------------------
# Host
# ----------------------------------------------------------------------------

func _host_message(src: String, payload: Dictionary) -> void:
	if not src.begins_with(ID_PREFIX + _code + "-"):
		return
	match String(payload.get("op", "")):
		"hello":
			var peer_id := int(payload.get("id", 0))
			if _sig_to_peer.has(src):
				return
			if peer_id < 2 or _rtc.has_peer(peer_id):
				_send({"type": "OFFER", "dst": src, "payload": {"op": "reject", "reason": "id"}})
				return
			if _rtc.get_peers().size() >= _max_clients:
				_send({"type": "OFFER", "dst": src, "payload": {"op": "reject", "reason": "full"}})
				return
			var conn := _make_connection(src)
			if conn == null:
				return
			_sig_to_peer[src] = peer_id
			_pending[peer_id] = 0.0
			_rtc.add_peer(conn, peer_id)
			conn.create_offer()
		"sdp":
			var peer_id: int = _sig_to_peer.get(src, 0)
			if peer_id != 0 and _rtc.has_peer(peer_id):
				_peer_connection(peer_id).set_remote_description(String(payload.get("type", "")), String(payload.get("sdp", "")))
		"ice":
			var peer_id: int = _sig_to_peer.get(src, 0)
			if peer_id != 0 and _rtc.has_peer(peer_id):
				_add_ice(_peer_connection(peer_id), payload)

func _expire_pending(delta: float) -> void:
	for peer_id in _pending.keys():
		if not _rtc.has_peer(peer_id):
			_pending.erase(peer_id)
		elif _is_peer_connected(peer_id):
			_pending.erase(peer_id)   # conectado: ya lo gestiona el MultiplayerAPI
		else:
			_pending[peer_id] += delta
			if _pending[peer_id] > PENDING_TIMEOUT_S:
				_remove_pending(peer_id)

func _drop_pending_sig(src: String) -> void:
	var peer_id: int = _sig_to_peer.get(src, 0)
	if _pending.has(peer_id) and not _is_peer_connected(peer_id):
		_remove_pending(peer_id)

func _is_peer_connected(peer_id: int) -> bool:
	return _rtc.has_peer(peer_id) and bool(_rtc.get_peer(peer_id).get("connected", false))

func _remove_pending(peer_id: int) -> void:
	_pending.erase(peer_id)
	if _rtc.has_peer(peer_id):
		_rtc.remove_peer(peer_id)
	for src in _sig_to_peer.keys():
		if _sig_to_peer[src] == peer_id:
			_sig_to_peer.erase(src)

# ----------------------------------------------------------------------------
# Cliente
# ----------------------------------------------------------------------------

func _client_message(src: String, payload: Dictionary) -> void:
	if src != _host_sig_id:
		return
	match String(payload.get("op", "")):
		"sdp":
			if _rtc.has_peer(1):
				return
			var conn := _make_connection(src)
			if conn == null:
				_fail("Este navegador no permite conexiones WebRTC.")
				return
			_rtc.add_peer(conn, 1)
			conn.set_remote_description(String(payload.get("type", "")), String(payload.get("sdp", "")))
		"ice":
			if _rtc.has_peer(1):
				_add_ice(_peer_connection(1), payload)
		"reject":
			_fail("La sala está llena." if payload.get("reason", "") == "full" else "No se pudo entrar en la sala.")

## Corta el intento de unirse: el MultiplayerAPI ve el peer cerrado y emite connection_failed.
func _fail(reason: String) -> void:
	if _is_host or _rtc == null:
		return
	push_warning("WebRTCBackend: %s" % reason)
	DevCli.log_event("join_failed: %s" % reason)
	failure_reason = reason
	_close_signaling()
	_rtc.close()

# ----------------------------------------------------------------------------
# WebRTC
# ----------------------------------------------------------------------------

func _make_connection(remote_sig_id: String) -> WebRTCPeerConnection:
	var conn := WebRTCPeerConnection.new()
	if conn.initialize({"iceServers": ICE_SERVERS}) != OK:
		push_error("WebRTCBackend: WebRTC no disponible")
		return null
	conn.session_description_created.connect(func(type: String, sdp: String) -> void:
		conn.set_local_description(type, sdp)
		_send({"type": "OFFER" if type == "offer" else "ANSWER", "dst": remote_sig_id,
				"payload": {"op": "sdp", "type": type, "sdp": sdp}}))
	conn.ice_candidate_created.connect(func(mid: String, index: int, cand: String) -> void:
		_send({"type": "CANDIDATE", "dst": remote_sig_id,
				"payload": {"op": "ice", "mid": mid, "index": index, "name": cand}}))
	return conn

func _peer_connection(peer_id: int) -> WebRTCPeerConnection:
	return _rtc.get_peer(peer_id)["connection"]

func _add_ice(conn: WebRTCPeerConnection, payload: Dictionary) -> void:
	conn.add_ice_candidate(String(payload.get("mid", "")), int(payload.get("index", 0)), String(payload.get("name", "")))

## (web) Enlace que abre el juego directamente en esta sala: ...?sala=K7QF
static func share_link(code: String) -> String:
	if not OS.has_feature("web"):
		return code
	var base := String(JavaScriptBridge.eval("location.origin + location.pathname", true))
	return "%s?sala=%s" % [base, code]

## (web) Código de sala que trae la dirección de la página (?sala=K7QF), o "".
static func code_from_url() -> String:
	if not OS.has_feature("web"):
		return ""
	var raw: Variant = JavaScriptBridge.eval("new URLSearchParams(location.search).get('sala') || ''", true)
	return normalize_code(String(raw)) if raw is String else ""

static func _random_code() -> String:
	var code := ""
	for i in CODE_LENGTH:
		code += CODE_CHARS[randi() % CODE_CHARS.length()]
	return code

static func _random_token(length: int) -> String:
	var chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	var token := ""
	for i in length:
		token += chars[randi() % chars.length()]
	return token
