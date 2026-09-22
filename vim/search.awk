# NUL records: encoded path, line, column, byte offset, display text.
function encode(s) {
    if (s !~ /[%\t\n\r\033]/) return s
    gsub(/%/, "%25", s)
    gsub(/\t/, "%09", s)
    gsub(/\n/, "%0A", s)
    gsub(/\r/, "%0D", s)
    gsub(/\033/, "%1B", s)
    return s
}

function decode(s) {
    gsub(/%09/, "\t", s)
    gsub(/%0A/, "\n", s)
    gsub(/%0D/, "\r", s)
    gsub(/%1B/, "\033", s)
    gsub(/%25/, "%", s)
    return s
}

function emit(path, line, column, offset, text, encoded, display) {
    if (path != last_path) {
        last_path = path
        last_encoded = encode(path)
        last_display = path
        gsub(/[[:cntrl:]]/, "?", last_display)
    }
    encoded = last_encoded
    display = last_display
    if (mode == "query") {
        gsub(/[[:cntrl:]]/, " ", text)
        display = display ":" line ":" column ":" text
    }
    printf "%s\t%s\t%s\t%s\t%s%c", encoded, line, column, offset, display, 0
    # Sparse matches and the first file must reach fzf immediately.
    # File enumeration then uses small batches to avoid one write syscall per path.
    if (mode != "files" || ++emitted == 1 || emitted % 64 == 0) fflush()
}

BEGIN { RS = mode == "recent" ? "\n" : "\0" }

mode == "files" {
    sub(/^\.\//, "")
    emit($0, 1, 1, 0, "")
}

mode == "recent" { emit(decode($0), 1, 1, 0, "") }

mode == "query" {
    path = $0
    sub(/^\.\//, "", path)
    RS = "\n"
    if ((getline result) > 0) {
        separator = index(result, ":")
        line = substr(result, 1, separator - 1)
        result = substr(result, separator + 1)
        separator = index(result, ":")
        column = substr(result, 1, separator - 1)
        result = substr(result, separator + 1)
        separator = index(result, ":")
        offset = substr(result, 1, separator - 1)
        result = substr(result, separator + 1)
        emit(path, line, column, offset, result)
    }
    RS = "\0"
}
