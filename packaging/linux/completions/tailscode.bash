_tailscode() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=($(compgen -W "--ask --connect --demo --force-desktop --help --name --opencode --password --probe-newchat --selftest --themes --version -h" -- "$cur"))
}
complete -F _tailscode tailscode
