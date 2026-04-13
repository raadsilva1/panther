#!/usr/bin/env ksh
set -u
umask 022

PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
export PATH

APP_NAME='panther'
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_FILE="${SCRIPT_DIR}/panther.pl"
INSTALL_BIN='/usr/local/bin/panther.pl'
INSTALL_LINK='/usr/local/bin/panther'
INSTALL_DESKTOP='/usr/share/applications/panther.desktop'
INSTALL_ICON='/usr/share/pixmaps/panther.svg'
SYSTEM_DIR='/etc/panther'
SYSTEM_CONF='/etc/panther/panther.conf'
SHARED_DIR='/var/lib/panther/shared'
LOG_FILE='/var/tmp/panther-build.log'
STEP=0
TOTAL_STEPS=8

now() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    typeset message="$*"
    print -- "[$(now)] ${message}"
    print -- "[$(now)] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

fail() {
    log "ERROR: $*"
    exit 1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_root_runner() {
    if [ "$(id -u)" -eq 0 ]; then
        print -- ''
        return 0
    fi
    if have_cmd sudo; then
        print -- 'sudo'
        return 0
    fi
    if have_cmd doas; then
        print -- 'doas'
        return 0
    fi
    return 1
}

ROOT_RUNNER=$(need_root_runner) || fail 'Root privileges are required. Please run as root, or make sudo/doas available.'

run_checked() {
    log "+ $*"
    "$@" || fail "Command failed: $*"
}

run_root() {
    log "+ $*"
    if [ -n "${ROOT_RUNNER}" ]; then
        ${ROOT_RUNNER} "$@" || fail "Command failed: $*"
    else
        "$@" || fail "Command failed: $*"
    fi
}

next_step() {
    STEP=$((STEP + 1))
    log "[${STEP}/${TOTAL_STEPS}] $*"
}

write_root_file() {
    typeset dest="$1"
    typeset mode="$2"
    typeset tmp
    tmp=$(mktemp "/tmp/${APP_NAME}.XXXXXX") || fail 'Could not create temporary file.'
    cat > "${tmp}" || {
        rm -f -- "${tmp}"
        fail "Could not prepare ${dest}."
    }
    run_root install -m "${mode}" "${tmp}" "${dest}"
    rm -f -- "${tmp}"
}

install_source_file() {
    [ -f "${SOURCE_FILE}" ] || fail "Local source file not found: ${SOURCE_FILE}"
    [ -s "${SOURCE_FILE}" ] || fail "Local source file is empty: ${SOURCE_FILE}"
    run_root install -d -m 0755 /usr/local/bin
    run_root install -m 0755 "${SOURCE_FILE}" "${INSTALL_BIN}"
    if [ -L "${INSTALL_LINK}" ] || [ -f "${INSTALL_LINK}" ]; then
        run_root rm -f "${INSTALL_LINK}"
    fi
    run_root ln -s "${INSTALL_BIN}" "${INSTALL_LINK}"
}

validate_artix() {
    [ -f /etc/os-release ] || fail '/etc/os-release is missing. This machine does not look like a supported Artix installation.'
    . /etc/os-release
    case "${ID:-}" in
        artix) ;;
        *)
            case "${NAME:-}" in
                *Artix*) ;;
                *) fail 'This installer supports Artix Linux only.' ;;
            esac
            ;;
    esac
}

validate_openrc() {
    if have_cmd rc-status; then
        return 0
    fi
    [ -d /run/openrc ] && return 0
    fail 'This installer expects an OpenRC-based Artix system.'
}

install_packages() {
    have_cmd pacman || fail 'pacman was not found. This does not look like a supported Artix environment.'
    run_root pacman -S --needed --noconfirm perl perl-gtk3 gtk3 feh desktop-file-utils hicolor-icon-theme
}

prepare_layout() {
    run_root install -d -m 0755 "${SYSTEM_DIR}"
    run_root install -d -m 0755 /usr/share/applications
    run_root install -d -m 0755 /usr/share/pixmaps
    run_root install -d -m 0755 "${SHARED_DIR}"
}

install_icon() {
    write_root_file "${INSTALL_ICON}" 0644 <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect x="8" y="10" width="112" height="108" rx="14" fill="#1f2937"/>
  <rect x="18" y="20" width="92" height="66" rx="10" fill="#334155"/>
  <circle cx="42" cy="40" r="8" fill="#fbbf24"/>
  <path d="M22 78l18-18 16 14 14-11 28 23H22z" fill="#86efac"/>
  <path d="M48 98c8-12 24-16 34-12 9 3 15 12 15 22H31c0-3 2-7 6-10 2-2 4-4 5-7 1-4 0-7-3-10 5 0 8 2 9 5 2 4 2 8 0 12z" fill="#111827"/>
  <circle cx="56" cy="86" r="2" fill="#f8fafc"/>
  <circle cx="70" cy="86" r="2" fill="#f8fafc"/>
</svg>
SVG
}

install_desktop_file() {
    write_root_file "${INSTALL_DESKTOP}" 0644 <<DESKTOP
[Desktop Entry]
Type=Application
Name=Panther
GenericName=Wallpaper Manager
Comment=Friendly wallpaper and background manager for feh
Exec=${INSTALL_LINK}
TryExec=${INSTALL_LINK}
Icon=${INSTALL_ICON}
Terminal=false
StartupNotify=true
Categories=Settings;DesktopSettings;GTK;
Keywords=wallpaper;background;feh;picture;desktop;
DESKTOP
}

install_system_conf_if_missing() {
    if [ -f "${SYSTEM_CONF}" ]; then
        log "Keeping existing shared configuration at ${SYSTEM_CONF}."
        return 0
    fi
    write_root_file "${SYSTEM_CONF}" 0644 <<CONF
# Panther shared configuration
# Add shared picture folders with one folder= line per directory.
shared_folder=${SHARED_DIR}
default_type=
default_path=
default_mode=fill
default_bg_color=#000000
default_pattern=solid
default_color1=#1F2937
default_color2=#111827
folder=/usr/share/backgrounds
folder=/usr/share/wallpapers
folder=/usr/local/share/backgrounds
folder=/usr/share/pixmaps
folder=${SHARED_DIR}
CONF
}

validate_runtime() {
    run_checked perl -e 'use Gtk3; use Glib; print "Perl GTK runtime ready\n";'
    run_checked perl -c "${INSTALL_BIN}"
    run_checked feh --version
}

refresh_desktop_cache() {
    if have_cmd update-desktop-database; then
        run_root update-desktop-database /usr/share/applications
    fi
}

print_summary() {
    log 'Panther is installed.'
    log "Main launcher: ${INSTALL_LINK}"
    log "Perl source:    ${INSTALL_BIN}"
    log "Desktop entry:  ${INSTALL_DESKTOP}"
    log "Shared config:  ${SYSTEM_CONF}"
    log "Shared images:  ${SHARED_DIR}"
    log 'Open Panther from your application menu or run: panther'
}

main() {
    : > "${LOG_FILE}" 2>/dev/null || true

    next_step 'Checking Artix Linux and OpenRC'
    validate_artix
    validate_openrc

    next_step 'Checking local source file'
    [ -f "${SOURCE_FILE}" ] || fail "Expected ./panther.pl next to this installer."

    next_step 'Installing required packages'
    install_packages

    next_step 'Preparing install locations'
    prepare_layout

    next_step 'Installing Panther application'
    install_source_file

    next_step 'Installing desktop integration'
    install_icon
    install_desktop_file
    refresh_desktop_cache

    next_step 'Preparing shared Panther configuration'
    install_system_conf_if_missing

    next_step 'Validating runtime readiness'
    validate_runtime

    next_step 'Finishing'
    print_summary
}

main "$@"
