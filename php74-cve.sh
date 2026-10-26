#!/bin/bash
# Patched PHP 7.4 packages for CVE-2026-109618 / CVE-2026-109619 (Remi, CentOS 7)
#
# Usage:
#   ./php74-cve.sh status              show the PHP installs on this server and their patch status
#   ./php74-cve.sh install [-y]        upgrade the installed PHP 7.4 packages to the patched version
#   ./php74-cve.sh uninstall [-y]      roll back to the versions installed before
#
# Two install types are detected automatically (both may be present):
#   base: php, php-cli, php-fpm ... 7.4.x  (remi-php74 repo; /usr/bin/php, php-fpm service)
#   scl : php74-php-*                      (Remi SCL; /opt/remi/php74, php74-php-fpm service)
# Only PHP packages that are already installed are changed. Packages not shipped here
# (PECL extensions, php-pear, php74-runtime ...) are left as they are.
# If verification fails after install, the upgrade is rolled back automatically.
#
# USE AT YOUR OWN RISK. Unofficial rebuilds of Remi's PHP 7.4 packages, provided
# "AS IS", WITHOUT WARRANTY OF ANY KIND. The authors are not liable for any damage.
# See README.md and LICENSE: https://github.com/bagsiz/el7-php74-security
set -uo pipefail

PATCHED_VR=7.4.33-31.1.el7
CVE=CVE-2026-109618
HERE=$(cd "$(dirname "$0")" && pwd)
STATE_ROOT=/var/lib/php74-cve-2026

# The RPMs are GitHub release assets: when rpms/<base|scl> is missing, the archive is
# downloaded and checked against the SHA256 below. Without access (no internet), download
# the archive by hand and put it next to this script.
RELEASE_URL=${PHP74CVE_RELEASE_URL:-https://github.com/bagsiz/el7-php74-security/releases/download/v7.4.33-31.1}
SHA256_base=a55478884dcd9b1973df52ed4065bca0d8047ae7ce2b5faa10d1c17d00453e20
SHA256_scl=3d327b529b498d63774feca517aac44dc17447ea6e9841027b046634e4ccfa56

# rpmrebuild + rpm-build for every EL7 rpm version (rpm-build must match the installed rpm
# exactly; old servers often cannot reach EPEL or the CentOS repositories). Same release.
TOOLS_ASSET=el7-rpmrebuild-tools.tar.gz
SHA256_tools=677dbcfbecc420f056fb5870f52c31be63dc778ec65d9cd23aaa1bae4a729447
TOOLS_DIR=$HERE/tools
# backup_rpm runs in a subshell ($(...)): state shared with it lives in files
TOOLS_STATE=$(mktemp)      # names of the tool packages this script installed
RR_FILTER=$(mktemp)        # rpmrebuild %files filter, see ensure_rpmrebuild

# Network timeouts (seconds). curl gives up when it cannot connect, or when the download
# stalls (below 1 KB/s), for NET_TIMEOUT seconds; a slow but moving download is not cut off.
# yum/yumdownloader: per-request timeout, one retry, unreachable repositories are skipped
# (EOL CentOS 7 servers often still list dead mirrors such as mirrorlist.centos.org).
NET_TIMEOUT=${PHP74CVE_NET_TIMEOUT:-10}
CURL_NET=(--connect-timeout "$NET_TIMEOUT" --speed-time "$NET_TIMEOUT" --speed-limit 1024)
# yum: retries=0 would mean "retry forever", 1 is the minimum
YUM_NET=(--setopt=timeout="$NET_TIMEOUT" --setopt=retries=1 --setopt='*.skip_if_unavailable=1')

# packages that have a patched build
PKGS_base="php php-bcmath php-cli php-common php-dba php-dbg php-devel php-embedded php-enchant php-ffi php-fpm php-gd php-gmp php-imap php-intl php-json php-ldap php-litespeed php-mbstring php-mysqlnd php-odbc php-opcache php-pdo php-pdo-dblib php-pdo-firebird php-pgsql php-process php-pspell php-snmp php-soap php-sodium php-tidy php-xml php-xmlrpc"
PKGS_scl="php74-php php74-php-bcmath php74-php-cli php74-php-common php74-php-dba php74-php-dbg php74-php-devel php74-php-embedded php74-php-enchant php74-php-ffi php74-php-fpm php74-php-gd php74-php-gmp php74-php-imap php74-php-intl php74-php-json php74-php-ldap php74-php-litespeed php74-php-mbstring php74-php-mysqlnd php74-php-odbc php74-php-opcache php74-php-pdo php74-php-pdo-dblib php74-php-pdo-firebird php74-php-pgsql php74-php-process php74-php-pspell php74-php-snmp php74-php-soap php74-php-sodium php74-php-tidy php74-php-xml php74-php-xmlrpc"

ASSUME_YES=0
INSTALLED=""   # install types upgraded by this run
CMD=${1:-status}
[ "${2:-}" = "-y" ] && ASSUME_YES=1

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " a
    [ "$a" = y ] || [ "$a" = Y ]
}

# per install type settings
set_mode() {
    MODE=$1
    case $MODE in
    base)
        TITLE="php (base, remi-php74)"
        COMMON=php-common
        GLOBS="php php-*"
        PHP=/usr/bin/php
        FPM=/usr/sbin/php-fpm
        CONF_PATHS="etc/php.ini etc/php.d etc/php-fpm.conf etc/php-fpm.d etc/httpd/conf.d/php.conf"
        SERVICES="php-fpm httpd"
        ;;
    scl)
        TITLE="php74 (Remi SCL)"
        COMMON=php74-php-common
        GLOBS="php74-php php74-php-*"
        PHP=/opt/remi/php74/root/usr/bin/php
        FPM=/opt/remi/php74/root/usr/sbin/php-fpm
        CONF_PATHS="etc/opt/remi/php74 etc/httpd/conf.d/php74-php.conf"
        SERVICES="php74-php-fpm httpd"
        ;;
    esac
    RPM_DIR=$HERE/rpms/$MODE
    STATE_DIR=$STATE_ROOT/$MODE
    eval "PKGS=\$PKGS_$MODE ASSET_SHA=\$SHA256_$MODE"
    ASSET=php74-rpms-$MODE.tar.gz
}

has_patched() { # NAME: is there a patched build of this package
    case " $PKGS " in *" $1 "*) return 0 ;; esac
    return 1
}

# when rpms/<mode> is missing: download the release archive, verify it, extract it
fetch_rpms() {
    [ -f "$RPM_DIR/SHA256SUMS" ] && return 0
    local f=$HERE/$ASSET
    if [ ! -f "$f" ]; then
        say "Downloading RPMs: $RELEASE_URL/$ASSET"
        local rc=0
        curl -fL "${CURL_NET[@]}" -o "$f.part" "$RELEASE_URL/$ASSET" && mv "$f.part" "$f" || rc=$?
        if [ "$rc" != 0 ]; then
            rm -f "$f.part"
            # 35/60: TLS handshake / certificate not trusted. Stock CentOS 7.0-7.3 CA bundles
            # do not trust the certificates of GitHub's download hosts
            case $rc in 35|51|58|60|77)
                warn "TLS/certificate error (curl exit $rc): update the CA bundle with 'yum update ca-certificates', or download the file on another machine" ;;
            esac
            die "could not download $ASSET. Download it from the release by hand, put it in $HERE/ and run again"
        fi
    fi
    echo "$ASSET_SHA  $f" | sha256sum --quiet -c - || die "$ASSET SHA256 mismatch (corrupted or modified); delete it and download again"
    tar xzf "$f" -C "$HERE" || die "could not extract $ASSET"
}

# PHP 7.4 install types on this server (scl / base), in install order: scl first, so that a
# base php-gd taking over a hand-copied gd.so (see adoptable) finds gd3php already in place
detect_modes() {
    local v
    rpm -q php74-php-common >/dev/null 2>&1 && echo scl
    v=$(rpm -q --qf '%{VERSION}' php-common 2>/dev/null) && case $v in 7.4.*) echo base ;; esac
    return 0
}

# package name -> install type: base | scl | description of an unsupported install
classify_pkg() { # NAME VERSION
    case "$1" in
        php74-php|php74-php-*)          echo scl ;;
        php74w*|mod_php74w*)            echo "Webtatic php74w (not supported)" ;;
        php74u*|mod_php74u*)            echo "IUS php74u (not supported)" ;;
        php|php-cli|php-fpm|php-cgi|php-common)
            case "$2" in 7.4.*) echo base ;; *) echo "PHP $2 (not 7.4)" ;; esac ;;
        php[0-9]*-php*)                 echo "Remi SCL ${1%%-*} (not 7.4)" ;;
        *)                              echo "package $1 (not recognized)" ;;
    esac
}

# owner of a file: "rpm NAME VERSION", "dpkg NAME" or "none"
owner_of() { # PATH
    local q
    if command -v rpm >/dev/null 2>&1 && q=$(rpm -qf --qf '%{NAME} %{VERSION}\n' "$1" 2>/dev/null | head -1); then
        echo "rpm $q"
    elif command -v dpkg >/dev/null 2>&1 && q=$(dpkg -S "$1" 2>/dev/null | head -1 | cut -d: -f1); then
        echo "dpkg $q"
    else
        echo none
    fi
}

php_version_of() { # BINARY (php / php-fpm / php-cgi)
    local v
    v=$("$1" -v 2>/dev/null | head -1) || true
    v=${v#PHP }; echo "${v%% *}"
}

# Finds every PHP on the server and how it is used.
# Each line: TYPE|DESCRIPTION   (TYPE: base, scl or - )
discover() {
    local cands=() p real own ver kind how pid exe conf mod f cmd
    local -A hows=() order=()
    local n=0
    local names="php php74 php7.4 php-fpm php-fpm74 php-fpm7.4 php74-php-fpm php-cgi php-cgi74 php-cgi7.4"
    for p in $names; do
        f=$(command -v "$p" 2>/dev/null) && cands+=("$f|command '$p'")
    done
    for f in /usr/bin/php* /usr/sbin/php-fpm* /usr/local/bin/php* /usr/local/sbin/php-fpm* \
             /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
             /usr/local/php*/bin/php /usr/local/php*/sbin/php-fpm /opt/php*/bin/php /opt/php*/sbin/php-fpm; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        # interpreters only: php, php74, php7.4, php-cgi*, php74-cgi, php-fpm* (not phpize, php-config, phar)
        case "${f##*/}" in
            php|php[0-9]|php[0-9][0-9]|php[0-9].[0-9]|php-fpm*|php-cgi*|php[0-9]*-cgi) cands+=("$f|$f") ;;
        esac
    done
    # running php-fpm master processes: title "php-fpm: master process (conf)";
    # if the title was not changed, the first argument of the command line is the php-fpm path
    local ppid_
    for p in /proc/[0-9]*; do
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        pid=${p#/proc/}
        exe=$(readlink -f "$p/exe" 2>/dev/null)
        case "$cmd" in
            "php-fpm: master"*) ;;
            /*)
                case "${cmd%% *}" in */php-fpm*) ;; *) continue ;; esac
                # master: a process whose parent is not php-fpm
                ppid_=$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null)
                case "$(tr '\0' ' ' < "/proc/$ppid_/cmdline" 2>/dev/null)" in *php-fpm*) continue ;; esac
                [ -n "$exe" ] || exe=${cmd%% *}
                ;;
            *) continue ;;
        esac
        [ -n "$exe" ] || continue
        conf=$(echo "$cmd" | sed -n 's/.*(\(.*\)).*/\1/p')
        cands+=("$exe|RUNNING: php-fpm master pid $pid${conf:+ ($conf)}")
    done
    # PHP module loaded by Apache (mod_php)
    for f in /etc/httpd/conf.modules.d/*.conf /etc/httpd/conf.d/*.conf; do
        [ -f "$f" ] || continue
        while read -r mod; do
            [ -n "$mod" ] || continue
            case "$mod" in /*) ;; *) mod=/etc/httpd/$mod ;; esac
            cands+=("$(readlink -f "$mod")|Apache module ($f)")
        done < <(sed -n 's/^[[:space:]]*LoadModule[[:space:]]\+php[0-9_]*module[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$f")
    done

    # merge paths that lead to the same real file into one line
    # bash 4.2 (CentOS 7): an empty array counts as unbound under "set -u"
    [ ${#cands[@]} -gt 0 ] || return 0
    for p in "${cands[@]}"; do
        f=${p%%|*}; how=${p#*|}
        real=$(readlink -f "$f" 2>/dev/null || echo "$f")
        [ "$how" = "$f" ] && { [ "$f" = "$real" ] && how="" || how="link: $f"; }
        if [ -z "${order[$real]+x}" ]; then order[$real]=$n; n=$((n+1)); hows[$real]=$how
        elif [ -n "$how" ]; then
            case "; ${hows[$real]}; " in *"; $how; "*) ;; *) hows[$real]="${hows[$real]:+${hows[$real]}; }$how" ;; esac
        fi
    done

    for real in $(for r in "${!order[@]}"; do echo "${order[$r]} $r"; done | sort -n | cut -d' ' -f2-); do
        how=${hows[$real]}
        own=$(owner_of "$real")
        case "$real" in *.so) ver="" ;; *) ver=$(php_version_of "$real") ;; esac
        case "$own" in
            rpm\ *) set -- $own; kind=$(classify_pkg "$2" "$3"); [ -z "$ver" ] && ver=$3 ;;
            dpkg\ *) kind="Debian/Ubuntu package ${own#dpkg } (not supported)" ;;
            *) kind="not owned by any package: built from source / copied by hand (not supported)" ;;
        esac
        f="$real  [PHP ${ver:-?}]${how:+  ($how)}"
        case "$kind" in base|scl) echo "$kind|$f" ;;
                        *)        echo "-|$f : $kind" ;; esac
    done
}

print_discovery() {
    local line k found=0
    say "PHP on this server"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=1; k=${line%%|*}
        case $k in
            base) echo "  [patchable: base] ${line#*|}" ;;
            scl)  echo "  [patchable: scl ] ${line#*|}" ;;
            *)    echo "  [left as is     ] ${line#*|}" ;;
        esac
    done < <(discover)
    [ "$found" = 1 ] || echo "  (no PHP found)"
}

# "NAME VERSION-RELEASE" lines
installed_pkgs() {
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' $GLOBS | sort
}

is_patched() { # NAME
    [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null)" = "$PATCHED_VR" ]
}

# Back up the RPM of an installed version, for rollback. Sources, in order:
#   cache  : the yum cache (/var/cache/yum, when keepcache=1 or downloaded earlier)
#   repo   : the repositories (yumdownloader)
#   rebuild: rpmrebuild, rebuilds the RPM from the RPM database and the files on disk.
#            Unsigned; config files go in as they are now (that is what a rollback needs).
# Prints the source used; returns 1 if none worked.
# PHP74CVE_BACKUP_SOURCES limits the sources (testing); PHP74CVE_NO_DOWNLOAD=1 disables all.
backup_rpm() { # NAME VERSION-RELEASE DESTDIR [ARCH]
    local name=$1 vr=$2 dest=$3 nevra="$1-$2.${4:-x86_64}" src f tmp
    local sources=${PHP74CVE_BACKUP_SOURCES:-cache repo rebuild}
    [ -n "${PHP74CVE_NO_DOWNLOAD:-}" ] && sources=""
    for src in $sources; do
        case $src in
        cache)
            while IFS= read -r f; do
                [ "$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$f" 2>/dev/null)" = "$nevra" ] || continue
                rpm -K --nosignature "$f" >/dev/null 2>&1 || continue
                cp "$f" "$dest/$nevra.rpm" && { echo cache; return 0; }
            done < <(find /var/cache/yum -name "$nevra.rpm" 2>/dev/null)
            ;;
        repo)
            command -v yumdownloader >/dev/null 2>&1 || yum "${YUM_NET[@]}" -y -q install yum-utils >/dev/null 2>&1
            yumdownloader "${YUM_NET[@]}" -q --destdir "$dest" "$nevra" >/dev/null 2>&1 && [ -f "$dest/$nevra.rpm" ] && { echo repo; return 0; }
            ;;
        rebuild)
            ensure_rpmrebuild || continue
            tmp=$(mktemp -d)
            # SHA256 file digests and xz payload like the original packages (normally set by
            # redhat-rpm-config, which the bundled tools do not pull in); files missing on
            # disk (docs not installed, deleted by hand) are dropped from %files
            if rpmrebuild --batch --notest-install \
                    --define '_binary_filedigest_algorithm 8' --define '_binary_payload w9.xzdio' \
                    --change-spec-files="$RR_FILTER" --directory="$tmp" "$nevra" >/dev/null 2>&1; then
                f=$(find "$tmp" -name "$nevra.rpm" | head -1)
                [ -n "$f" ] && mv "$f" "$dest/$nevra.rpm" && { rm -rf "$tmp"; echo rebuild; return 0; }
            fi
            rm -rf "$tmp"
            ;;
        esac
    done
    return 1
}

# Make rpmrebuild usable: already installed, else the bundled tools from the release
# (rpm-build matching this server's rpm + rpmrebuild, installed with --nodeps: rebuilding
# installed files needs neither perl, gdb nor redhat-rpm-config), else yum (EPEL).
# Packages installed here are removed again by cleanup_tools.
ensure_rpmrebuild() {
    local f r add=()
    if [ ! -s "$RR_FILTER" ]; then
        cat > "$RR_FILTER" <<'FILTER'
#!/bin/bash
while IFS= read -r line; do
    p=$(printf '%s\n' "$line" | sed -n 's/.*"\(\/[^"]*\)"[[:space:]]*$/\1/p')
    if [ -n "$p" ] && [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi
    printf '%s\n' "$line"
done
FILTER
        chmod +x "$RR_FILTER"
    fi
    command -v rpmrebuild >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1 && return 0

    if [ ! -f "$TOOLS_DIR/SHA256SUMS" ]; then
        f=$HERE/$TOOLS_ASSET
        if [ ! -f "$f" ]; then
            curl -fsL "${CURL_NET[@]}" -o "$f.part" "$RELEASE_URL/$TOOLS_ASSET" && mv "$f.part" "$f"
            rm -f "$f.part"
        fi
        if [ -f "$f" ] && echo "$SHA256_tools  $f" | sha256sum --quiet -c - >/dev/null 2>&1; then
            tar xzf "$f" -C "$HERE" 2>/dev/null
        fi
    fi
    if [ -f "$TOOLS_DIR/SHA256SUMS" ] && (cd "$TOOLS_DIR" && sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1); then
        r=$(rpm -q --qf '%{VERSION}-%{RELEASE}' rpm)
        if ! rpm -q rpm-build >/dev/null 2>&1; then
            [ -f "$TOOLS_DIR/rpm-build-$r.x86_64.rpm" ] && add+=("$TOOLS_DIR/rpm-build-$r.x86_64.rpm")
        fi
        if ! rpm -q rpmrebuild >/dev/null 2>&1; then
            for f in "$TOOLS_DIR"/rpmrebuild-*.noarch.rpm; do [ -f "$f" ] && add+=("$f"); done
        fi
        if [ ${#add[@]} -gt 0 ] && rpm -i --nodeps "${add[@]}" >/dev/null 2>&1; then
            for f in "${add[@]}"; do rpm -qp --qf '%{NAME}\n' "$f" 2>/dev/null >> "$TOOLS_STATE"; done
        fi
        command -v rpmrebuild >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1 && return 0
    fi
    yum "${YUM_NET[@]}" -y -q install rpmrebuild >/dev/null 2>&1
    command -v rpmrebuild >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1
}

# remove the rpm-build/rpmrebuild packages installed by ensure_rpmrebuild
cleanup_tools() {
    if [ -s "$TOOLS_STATE" ]; then
        rpm -e --nodeps $(sort -u "$TOOLS_STATE") >/dev/null 2>&1
        : > "$TOOLS_STATE"
    fi
}
trap 'cleanup_tools; rm -f "$TOOLS_STATE" "$RR_FILTER"' EXIT

active_services() {
    local s
    for s in $SERVICES; do
        systemctl is-active --quiet "$s" >/dev/null 2>&1 && echo "$s"
    done
}

preflight() {
    [ "$(id -u)" = 0 ] || die "run as root"
    grep -q 'release 7\.' /etc/centos-release 2>/dev/null || die "CentOS 7 only"
    [ "$(uname -m)" = x86_64 ] || die "x86_64 only"
}

# post-install checks; returns 1 on failure
verify() {
    local ok=0 out
    say "Verifying ($TITLE)"
    # the cli package may be missing (e.g. only a leftover php74-php-common)
    if [ -x "$PHP" ]; then
        if out=$("$PHP" -v 2>&1); then echo "  php -v: $(echo "$out" | head -1)"; else echo "  php -v FAILED: $out"; ok=1; fi
        out=$("$PHP" -m 2>&1 | grep -iE 'warning|error|fatal|unable to')
        if [ -n "$out" ]; then echo "  php -m reported warnings/errors:"; echo "$out" | sed 's/^/    /'; ok=1; else echo "  modules: loaded without warnings"; fi
    else
        echo "  php -v / php -m: skipped ($PHP missing, cli package not installed)"
    fi
    if rpm -q --changelog "$COMMON" | grep -q "$CVE"; then echo "  changelog: contains $CVE"; else echo "  changelog: $CVE MISSING"; ok=1; fi
    if [ -x "$FPM" ]; then
        if out=$("$FPM" -t 2>&1); then echo "  php-fpm -t: ok"; else echo "  php-fpm -t FAILED:"; echo "$out" | sed 's/^/    /'; ok=1; fi
    fi
    if systemctl is-active --quiet httpd >/dev/null 2>&1 || [ -n "${HTTPD_CHECK:-}" ]; then
        if command -v apachectl >/dev/null 2>&1; then
            if out=$(apachectl -t 2>&1); then echo "  apachectl -t: ok"; else echo "  apachectl -t FAILED:"; echo "$out" | sed 's/^/    /'; ok=1; fi
        fi
    fi
    # testing only: exercise the automatic rollback path
    [ -n "${PHP74CVE_TEST_FAIL_VERIFY:-}" ] && { echo "  (test) verification forced to fail"; ok=1; }
    return $ok
}

restart_services() { # service list
    local s ok=0
    for s in "$@"; do
        say "Restarting $s"
        if systemctl restart "$s" && sleep 2 && systemctl is-active --quiet "$s" >/dev/null 2>&1; then
            echo "  $s: active"
        else
            echo "  $s: FAILED TO START"; systemctl status "$s" --no-pager -l 2>&1 | tail -15 | sed 's/^/    /'; ok=1
        fi
    done
    return $ok
}

status_mode() {
    local name vr mark
    say "Installed packages: $TITLE"
    while read -r name vr; do
        [ -n "$name" ] || continue
        if [ "$vr" = "$PATCHED_VR" ]; then mark="patched"
        elif has_patched "$name"; then mark="UNPATCHED (patched build available)"
        else mark="left as is (not shipped here)"; fi
        printf '  %-32s %-24s %s\n' "$name" "$vr" "$mark"
    done < <(installed_pkgs)
    say "Services"
    for s in $SERVICES; do printf '  %-16s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done
    if [ -L "$STATE_DIR/current" ]; then say "Backup of the last install: $(readlink "$STATE_DIR/current")"; fi
}

install_mode() {
    fetch_rpms
    say "Checking package integrity ($TITLE)"
    (cd "$RPM_DIR" && sha256sum --quiet -c SHA256SUMS) || die "RPM files are corrupted or modified"

    local name vr files=() upgrade=() skipped=()
    while read -r name vr; do
        [ -n "$name" ] || continue
        if is_patched "$name"; then continue; fi
        if has_patched "$name"; then
            [ -f "$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm" ] || die "$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm is missing"
            files+=("$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm"); upgrade+=("$name $vr")
        else
            skipped+=("$name $vr")
        fi
    done < <(installed_pkgs)

    if [ ${#upgrade[@]} -eq 0 ]; then
        say "$TITLE: nothing to upgrade, the installed packages are already patched"
        return 0
    fi

    local adopt=() adopt_paths=() r f
    while read -r name r; do
        [ -n "$name" ] || continue
        adopt+=("$name"); files+=("$r")
        while read -r f; do
            [ -e "$f" ] && [ ! -d "$f" ] && ! rpm -qf "$f" >/dev/null 2>&1 && adopt_paths+=("$f")
        done < <(rpm -qpl "$r" 2>/dev/null)
    done < <(adoptable)

    say "$TITLE: packages to upgrade (-> $PATCHED_VR)"
    printf '  %s\n' "${upgrade[@]}"
    if [ ${#skipped[@]} -gt 0 ]; then
        say "$TITLE: packages left as is"
        printf '  %s\n' "${skipped[@]}"
    fi
    if [ ${#adopt[@]} -gt 0 ]; then
        say "$TITLE: also installed, their files are on disk without a package (copied by hand?)"
        printf '  %s\n' "${adopt[@]}"
        echo "  files replaced (backed up, put back by uninstall):"
        printf '    %s\n' "${adopt_paths[@]}"
    fi

    if [ -x "$FPM" ] && ! "$FPM" -t >/dev/null 2>&1; then
        "$FPM" -t
        die "the php-fpm configuration is already broken BEFORE the install; fix that first"
    fi

    local services
    services=$(active_services)
    say "Services to restart after the install: ${services:-(none)}"

    confirm "Continue?" || die "aborted"

    # backup
    local backup=$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S) p existing=()
    mkdir -p "$backup/rpms"
    say "Creating backup: $backup"
    printf '%s\n' "${upgrade[@]}" > "$backup/upgraded.txt"
    echo "$services" > "$backup/services.txt"
    for p in $CONF_PATHS; do [ -e "/$p" ] && existing+=("$p"); done
    if [ ${#adopt[@]} -gt 0 ]; then
        printf '%s\n' "${adopt[@]}" > "$backup/adopted.txt"
        tar czf "$backup/adopted-files.tar.gz" -P "${adopt_paths[@]}" ||
            { rm -rf "$backup"; die "could not back up ${adopt_paths[*]}"; }
        echo "  files replaced by ${adopt[*]}: $backup/adopted-files.tar.gz"
    fi
    if [ ${#existing[@]} -gt 0 ] && tar czf "$backup/config.tar.gz" -C / "${existing[@]}" 2>/dev/null; then
        echo "  configuration: $backup/config.tar.gz"
    fi

    # Installed packages the yum transaction replaces: a new dependency obsoletes them (for
    # example gd3php obsoletes gd-last, which older php-gd builds need). The old PHP
    # packages need them back on rollback, so they are backed up too.
    : > "$backup/replaced.txt"
    yum "${YUM_NET[@]}" --assumeno localinstall "${files[@]}" 2>/dev/null |
        awk '$1 == "replacing" { n = $2; a = n; sub(/\.[^.]*$/, "", n); sub(/.*\./, "", a)
                                 vr = $3; sub(/^[0-9]+:/, "", vr); print n, a, vr }' | sort -u > "$backup/replaced.txt"
    if [ -s "$backup/replaced.txt" ]; then
        echo "  the install replaces: $(awk '{printf "%s%s-%s.%s", (NR > 1 ? ", " : ""), $1, $3, $2}' "$backup/replaced.txt")"
    fi

    # RPMs of the current versions, for rollback: yum cache, then repositories, then rpmrebuild
    local missing=() nevra line src total=0 todo=()
    mapfile -t todo < <(printf '%s\n' "${upgrade[@]}"; awk '{print $1, $3, $2}' "$backup/replaced.txt")
    for line in "${todo[@]}"; do
        set -- $line
        nevra="$1-$2.${3:-x86_64}"; total=$((total + 1))
        if src=$(backup_rpm "$1" "$2" "$backup/rpms" "${3:-x86_64}"); then
            echo "$nevra $src" >> "$backup/sources.txt"
            printf '  %-48s %s\n' "$nevra" "$src"
        else
            missing+=("$nevra")
        fi
    done
    cleanup_tools
    echo "  RPMs of the current versions: $(( total - ${#missing[@]} ))/$total backed up"
    if grep -q ' rebuild$' "$backup/sources.txt" 2>/dev/null; then
        warn "some RPMs were rebuilt from the installed files with rpmrebuild (unsigned, not identical to the original)"
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        warn "These versions could not be backed up (not in the yum cache or the repositories, rpmrebuild failed):"
        printf '    %s\n' "${missing[@]}" >&2
        warn "for these, uninstall goes back to the newest version in the repositories (unpatched)"
        confirm "Continue anyway?" || { rm -rf "$backup"; die "aborted"; }
    fi
    ln -sfn "$backup" "$STATE_DIR/current"

    say "Installing the patched packages ($TITLE)"
    rpm -qa --qf '%{NAME}\n' | sort -u > "$backup/rpmqa-before.txt"
    if ! yum "${YUM_NET[@]}" -y localinstall "${files[@]}"; then
        die "yum install failed; nothing was changed (the yum transaction was rolled back). Backup: $backup"
    fi
    # new dependencies (removed again on rollback when nothing else needs them)
    rpm -qa --qf '%{NAME}\n' | sort -u | comm -13 "$backup/rpmqa-before.txt" - > "$backup/added.txt"

    local failed=0
    verify || failed=1
    if [ "$failed" = 0 ] && [ -n "$services" ]; then
        restart_services $services || failed=1
    fi

    if [ "$failed" = 1 ]; then
        warn "Verification failed, rolling back automatically ($TITLE${INSTALLED:+ and the install types upgraded before it})"
        INSTALLED="$INSTALLED $MODE"
        rollback_run
        die "the install was rolled back"
    fi
    INSTALLED="$INSTALLED $MODE"
    say "Done: $TITLE upgraded to the patched version ($PATCHED_VR)"
}

# Patched packages that are not installed, but whose PHP extension (.so) is on disk without
# an owning package: an extension copied by hand from another build, e.g.
# /usr/lib64/php/modules/gd.so without php-gd. Such a file keeps its old library
# dependencies (gd.so -> libgd.so.3 from gd-last) that rpm does not know about, so it breaks
# when the install replaces that library. Installing the patched package puts a packaged
# extension in its place. Prints "NAME RPMFILE" per package.
adoptable() {
    local r n f
    for r in "$RPM_DIR"/*.rpm; do
        n=$(rpm -qp --qf '%{NAME}' "$r" 2>/dev/null) || continue
        rpm -q "$n" >/dev/null 2>&1 && continue
        while read -r f; do
            case $f in *.so) ;; *) continue ;; esac
            [ -e "$f" ] && ! rpm -qf "$f" >/dev/null 2>&1 && { echo "$n $r"; break; }
        done < <(rpm -qpl "$r" 2>/dev/null)
    done
}

# roll back every install type upgraded by this run, in reverse install order, so that the
# server ends up as it was (one install type may have replaced a library the other needs)
rollback_run() {
    local m
    for m in base scl; do
        case " $INSTALLED " in *" $m "*) set_mode "$m"; ASSUME_YES=1 uninstall_mode ;; esac
    done
}

# Remove the dependencies the install added (backup/added.txt, e.g. gd3php) once nothing
# needs them any more. One at a time, until no more can go: they may need each other.
remove_added() { # BACKUP
    [ -s "$1/added.txt" ] || return 0
    local p left removed=() more=1
    while [ $more = 1 ]; do
        more=0; left=()
        while read -r p; do
            rpm -q "$p" >/dev/null 2>&1 || continue
            if rpm -e --test "$p" >/dev/null 2>&1 && rpm -e "$p" >/dev/null 2>&1; then
                removed+=("$p"); more=1
            else
                left+=("$p")
            fi
        done < "$1/added.txt"
    done
    [ ${#removed[@]} -gt 0 ] && echo "  removed the dependencies the install had added: ${removed[*]}"
    [ ${#left[@]} -gt 0 ] && echo "  kept (still needed): ${left[*]}"
    return 0
}

uninstall_mode() {
    if [ ! -L "$STATE_DIR/current" ]; then
        say "$TITLE: no install backup, not installed by this script; skipping"
        return 0
    fi
    local backup
    backup=$(readlink "$STATE_DIR/current")
    [ -f "$backup/upgraded.txt" ] || die "$backup/upgraded.txt is missing"

    local name vr local_rpms=() repo_pkgs=()
    while read -r name vr; do
        [ -n "$name" ] || continue
        is_patched "$name" || continue
        if [ -f "$backup/rpms/$name-$vr.x86_64.rpm" ]; then
            local_rpms+=("$backup/rpms/$name-$vr.x86_64.rpm")
        else
            repo_pkgs+=("$name")
        fi
    done < "$backup/upgraded.txt"
    # Packages an install replaced (see install_mode). Both install types are checked: the
    # install type that replaced gd-last may not be the only one whose old packages need it.
    local arch b r
    for b in "$backup" "$STATE_ROOT"/*/current; do
        [ -f "$b/replaced.txt" ] || continue
        b=$(readlink -f "$b")
        while read -r name arch vr; do
            [ -n "$name" ] || continue
            rpm -q "$name-$vr.$arch" >/dev/null 2>&1 && continue
            r=$b/rpms/$name-$vr.$arch.rpm
            if [ ! -f "$r" ]; then
                warn "$name-$vr.$arch was replaced by the install and is not in the backup"
            elif ! printf '%s\n' ${local_rpms[@]+"${local_rpms[@]}"} | grep -q "/$name-$vr.$arch.rpm$"; then
                local_rpms+=("$r")
            fi
        done < "$b/replaced.txt"
    done

    if [ ${#local_rpms[@]} -eq 0 ] && [ ${#repo_pkgs[@]} -eq 0 ]; then
        say "$TITLE: no patched packages to roll back"
        rm -f "$STATE_DIR/current"; return 0
    fi

    say "$TITLE: rolling back to"
    local r s
    for r in ${local_rpms[@]+"${local_rpms[@]}"}; do
        s=$(awk -v n="$(basename "$r" .rpm)" '$1 == n {print $2}' "$backup/sources.txt" 2>/dev/null)
        printf '  %s (from backup%s)\n' "${r##*/}" "${s:+: $s}"
    done
    [ ${#repo_pkgs[@]} -gt 0 ] && printf '  %s -> newest version in the repositories\n' "${repo_pkgs[@]}"
    confirm "Continue?" || die "aborted"

    # packages the install added in place of hand-copied files: remove them, put the files back
    if [ -s "$backup/adopted.txt" ]; then
        local adopted
        adopted=$(rpm -q --qf '%{NAME}\n' $(cat "$backup/adopted.txt") 2>/dev/null | grep -v ' ')
        if [ -n "$adopted" ]; then
            rpm -e $adopted || die "could not remove $adopted"
        fi
        tar xzf "$backup/adopted-files.tar.gz" -P || die "could not restore the files from $backup/adopted-files.tar.gz"
        echo "  removed $(echo $adopted), restored: $(tar tzf "$backup/adopted-files.tar.gz" -P | tr '\n' ' ')"
    fi
    if [ ${#local_rpms[@]} -gt 0 ]; then
        # A restored replaced package is "obsoleted by (installed)" its replacement (gd-last
        # by gd3php), which rpm refuses. When that is the only problem, install without the
        # dependency check; remove_added then removes the replacement if nothing needs it.
        local test_out nodeps=()
        if ! test_out=$(rpm -U --test --oldpackage "${local_rpms[@]}" 2>&1); then
            if printf '%s\n' "$test_out" | grep -v -e '^error: Failed dependencies:' \
                    -e 'is obsoleted by (installed)' | grep -q .; then
                printf '%s\n' "$test_out" >&2
                die "rpm downgrade failed"
            fi
            nodeps=(--nodeps)
        fi
        rpm -Uvh --oldpackage ${nodeps[@]+"${nodeps[@]}"} "${local_rpms[@]}" || die "rpm downgrade failed"
    fi
    if [ ${#repo_pkgs[@]} -gt 0 ]; then
        yum "${YUM_NET[@]}" -y downgrade "${repo_pkgs[@]}" || die "yum downgrade failed"
    fi
    remove_added "$backup"

    local services
    services=$(cat "$backup/services.txt" 2>/dev/null)
    [ -n "$services" ] && restart_services $services

    rm -f "$STATE_DIR/current"
    say "$TITLE rolled back. Configuration backup: $backup/config.tar.gz (not restored automatically)"
}

main() {
    local modes m
    case "$CMD" in
        status|install|uninstall) ;;
        *) sed -n '2,14p' "$0"; exit 2 ;;
    esac
    # status works on any server (report only); install/uninstall need CentOS 7
    [ "$CMD" = status ] || preflight

    if [ "$CMD" = uninstall ]; then
        # rollback: every install type installed by this script, in reverse install order
        # (scl installs first, so its new dependencies such as gd3php go last)
        modes=$(for m in base scl; do [ -L "$STATE_ROOT/$m/current" ] && echo $m; done)
        [ -n "$modes" ] || die "nothing to roll back ($STATE_ROOT); nothing was installed by this script"
    else
        print_discovery
        command -v rpm >/dev/null 2>&1 && modes=$(detect_modes) || modes=""
        if [ -z "$modes" ]; then
            say "No patchable PHP 7.4 install (Remi php-* 7.4 or php74-php-*)"
            [ "$CMD" = status ] && exit 0 || exit 1
        fi
    fi

    for m in $modes; do
        set_mode "$m"
        case "$CMD" in
            status)    status_mode ;;
            install)   install_mode ;;
            uninstall) uninstall_mode ;;
        esac
    done
    # With both install types, a later transaction can break the PHP checked earlier (for
    # example by replacing a library its extensions use): check every one again.
    if [ "$CMD" = install ] && [ -n "$INSTALLED" ] && [ "$(echo $modes | wc -w)" -gt 1 ]; then
        local failed=0
        for m in $modes; do set_mode "$m"; verify || failed=1; done
        if [ "$failed" = 1 ]; then
            warn "Final verification failed, rolling back automatically"
            rollback_run
            die "the install was rolled back"
        fi
    fi
    [ "$CMD" = install ] && say "To roll back: $0 uninstall"
    return 0
}

main
