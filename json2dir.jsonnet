// json2dir evaluator: reads the document, validates all of it (RFC J2D-1 sections 3, 4)
// and returns a POSIX shell script that creates the tree. Run with `jsonnet -S`.
// The launcher puts the document at <tmp>/json2dir-input.bin and passes `-J <tmp>`.
local input = importbin 'json2dir-input.bin';

local fail(msg) = error 'json2dir: ' + msg;
local nul = std.char(0);
local has(s, c) = std.strReplace(s, c, '') != s;

// A byte order mark at the start is ignored, as RFC 8259 permits.
local bytes = if std.length(input) >= 3 && input[0:3] == [239, 187, 191] then input[3:] else input;

// Strict UTF-8: Go's decoder turns every invalid sequence (overlong, surrogate, > U+10FFFF,
// truncated) into U+FFFD, so the round trip only reproduces the input when it is valid.
local text = std.decodeUTF8(bytes);
local utf8Ok = std.encodeUTF8(text) == bytes;

// std.parseJson (Go encoding/json) rejects comments, NaN, trailing commas, control characters
// and trailing data, but silently turns \ud800-style lone surrogates into U+FFFD.
// So: drop escaped backslashes, split at the remaining \u escapes and check the pairing.
local segs = std.split(std.strReplace(text, @'\\', ''), @'\u');
local isHex(s) = std.all([std.member('0123456789abcdefABCDEF', c) for c in std.stringChars(s)]);
// Code unit of the escape that starts segs[k]; only D800-DFFF matters, so others are -1.
local units = std.makeArray(std.length(segs), function(k)
  local s = segs[k];
  if k == 0 || std.length(s) < 4 || (s[0] != 'd' && s[0] != 'D') || !isHex(s[0:4]) then -1
  else std.parseHex(std.asciiLower(s[0:4])));
local nsegs = std.length(segs);
local high(k) = k < nsegs && units[k] >= 55296 && units[k] <= 56319;  // D800-DBFF
local low(k) = k < nsegs && units[k] >= 56320 && units[k] <= 57343;  // DC00-DFFF
// segs[k] == 4 hex digits only means the next \u follows immediately.
local paired(k) = high(k) && low(k + 1) && std.length(segs[k]) == 4;
local surrogatesOk = std.all([
  (!high(k) || paired(k)) && (!low(k) || (k >= 2 && paired(k - 1)))
  for k in std.range(1, nsegs - 1)
]);

local q(s) = "'" + std.strReplace(s, "'", @"'\''") + "'";

// NUL cannot travel in a shell argument, so content is passed as the words between NULs;
// the script writes them joined by NUL bytes using a constant printf format.
local content(s) = std.join('', [' ' + q(part) for part in std.split(s, nul)]);

local checkName(name, p) =
  if name == '' || name == '.' || name == '..' || has(name, '/') || has(name, nul)
  then fail('invalid name ' + std.manifestJson(name) + ' at ' + p)
  else true;

local entry(dir, name, v) =
  local p = dir + '/' + name;
  if !checkName(name, p) then ''
  else if std.isObject(v) then
    '_j2d_dir ' + q(p) + '\n' + tree(p, v)
  else if std.isString(v) then
    '_j2d_file ' + q(p) + content(v) + '\n'
  else if std.isArray(v) then
    if std.length(v) != 2 || !std.isString(v[0]) || !std.isString(v[1]) then
      fail('an array must be ["link", target] or ["script", content] at ' + p)
    else if v[0] == 'script' then
      '_j2d_script ' + q(p) + content(v[1]) + '\n'
    else if v[0] != 'link' then
      fail('unknown array kind ' + std.manifestJson(v[0]) + ' at ' + p)
    // A symlink target cannot contain NUL (RFC section 10).
    else if has(v[1], nul) then
      fail('a link target cannot contain NUL at ' + p)
    else '_j2d_link ' + q(p) + ' ' + q(v[1]) + '\n'
  else
    fail(std.type(v) + ' values are not allowed at ' + p),
// Members in ascending code point order, which equals the UTF-8 byte order of the names.
tree(dir, o) = std.join('', [entry(dir, k, o[k]) for k in std.sort(std.objectFields(o))]);

local helpers = |||
  set -eu
  _j2d_fail() { printf 'json2dir: cannot create %s\n' "$1" >&2; exit 1; }
  # Remove an existing non-directory (a symlink itself, never its target);
  # a real directory in the way of a non-object is an error.
  _j2d_clear() {
    if [ -L "$1" ]; then rm -f -- "$1" || _j2d_fail "$1"
    elif [ -d "$1" ]; then printf 'json2dir: a directory is in the way: %s\n' "$1" >&2; exit 1
    elif [ -e "$1" ]; then rm -f -- "$1" || _j2d_fail "$1"
    fi
  }
  _j2d_dir() {
    if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then rm -f -- "$1" || _j2d_fail "$1"; fi
    if [ ! -d "$1" ]; then mkdir -- "$1" || _j2d_fail "$1"; fi
  }
  # _j2d_file path part...: the content is the parts joined by NUL bytes.
  _j2d_file() {
    _j2d_clear "$1"
    _j2d_path=$1; shift
    {
      printf '%s' "$1"; shift
      for _j2d_part in "$@"; do printf '\000%s' "$_j2d_part"; done
    } > "$_j2d_path" || _j2d_fail "$_j2d_path"
  }
  _j2d_script() { _j2d_file "$@"; chmod a+x -- "$1" || _j2d_fail "$1"; }
  _j2d_link() { _j2d_clear "$1"; ln -s -- "$2" "$1" || _j2d_fail "$1"; }
|||;

if !utf8Ok then fail('input is not valid UTF-8')
else if !surrogatesOk then fail('input contains an unpaired surrogate escape')
else
  local doc = std.parseJson(text);
  if !std.isObject(doc) then fail('the root of the document must be an object')
  else helpers + tree('.', doc)
