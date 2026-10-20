enum TailscodeVersion {
    /// The one number the three clients share — `project.yml`'s marketing version. A desktop that
    /// stamped itself with a number of its own would make "what is this running" a different
    /// question on every desk, and the update surface compares this against what a checkout says.
    static let current = "1.79"

    static let usage = """
        tailscode — drive your coding agents over Tailscale

          tailscode                          open the window
          tailscode --ask                    open the question box (bind this to a key)
          tailscode <tailscode://… link>     add the machine a pairing link names (also --connect <link>)
          tailscode --demo                   open the scripted demo world (no server)
          tailscode --connect <address>      save a server (--password, --name, --opencode, --omp)
          tailscode --selftest               check the whole chain with no display
          tailscode --flight [minutes]       print the flight recorder, newest last
          tailscode --limits                 apply and print this launch's resource limits
          tailscode --stacks [count]         print the watchdog's last freeze captures, resolved
          tailscode --version
        """
}
