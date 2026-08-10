class_name TownHallApi
extends RefCounted


static func base_url() -> String:
	var configured := str(RunMode.town_hall_api_base).strip_edges()
	return configured.trim_suffix("/")


static func list_url() -> String:
	return "%s/api/towns" % base_url()


static func town_url(town_id: String) -> String:
	return "%s/api/towns/%s" % [base_url(), town_id.uri_encode()]


static func json_headers(edit_token := "") -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if not edit_token.is_empty():
		headers.append("X-Town-Edit-Token: %s" % edit_token)
	return headers


static func parse_json_body(body: PackedByteArray) -> Dictionary:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


static func result_error(result: int, response_code: int, body: PackedByteArray) -> String:
	if result != HTTPRequest.RESULT_SUCCESS:
		return "无法连接小镇服务器（错误 %d）" % result
	var parsed := parse_json_body(body)
	if response_code < 200 or response_code >= 300:
		return str(parsed.get("error", "服务器返回 HTTP %d" % response_code))
	return ""
