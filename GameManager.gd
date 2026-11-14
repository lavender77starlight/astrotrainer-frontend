extends Node

# ==========================================
# SIGNALS (UI scenes can connect to these)
# ==========================================
signal telemetry_updated
signal mission_data_loaded(data: Dictionary)
signal auth_completed(success: bool, message: String)
signal event_resolved(result: Dictionary)
signal pressure_adjusted(result: Dictionary)
signal mars_day_resolved(result: Dictionary)
signal aria_replied(dialogue: String)
signal choice_resolved(result: Dictionary)
signal finale_resolved(result: Dictionary)

# ==========================================
# SERVER & SESSION CONFIG
# ==========================================
var use_mock_backend: bool = false
const BASE_URL: String = "http://localhost:3000"
const SESSION_PATH: String = "user://session.cfg"

var auth_token: String = ""
var username: String = "Cadet"
var is_guest: bool = true

# ==========================================
# PRIMARY HUD TELEMETRY & RUN STATE
# ==========================================
var oxygen_level: float = 100.0
var suit_power: float = 100.0
var speed: float = 100.0
var selected_suit: String = "standard"

var seen_hazard_ids: Array[String] = []
var active_landing_zone: Dictionary = {}
var mission_data: Dictionary = {}

# ARIA LLM outputs & named 9-meter spacecraft telemetry
var aria_dialogue: String = ""
var detailed_meters: Dictionary = {
	"o2Percent": 100.0,
	"waterPercent": 100.0,
	"foodPercent": 100.0,
	"powerPercent": 100.0,
	"shieldPercent": 100.0,
	"suitIntegrityPercent": 100.0,
	"thermalCelsius": 20.0,
	"massKg": 5000.0,
	"fuelKg": 1500.0
}

func _ready() -> void:
	load_session()
	if not is_guest and auth_token != "":
		verify_session()

# ==========================================
# SESSION PERSISTENCE (JWT + GUEST MODE)
# ==========================================
func save_session() -> void:
	var config := ConfigFile.new()
	config.set_value("auth", "token", auth_token)
	config.set_value("auth", "username", username)
	config.set_value("auth", "is_guest", is_guest)
	config.save(SESSION_PATH)

func load_session() -> void:
	var config := ConfigFile.new()
	if config.load(SESSION_PATH) == OK:
		auth_token = str(config.get_value("auth", "token", ""))
		username = str(config.get_value("auth", "username", "Cadet"))
		is_guest = bool(config.get_value("auth", "is_guest", true))

func play_as_guest(guest_name: String = "Guest Cadet") -> void:
	auth_token = ""
	username = guest_name
	is_guest = true
	save_session()
	auth_completed.emit(true, "Playing in Guest Mode")

func logout() -> void:
	auth_token = ""
	username = "Cadet"
	is_guest = true
	save_session()

func reset_run_state() -> void:
	seen_hazard_ids.clear()
	oxygen_level = 100.0
	suit_power = 100.0
	speed = 100.0
	aria_dialogue = ""
	detailed_meters = {
		"o2Percent": 100.0,
		"waterPercent": 100.0,
		"foodPercent": 100.0,
		"powerPercent": 100.0,
		"shieldPercent": 100.0,
		"suitIntegrityPercent": 100.0,
		"thermalCelsius": 20.0,
		"massKg": 5000.0,
		"fuelKg": 1500.0
	}
	telemetry_updated.emit()

# ==========================================
# AUTHENTICATION ENDPOINTS
# ==========================================
func signup(user_input: String, password_input: String) -> void:
	var body := {"username": user_input, "password": password_input}
	_send_request("/api/auth/signup", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if (code == 200 or code == 201) and data.has("token"):
			auth_token = str(data["token"])
			username = str(data.get("username", user_input))
			is_guest = false
			save_session()
			auth_completed.emit(true, str(data.get("message", "Signup successful")))
		else:
			auth_completed.emit(false, str(data.get("error", "Signup failed")))
	)

func login(user_input: String, password_input: String) -> void:
	var body := {"username": user_input, "password": password_input}
	_send_request("/api/auth/login", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200 and data.has("token"):
			auth_token = str(data["token"])
			username = str(data.get("username", user_input))
			is_guest = false
			save_session()
			auth_completed.emit(true, str(data.get("message", "Login successful")))
		else:
			auth_completed.emit(false, str(data.get("error", "Invalid username or password")))
	)

func verify_session() -> void:
	if auth_token == "":
		return
	_send_request("/api/auth/me", HTTPClient.METHOD_GET, {}, func(code: int, data: Dictionary):
		if code == 200 and bool(data.get("valid", false)):
			username = str(data.get("username", username))
			is_guest = false
			auth_completed.emit(true, "Session restored")
		else:
			logout()
			auth_completed.emit(false, "Session expired")
	)

# ==========================================
# GAMEPLAY, NASA & ARIA LLM ENDPOINTS
# ==========================================
func fetch_mission_data() -> void:
	if use_mock_backend:
		var mock := get_mock_mars_data()
		mission_data = mock
		if mock.has("selectedLandingZone") and mock["selectedLandingZone"] is Dictionary:
			active_landing_zone = mock["selectedLandingZone"]
		mission_data_loaded.emit(mission_data)
		return

	_send_request("/api/mission-data", HTTPClient.METHOD_GET, {}, func(code: int, data: Dictionary):
		if code == 200 and not data.is_empty():
			mission_data = data
			if data.has("selectedLandingZone") and data["selectedLandingZone"] is Dictionary:
				active_landing_zone = data["selectedLandingZone"]
		else:
			mission_data = get_mock_mars_data()
		mission_data_loaded.emit(mission_data)
	)

func ask_aria(player_message: String, stage_key: String = "level2_transit", decision: String = "") -> void:
	if use_mock_backend:
		aria_dialogue = "ARIA (Offline): Received '" + player_message + "' (" + stage_key + ")."
		telemetry_updated.emit()
		aria_replied.emit(aria_dialogue)
		return

	var body := {
		"message": player_message,
		"stageKey": stage_key,
		"decision": decision if decision != "" else player_message,
		"telemetry": {
			"oxygenLevel": oxygen_level,
			"suitPower": suit_power,
			"speed": speed
		},
		"detailedMeters": detailed_meters
	}
	_send_request("/api/aria/chat", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200 and data.has("ariaDialogue"):
			apply_aria_payload(data)
			aria_replied.emit(aria_dialogue)
	)

func trigger_event(stage_key: String = "level2_transit", decision: String = "") -> void:
	var body := {
		"stageKey": stage_key,
		"currentMeters": _get_meters_array(),
		"seenHazardIds": seen_hazard_ids,
		"landingZoneId": active_landing_zone.get("id", null),
		"decision": decision if decision != "" else null
	}
	_send_request("/api/event", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200:
			if data.has("hazardTriggered") and data["hazardTriggered"] is Dictionary and data["hazardTriggered"].has("id"):
				var hid := str(data["hazardTriggered"]["id"])
				if not seen_hazard_ids.has(hid):
					seen_hazard_ids.append(hid)
			elif data.has("hazard") and data["hazard"] is Dictionary and data["hazard"].has("id"):
				var hid := str(data["hazard"]["id"])
				if not seen_hazard_ids.has(hid):
					seen_hazard_ids.append(hid)
			apply_aria_payload(data)
			event_resolved.emit(data)
	)

func submit_choice(scene_id: String, choice_letter: String) -> void:
	if use_mock_backend:
		var mock_res := {
			"sceneId": scene_id,
			"choice": choice_letter,
			"lessonCard": "Every spaceflight choice balances mass, power, and survival margins.",
			"ariaDialogue": "ARIA (Offline): Choice " + choice_letter + " recorded for Scene " + scene_id + "."
		}
		apply_aria_payload(mock_res)
		choice_resolved.emit(mock_res)
		return

	var body := {
		"sceneId": scene_id,
		"choice": choice_letter,
		"currentMeters": _get_meters_array()
	}
	_send_request("/api/choice", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200:
			if data.has("selectedSuit") and data["selectedSuit"] != null:
				selected_suit = str(data["selectedSuit"])
			apply_aria_payload(data)
			choice_resolved.emit(data)
	)

func submit_finale(priorities: Array[String]) -> void:
	if use_mock_backend:
		var mock_res := {
			"stars": 3,
			"endingTitle": "Star Ending",
			"sproutStatus": "Blooming",
			"ariaDialogue": "ARIA (Offline): Star Ending achieved!"
		}
		apply_aria_payload(mock_res)
		finale_resolved.emit(mock_res)
		return

	var body := {
		"priorities": priorities,
		"currentMeters": _get_meters_array()
	}
	_send_request("/api/finale", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200:
			apply_aria_payload(data)
			finale_resolved.emit(data)
	)

func adjust_pressure(stage_key: String, target_pressure_kpa: float) -> void:
	var body := {
		"stageKey": stage_key,
		"targetPressureKpa": target_pressure_kpa,
		"currentMeters": _get_meters_array()
	}
	_send_request("/api/pressure/adjust", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200:
			apply_aria_payload(data)
			pressure_adjusted.emit(data)
	)

func survive_mars_day(day_number: int, strategy_id: String = "rehydratable") -> void:
	var body := {
		"dayNumber": day_number,
		"strategyId": strategy_id,
		"landingZoneId": active_landing_zone.get("id", "jezero_crater"),
		"currentMeters": _get_meters_array()
	}
	_send_request("/api/mars/survive-day", HTTPClient.METHOD_POST, body, func(code: int, data: Dictionary):
		if code == 200:
			apply_aria_payload(data)
			mars_day_resolved.emit(data)
	)

# ==========================================
# PAYLOAD PARSING & MOCK FALLBACK
# ==========================================
func _get_meters_array() -> Array[float]:
	return [
		float(detailed_meters.get("suitIntegrityPercent", 100.0)) / 100.0,
		float(detailed_meters.get("o2Percent", oxygen_level)),
		float(detailed_meters.get("waterPercent", 100.0)),
		float(detailed_meters.get("foodPercent", 100.0)),
		float(detailed_meters.get("powerPercent", suit_power)),
		float(detailed_meters.get("shieldPercent", 100.0)),
		float(detailed_meters.get("thermalCelsius", 20.0)),
		float(detailed_meters.get("massKg", 5000.0)),
		float(detailed_meters.get("fuelKg", 1500.0))
	]

func get_mock_mars_data() -> Dictionary:
	var paths := ["res://shared/mockdata.json", "res://shared/marsData.json"]
	for path in paths:
		if FileAccess.file_exists(path):
			var file_text: String = FileAccess.get_file_as_string(path)
			var parsed = JSON.parse_string(file_text)
			if parsed is Dictionary:
				return parsed
	return {}

func apply_aria_payload(payload: Dictionary) -> void:
	if payload.has("ariaDialogue"):
		aria_dialogue = str(payload["ariaDialogue"])

	var has_new_telemetry := false

	if payload.has("updatedTelemetry") and payload["updatedTelemetry"] is Dictionary:
		var t: Dictionary = payload["updatedTelemetry"]
		oxygen_level = float(t.get("oxygenLevel", oxygen_level))
		suit_power = float(t.get("suitPower", suit_power))
		speed = float(t.get("speed", speed))
		detailed_meters["o2Percent"] = oxygen_level
		detailed_meters["powerPercent"] = suit_power
		has_new_telemetry = true

	if payload.has("detailedMeters") and payload["detailedMeters"] is Dictionary:
		detailed_meters.merge(payload["detailedMeters"], true)
		oxygen_level = float(detailed_meters.get("o2Percent", oxygen_level))
		suit_power = float(detailed_meters.get("powerPercent", suit_power))
		has_new_telemetry = true

	if has_new_telemetry:
		telemetry_updated.emit()

# ==========================================
# INTERNAL HTTP HELPER
# ==========================================
func _send_request(endpoint: String, method: int, body: Dictionary, callback: Callable) -> void:
	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray(["Content-Type: application/json"])
	if auth_token != "":
		headers.append("Authorization: Bearer " + auth_token)

	var json_body := ""
	if method != HTTPClient.METHOD_GET and not body.is_empty():
		json_body = JSON.stringify(body)

	http.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, raw_body: PackedByteArray):
		http.queue_free()
		var text := raw_body.get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		var data: Dictionary = parsed if parsed is Dictionary else {}
		callback.call(response_code, data)
	)

	var err := http.request(BASE_URL + endpoint, headers, method, json_body)
	if err != OK:
		http.queue_free()
		callback.call(0, {"error": "Network connection error"})