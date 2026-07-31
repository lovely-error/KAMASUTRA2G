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
