# Sourced by every script that shells out to a Windows toolchain.
#
# `bash` on a Windows box with WSL installed resolves to WSL's bash, not Git
# Bash. Under WSL the Windows filesystem lives at /mnt/c, the Gowin and Questa
# paths do not exist, and even launching the .exe through interop would hand it
# Linux-style paths it cannot use. The failure otherwise looks like a missing
# toolchain, which sends you looking in the wrong place entirely.

k2g_require_windows_shell() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac

    cat >&2 <<'EOF'
This script needs Git Bash, not WSL.

`bash` resolved to WSL, whose filesystem has no C:/Gowin or E:/Quartus -- the
Windows toolchains are not reachable from there, and passing it Linux paths
would fail even if they were.

Run it from Git Bash instead:

    & "C:\Program Files\Git\bin\bash.exe" rtl/board/build.sh soc

or, from a Git Bash prompt:

    bash rtl/board/build.sh soc

EOF
    return 1
}

# The Questa licence here is NODELOCKED and refuses a second concurrent
# instance. That would be a nuisance rather than a trap if it failed loudly, but
# it does not: the checkout error goes into the per-test log, the testbench
# never runs, and the script that started second reports the same thing it would
# report for a design that is genuinely broken.
#
# The way that actually bites is `mutants.sh`. Start anything else while a sweep
# is running and the mutants that collide come back as "not caught" -- a sweep
# full of guards that appear to have stopped guarding, when in fact nothing ever
# ran. Diagnosed once by finding the error text in a scratch log.
#
# `mutants.sh` sets K2G_ALLOW_CONCURRENT for its own nested run.sh/cosim.sh
# calls: it already serializes them itself, through wait_for_questa_exit.
k2g_require_no_questa() {
    [ "${K2G_ALLOW_CONCURRENT:-0}" = "1" ] && return 0

    ps -W 2>/dev/null | grep -qiE 'vsim|vish|vsimk' || return 0

    cat >&2 <<'EOF'
Another Questa instance is already running.

The licence on this machine is nodelocked and allows one at a time. Starting a
second does not fail loudly -- the checkout error lands in the per-test log and
the run reports failures that are about the licence rather than the design.

Wait for the other run to finish, or stop it, and try again.

EOF
    return 1
}
