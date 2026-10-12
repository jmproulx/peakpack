# json_flat.awk - flatten a JSON document into "path<TAB>value" lines (POSIX/BSD awk, macOS base).
# Part of the PeakPack for Mac test kit. MIT licence.
#
#   awk -f json_flat.awk file.json
#   {"a":{"b":[1,"x"]}}  ->  a.b.0<TAB>1   a.b.1<TAB>x   a.b._count<TAB>2
#
# Strings are unescaped (\n is printed as the two characters \n, tabs become spaces,
# \uXXXX becomes "?"). Literals (numbers, true, false, null) are printed as written.
# Exit 2 with "JSONERR" on stderr when the input is not valid enough to walk.

function jerr(m) { print "JSONERR\t" m " (at byte " pos ")" > "/dev/stderr"; failed = 1; exit 2 }
function ws() { while (pos <= n && index(" \t\r\n", substr(s, pos, 1)) > 0) pos++ }
function join(p, k) { return (p == "") ? k : p "." k }
function emit(p, v) { gsub(/\n/, "\\n", v); gsub(/\t/, " ", v); gsub(/\r/, "", v); print p "\t" v }

function value(path,   c) {
    ws(); c = substr(s, pos, 1)
    if (c == "{") obj(path)
    else if (c == "[") arr(path)
    else if (c == "\"") emit(path, str())
    else lit(path)
}
function obj(path,   k, c) {
    pos++; ws()
    if (substr(s, pos, 1) == "}") { pos++; return }
    while (1) {
        ws()
        if (substr(s, pos, 1) != "\"") jerr("object key expected")
        k = str(); ws()
        if (substr(s, pos, 1) != ":") jerr("':' expected")
        pos++
        value(join(path, k)); ws()
        c = substr(s, pos, 1)
        if (c == ",") { pos++; continue }
        if (c == "}") { pos++; return }
        jerr("',' or '}' expected")
    }
}
function arr(path,   i, c) {
    pos++; i = 0; ws()
    if (substr(s, pos, 1) == "]") { pos++; emit(join(path, "_count"), 0); return }
    while (1) {
        value(join(path, i)); i++; ws()
        c = substr(s, pos, 1)
        if (c == ",") { pos++; continue }
        if (c == "]") { pos++; emit(join(path, "_count"), i); return }
        jerr("',' or ']' expected")
    }
}
function str(   out, c, e) {
    pos++; out = ""
    while (pos <= n) {
        c = substr(s, pos, 1)
        if (c == "\"") { pos++; return out }
        if (c == "\\") {
            e = substr(s, pos + 1, 1)
            if (e == "n") out = out "\n"
            else if (e == "t") out = out "\t"
            else if (e == "r") out = out "\r"
            else if (e == "b" || e == "f") out = out ""
            else if (e == "u") { out = out "?"; pos += 4 }
            else out = out e
            pos += 2; continue
        }
        out = out c; pos++
    }
    jerr("unterminated string")
}
function lit(path,   m) {
    m = ""
    while (pos <= n && index(",}] \t\r\n", substr(s, pos, 1)) == 0) { m = m substr(s, pos, 1); pos++ }
    if (m == "") jerr("value expected")
    emit(path, m)
}

{ s = s $0 "\n" }
END {
    if (failed) exit 2
    n = length(s); pos = 1
    value("")
}
