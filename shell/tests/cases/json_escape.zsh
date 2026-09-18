# _lumen_json_escape / _lumen_json_str_array — the payload sent to the
# companion app. Anything that lands unescaped inside a JSON string (a lone
# backslash, a raw control byte pulled from a filename) makes the whole
# message invalid, and the app drops invalid messages silently.
case_json_escape() {
  local bs=$'\\'   # one backslash, so no literal \uXXXX has to appear below

  assert_eq "${bs}${bs}"  "$(_lumen_json_escape '\')"       'lone backslash'
  assert_eq "${bs}\""     "$(_lumen_json_escape '"')"       'double quote'
  assert_eq "a${bs}tb"    "$(_lumen_json_escape $'a\tb')"   'tab'
  assert_eq "a${bs}nb"    "$(_lumen_json_escape $'a\nb')"   'newline'
  assert_eq "a${bs}rb"    "$(_lumen_json_escape $'a\rb')"   'carriage return'
  assert_eq "a${bs}u0007b" "$(_lumen_json_escape $'a\x07b')" 'bell char'
  assert_eq "x${bs}u001fb" "$(_lumen_json_escape $'x\x1fb')" 'unit separator'
  assert_eq 'clean'       "$(_lumen_json_escape 'clean')"   'clean text untouched'

  # A filename really can contain a newline and a quote; the array literal
  # built from it must parse back to exactly those bytes.
  if (( $+commands[python3] )); then
    local weird=$'weird\nname "q"\tend'
    local arr got
    arr=$(_lumen_json_str_array "$weird")
    got=$(print -r -- "$arr" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0], end="")')
    assert_eq "$weird" "$got" 'filename round-trips through JSON array'
  fi
}
