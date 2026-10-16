function publish(text,    line) {
    line = counter == "" ? text : "[" counter "] " text
    if (line == last) return
    last = line
    print line > state
    close(state)
    if (tty != "yes") { print "  " line; fflush() }
}

function named(list,    parts, count, shown, index_) {
    count = split(list, parts, ", ")
    shown = parts[1]
    for (index_ = 2; index_ <= count && index_ <= 3; index_++) shown = shown ", " parts[index_]
    if (count > 3) shown = shown ", +" (count - 3) " more"
    return count == 1 ? parts[1] : count " files (" shown ")"
}

/^\[[0-9]+ \/ [0-9]+\]/ {
    match($0, /^\[[0-9]+ \/ [0-9]+\]/)
    counter = substr($0, 2, RLENGTH - 2)
    gsub(/ /, "", counter)
    publish(module == "" ? substr($0, RLENGTH + 2) : "compiling " module)
    next
}

/^\[[A-Za-z]/ {
    text = $0
    gsub(/^\[|\]$/, "", text)
    publish(module == "" ? text : "compiling " module)
    next
}

/^Planning Swift module / {
    module = $4
    publish("compiling " module)
    next
}

/^Compiling [^ ]/ {
    if (tty == "yes") printf "\r\033[K"
    print "compiled " (module == "" ? "" : module " — ") named(substr($0, 11))
    fflush()
    next
}

/^Discovering Swift tasks after / {
    compiling = 0
    module = ""
    next
}

/error:/ {
    if (tty == "yes") printf "\r\033[K"
    print
    fflush()
    next
}

/^Build complete/ {
    if (tty == "yes") printf "\r\033[K"
    print
    fflush()
}
