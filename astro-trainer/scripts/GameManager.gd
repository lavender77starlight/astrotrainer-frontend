extends Node

# Keep true for offline testing; flip to false once Render backend URL is live
var use_mock_backend: bool = true
const BASE_URL: String = "http://localhost:5000"

# Shared player telemetry across Level 0 -> 1 -> 2 -> 3
var oxygen_level: float = 100.0
var suit_power: float = 100.0
var speed: float = 100.0
var selected_suit: String = "standard"

func get_mock_data() -> Dictionary:
	var file_text = FileAccess.get_file_as_string("res://shared/mockdata.json")
	var parsed = JSON.parse_string(file_text)
	if parsed != null:
		return parsed
	return {}