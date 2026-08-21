# Counts how often an anchor appears in Swift sources AS THE COMPILER SEES THEM for one
# distribution of the Mac client. Only #if frames whose condition mentions TAILSCODE_MAS are
# honoured; every other conditional is transparent, so an anchor behind #if DEBUG still counts.
#
#   awk -v store=0 -v anchor='TerminalPane' -f gating.awk TailscodeMac/*.swift
#   awk -v store=1 -v anchors=/tmp/list -f gating.awk TailscodeMac/*.swift
#
# store=1 is the sandboxed App Store target (TAILSCODE_MAS defined), store=0 every other build.
# Prints one "<count><TAB><anchor>" line per anchor, in the order the anchors were given.

BEGIN {
    n = 0
    if (anchors != "") {
        while ((getline row < anchors) > 0) {
            if (row != "") { n++; list[n] = row }
        }
        close(anchors)
    }
    if (anchor != "") { n++; list[n] = anchor }
    store = (store == "" ? 0 : store + 0)
    depth = 0
    emit = 1
}

FNR == 1 { depth = 0; emit = 1 }

{
    directive = $0
    sub(/^[ \t]+/, "", directive)
    if (directive ~ /^#if([ \t(!]|$)/) {
        condition = directive
        sub(/^#if[ \t]*/, "", condition)
        depth++
        live[depth] = branchState(condition)
        pure[depth] = purity
        taken[depth] = (purity ? live[depth] : 0)
        recompute()
        next
    }
    if (directive ~ /^#elseif([ \t(!]|$)/) {
        condition = directive
        sub(/^#elseif[ \t]*/, "", condition)
        state = branchState(condition)
        if (taken[depth]) state = 0
        live[depth] = state
        if (purity && state) taken[depth] = 1
        pure[depth] = (pure[depth] && purity)
        recompute()
        next
    }
    if (directive ~ /^#else([ \t]|$)/) {
        live[depth] = (pure[depth] ? (taken[depth] ? 0 : 1) : 1)
        recompute()
        next
    }
    if (directive ~ /^#endif([ \t]|$)/) {
        if (depth > 0) depth--
        recompute()
        next
    }
    if (!emit) next
    for (i = 1; i <= n; i++) {
        if (index($0, list[i])) hits[i]++
    }
}

END {
    for (i = 1; i <= n; i++) printf "%d\t%s\n", hits[i] + 0, list[i]
}

function recompute(    i) {
    emit = 1
    for (i = 1; i <= depth; i++) {
        if (!live[i]) { emit = 0; return }
    }
}

function branchState(condition,   flat, parts, count, i, term, value) {
    purity = 0
    if (condition !~ /TAILSCODE_MAS/) return 1
    flat = condition
    gsub(/[ \t()]/, "", flat)
    value = term_value(flat)
    if (value >= 0) { purity = 1; return value }
    if (flat ~ /\|\|/) return 1
    count = split(flat, parts, /&&/)
    for (i = 1; i <= count; i++) {
        value = term_value(parts[i])
        if (value == 0) return 0
    }
    return 1
}

function term_value(term) {
    if (term == "TAILSCODE_MAS") return (store ? 1 : 0)
    if (term == "!TAILSCODE_MAS") return (store ? 0 : 1)
    return -1
}
