#!/bin/bash

# echo "create table items (id,name)"|sqlite3 database
# curl --location --request PUT 'localhost:8080/items' --data-raw '{"name":"MyItem"}' 2>/dev/null | jq
# curl --location --request GET 'localhost:8080/items/xxx' 2>/dev/null | jq
# curl --location --request GET 'localhost:8080/items' 2>/dev/null | jq
# curl --location --request DELETE 'localhost:8080/items' 2>/dev/null | jq

debug() {
  [ "$verbose" == 1 ] && echo -e "$@" >&2
}

quit() {
  rm -rf "$(dirname "$response_fifo")"
  exit 0
}
trap quit SIGINT

usage() {
  cat<<EOF
usage: $0 <options>
flags:
  -h            --help            display this help message
  -v            --verbose         verbose mode
  -p [num]      --port [num]      port to listen to. Defaults to 8080.

EOF
}

prepare_response_fifo() {
  response="$(mktemp -d)/response.fifo"
  mkfifo "$response"
  echo "$response"
}

verbose=0
port=8080
while [ -n "$1" ]; do
  case "$1" in
    -h|--help    ) shift; usage; exit 0 ;;
    -v|--verbose ) shift; verbose=1 ;;
    -p|--port    ) shift; port="$1"; shift ;;
    *            ) shift; echo "Unknown option $1"; exit 1 ;;
  esac
done

echo "Listening on port $port"
response_fifo="$(prepare_response_fifo)"

url_decode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

parse_query_params() {
  local query_string="${1#"?"}"
  declare -A query_params
  debug "# query string: $query_string"

  echo '('
  IFS='&' read -ra params <<< "$query_string"
  for param in "${params[@]}"; do
    IFS='=' read -ra param <<< "$param"
    debug "# key: ${param[0]}; value: ${param[1]}"
    echo "[${param[0]}]=${param[1]}"
  done
  echo ')'
}

build_ok() { echo "200$1"; }
build_created() { echo "201$1"; }
build_no_content() { echo "204"; }
build_bad_request() { echo "400$1"; }
build_not_found() { echo "404$1"; }
build_method_not_allowed() { echo "405${1:-Method Not Allowed}"; }

get_index() {
  declare -A query_params="$(parse_query_params "$1")"

  [ -z "${query_params[what]}" ] && build_bad_request "Missing 'what' parameter" && return
  [ -z "${query_params[who]}" ] && build_bad_request "Missing 'who' parameter" && return

  build_ok "$(url_decode "${query_params[what]}"), $(url_decode "${query_params[who]}")"
}

put_items() {
  local name
  local id

  name="$(echo "$2" | jq --raw-output '.name')"
  [ -z "$name" ] && build_bad_request "Missing 'name' attribute" && return

  id="$(uuidgen)"

  echo "insert into items values ('$id','$name')" | sqlite3 database

  build_created "{\"uuid\":\"$id\",\"name\":\"$name\"}"
}

get_item() {
  result="$(echo "select '{\"id\":\"'||id||'\",\"name\":\"'||name||'\"}' from items where id='$1'" | sqlite3 database)"
  [ -z "$result" ] && build_not_found "{\"error\":\"not found\"}" && return
  build_ok "$result"
}

get_items() {
  result="$(echo "select '['||group_concat('{\"id\":\"'||id||'\",\"name\":\"'||name||'\"}',',')||']' from items" | sqlite3 database)"
  build_ok "${result:-"[]"}"
}

delete_items() {
  echo "delete from items" | sqlite3 database
  build_no_content
}

handle_request() {
  debug "\nready."
  readonly HEADLINE_REGEX='(.*?)\s(.*?)\shttp.*?'
  readonly CONTENT_LENGTH_REGEX='content-length:\s+(.*?)'
  local request=''
  local content_length=''
  local request_body=''
  local line; while IFS= read -r line; do
    debug "> $line"
    line="$(echo "$line" | tr -d '\r\n')"
    [ -z "$line" ] && break

    [[ "${line,,}" =~ $HEADLINE_REGEX ]] && readonly request=$(echo "$line" | sed -E "s/$HEADLINE_REGEX/\1 \2/I")
    [[ "${line,,}" =~ $CONTENT_LENGTH_REGEX ]] && readonly content_length=$(echo "$line" | sed -E "s/$CONTENT_LENGTH_REGEX/\1/I")
  done

  [ -n "$content_length" ] && read -r -N"$content_length" -t1 request_body
  readonly request_body

  debug "# content-length: $content_length"
  debug "# $request_body"

  local response
  case "$request" in
    "GET /"|"GET /?"* ) readonly response="$(get_index "${request#"GET /"}")" ;;
    *" /"             ) readonly response="$(build_method_not_allowed)" ;;
    "PUT /items"      ) readonly response="$(put_items "${request#"PUT /items"}" "$request_body")" ;;
    "DELETE /items"   ) readonly response="$(delete_items "${request#"DELETE /items"}")" ;;
    "GET /items"      ) readonly response="$(get_items "${request#"GET /items"}")" ;;
    "GET /items/"*    ) readonly response="$(get_item "${request#"GET /items/"}")" ;;
    *" /items"*       ) readonly response="$(build_method_not_allowed "Method Not Allowed")" ;;
    *                 ) readonly response="$(build_not_found "Not Found")" ;;
  esac

  echo -en "HTTP/1.1 ${response:0:3}\r\n\r\n${response:3:${#response}}" > "$response_fifo"
}

while true; do
  cat "$response_fifo" | nc -lN "$port" | handle_request
done