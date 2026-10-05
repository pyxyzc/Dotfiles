# Bounded, single-pass preview rendering. A small ring keeps preceding context;
# syntax state is local to the displayed snippet. Run with LC_ALL=C.
function words(list, color, items, count, i) {
    count = split(list, items, " ")
    for (i = 1; i <= count; i++) token_color[items[i]] = color
}

function paint(text, color) {
    return color text reset
}

# Find a closing quote, honoring backslash escapes and Vim's doubled single quotes.
function quote_end(text, quote, start, position, i, escapes) {
    start = 1
    while ((position = index(substr(text, start), quote))) {
        position += start - 1
        escapes = 0
        for (i = position - 1; i > 0 && substr(text, i, 1) == "\\"; i--) escapes++
        if (syntax == "vim" && quote == "'" && substr(text, position + 1, 1) == "'") {
            start = position + 2
        } else if (escapes % 2 && !((syntax == "shell" || syntax == "vim") && quote == "'")) {
            start = position + length(quote)
        } else {
            return position + length(quote) - 1
        }
    }
    return 0
}

function highlight(text, output, token, rest, end, color) {
    if (syntax == "") return text
    if (syntax == "vim" && text ~ /^ *"/ && quote == "") return paint(text, comment)
    output = ""
    while (length(text)) {
        if (block_comment) {
            end = index(text, "*/")
            if (!end) return output paint(text, comment)
            output = output paint(substr(text, 1, end + 1), comment)
            text = substr(text, end + 2)
            block_comment = 0
        } else if (quote != "") {
            end = quote_end(text, quote)
            if (!end) {
                output = output paint(text, string)
                # Only multiline strings keep state across physical lines.
                if (syntax != "shell" && length(quote) == 1 && quote != "\140" &&
                        text !~ /\\$/) quote = ""
                return output
            }
            output = output paint(substr(text, 1, end), string)
            text = substr(text, end + 1)
            quote = ""
        } else if (match(text, /[A-Za-z_$][A-Za-z_0-9$]*|0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(\.[0-9_]+)?([eE][+-]?[0-9_]+)?[fFuUlL]*|\/\/|\/\*|["\047\140#]/)) {
            output = output substr(text, 1, RSTART - 1)
            token = substr(text, RSTART, RLENGTH)
            rest = substr(text, RSTART + RLENGTH)
            if ((hash_comment && token == "#") || (c_comment && token == "//")) {
                return output paint(token rest, comment)
            } else if (c_comment && token == "/*") {
                output = output paint(token, comment)
                block_comment = 1
            } else if (token == "'" || token == "\"" || (backtick && token == "\140")) {
                if (syntax == "python" && substr(token rest, 1, 3) == token token token) {
                    quote = token token token
                    rest = substr(rest, 3)
                } else {
                    quote = token
                }
                output = output paint(quote, string)
            } else {
                color = token_color[token]
                if (token ~ /^[0-9]/) color = number
                else if (token ~ /^[A-Za-z_$]/ && !color && rest ~ /^ *\(/) color = function_color
                else if (syntax == "yaml" && rest ~ /^ *:/) color = type
                else if (syntax == "cpp" && token == "#") color = keyword
                output = output (color ? paint(token, color) : token)
            }
            text = rest
        } else {
            return output text
        }
    }
    return output
}

BEGIN {
    height = ENVIRON["FZF_PREVIEW_LINES"]
    if (height !~ /^[1-9][0-9]*$/) height = 20
    before = int((height - 1) / 2) - header_rows
    if (before < 0) before = 0
    if (before > 99) before = 99
    reset = "\033[0m"
    # TokyoNight colors; Vim's terminal translates these for a 256-color outer terminal.
    keyword = "\033[38;2;187;154;247m"
    string = "\033[38;2;158;206;106m"
    comment = "\033[38;2;86;95;137m"
    number = "\033[38;2;255;158;100m"
    type = "\033[38;2;42;195;222m"
    function_color = "\033[38;2;122;162;247m"
    if (syntax == "python") {
        words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield", keyword)
        words("True False None", number)
        words("bool bytes dict float int list object set str tuple type", type)
        hash_comment = 1
    } else if (syntax == "cpp") {
        words("alignas alignof asm auto break case catch class concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do dynamic_cast else enum explicit export extern for friend goto if inline mutable namespace new noexcept operator private protected public register reinterpret_cast requires return sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typename union using virtual volatile while __device__ __global__ __host__ __shared__ define elif endif ifdef ifndef include pragma undef", keyword)
        words("bool char char8_t char16_t char32_t double float int long short signed unsigned void wchar_t size_t", type)
        words("false true nullptr NULL", number)
        c_comment = 1
    } else if (syntax == "javascript") {
        words("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function if implements import in instanceof interface let new of private protected public readonly return static super switch this throw try type typeof var void while with yield", keyword)
        words("any bigint boolean never number object string symbol unknown", type)
        words("false true null undefined", number)
        c_comment = backtick = 1
    } else if (syntax == "shell") {
        words("case do done elif else esac fi for function if in select then until while", keyword)
        words("export local readonly declare typeset", type)
        hash_comment = backtick = 1
    } else if (syntax == "vim") {
        words("augroup autocmd break call catch command continue echo echohl echom else elseif endfor endfunction endif endtry endwhile execute finish for function if let nnoremap return set setlocal silent source throw try unlet while", keyword)
        words("true false null", number)
    } else if (syntax == "json" || syntax == "yaml") {
        words("false true null", number)
        if (syntax == "yaml") hash_comment = 1
    }
}

function render(raw, line, hit, partial, text) {
    text = raw
    gsub(/[[:cntrl:]]/, " ", text)
    if (length(text) > 500) {
        text = substr(text, 1, 500)
        sub(/[\300-\377][\200-\277]*$/, "", text)
        text = text " …"
        shortened = 1
    } else if (partial) {
        sub(/[\300-\377][\200-\277]*$/, "", text)
    }
    if (syntax == "") {
        if (hit) printf "\033[1;36m>%6d %s\033[0m\n", line, text
        else printf " %6d %s\n", line, text
    } else {
        if (hit) printf "\033[1;36m>%6d\033[0m %s\n", line, highlight(text)
        else printf "\033[38;2;86;95;137m %6d\033[0m %s\n", line, highlight(text)
    }
    displayed++
    if (++source_lines == 1 || hit) fflush()
}

function render_context(count, i) {
    count = context_total < before ? context_total : before
    if (count >= match_line) count = match_line - 1
    # Blank padding also centers a match near the beginning of a file.
    for (i = count; i < before; i++) {
        print ""
        displayed++
    }
    for (i = context_total - count + 1; i <= context_total; i++)
        render(context[(i - 1) % before + 1], match_line - context_total + i - 1, 0, 0)
}

{
    record_start = bytes
    bytes += length($0) + 1
    raw = $0
    if (by_line && NR == 1) sub(/^\357\273\277/, "", raw)
    preceding = by_line ? NR < match_line : bytes <= target_offset
    if (!started && preceding) {
        # The first record can be the tail of a line cut by the backwards seek.
        if (before && !(skip_first && NR == 1)) {
            context_total++
            context[(context_total - 1) % before + 1] = raw
        }
        next
    }
    if (!started) {
        if (!by_line && record_start < target_offset)
            raw = substr(raw, target_offset - record_start + 1)
        render_context()
        started = 1
        next_line = match_line
        render(raw, next_line++, 1, bytes >= 65536)
    } else {
        render(raw, next_line++, 0, bytes >= 65536)
    }
    if (displayed == 200) exit
}

END {
    if (!started)
        print "[Match is outside the bounded preview; Enter opens the file]"
    else if (displayed == 200 || bytes >= 65536 || shortened)
        print "[Preview limited to 64 KiB / 200 lines / 500 bytes per line; Enter opens the file]"
}
