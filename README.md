# el7-php74-security

Patched PHP 7.4 RPMs for **CentOS 7** (Remi packages) fixing
**CVE-2026-109618** and **CVE-2026-109619** (GHSA-w8hw-w9fx-j79w, GHSA-6wmf-4rv5-p3rp).
The repo also includes an installer that finds the PHP installs on a server, upgrades
them and can roll the upgrade back.

These are **Remi Collet's own `7.4.33-31` packages, which carry the official fix**, rebuilt
for CentOS 7. Remi stopped publishing EL7 builds of PHP 7.4 in June 2024 at `7.4.33-15`, but
kept updating the source packages. Rebuilding them gives EL7 servers this fix and every
security fix Remi backported to 7.4 between `-16` and `-31`.

> ⚠️ PHP 7.4 has been end-of-life since November 2022 and CentOS 7 since June 2024. This is
> a stop-gap. The real fix is to move to a supported OS and PHP version. Test on a
> non-production server first.

## Quick start

```bash
curl -fLO https://raw.githubusercontent.com/bagsiz/el7-php74-security/main/php74-cve.sh
chmod +x php74-cve.sh

./php74-cve.sh status      # list every PHP on the server and its patch status
./php74-cve.sh install     # upgrade installed PHP 7.4 packages (asks for confirmation; -y to skip)
./php74-cve.sh uninstall   # roll back to the previous versions
```

The RPMs are published as [release assets](https://github.com/bagsiz/el7-php74-security/releases/tag/v7.4.33-31.1).
`install` downloads the archive it needs and checks it against a SHA256 that is hardcoded
in the script. If the server has no internet access, download the archive by hand and put
it next to the script.

> **Old CentOS 7 (7.0–7.3) with the original CA bundle:** the stock `ca-certificates` of
> those releases does not trust the certificates of `raw.githubusercontent.com` and GitHub's
> release download host, so `curl` fails with a TLS/certificate error. Run
> `yum update ca-certificates`, or download the files on another machine and copy them over.

### Network timeouts

Network waits are capped at **10 seconds** so the script does not hang on unreachable
hosts. This matters on CentOS 7 servers, which are EOL and often still list dead mirrors
such as `mirrorlist.centos.org`.

| Step | Behaviour |
|---|---|
| Release download (`curl`) | Gives up if no connection is made within 10s, or if the download stalls (below 1 KB/s) for 10s. No retry. A slow download that is still moving is not cut off |
| `yum` / `yumdownloader` (backup, `rpmrebuild` install, install, rollback) | 10s per request, one retry (in yum, `0` would mean "retry forever"), and unreachable repositories are skipped (`skip_if_unavailable`) |

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `PHP74CVE_NET_TIMEOUT` | `10` | Network timeout in seconds, e.g. `PHP74CVE_NET_TIMEOUT=30 ./php74-cve.sh install` on a slow link |
| `PHP74CVE_RELEASE_URL` | this repo's `v7.4.33-31.1` release | Download the archives from a mirror or an internal server instead |

## What it detects

`status` and `install` start by listing every PHP they can find on the server:

- the `php`, `php74`, `php7.4`, `php-fpm` and `php-cgi` commands (symlinks are resolved)
- copies under `/usr/local` and `/opt`, and under `/opt/remi/php*`
- running `php-fpm` master processes
- PHP modules loaded by Apache (mod_php)

For each binary it looks up the RPM that owns it:

| Found | Action |
|---|---|
| `php`, `php-cli`, `php-fpm`, … **7.4.x** from Remi `remi-php74` (`/usr/bin/php`, `php-fpm` service, mod_php) | upgraded with `php74-rpms-base` |
| `php74-php-*` from Remi SCL (`/opt/remi/php74`, `php74-php-fpm` service) | upgraded with `php74-rpms-scl` |
| Both on one server | both are upgraded |
| Webtatic `php74w`, IUS `php74u`, Debian/Ubuntu `php7.4`, source builds, PHP other than 7.4 | reported only, not changed |

Example `status` output from a server with base PHP 7.0, mod_php and PECL extensions:

```
==> PHP on this server
  [patchable: base] /usr/bin/php  [PHP 7.4.33]  (command 'php')
  [patchable: base] /usr/sbin/php-fpm  [PHP 7.4.33]  (command 'php-fpm'; RUNNING: php-fpm master pid 192)
  [patchable: base] /usr/lib64/httpd/modules/libphp7.so  [PHP 7.4.33]  (Apache module (/etc/httpd/conf.modules.d/15-php.conf))
  [left as is     ] /usr/local/bin/php  [PHP 7.4.33]  (command 'php') : not owned by any package: built from source / copied by hand (not supported)
==> Installed packages: php (base, remi-php74)
  php                              7.4.33-14.el7.remi       UNPATCHED (patched build available)
  php-cli                          7.4.33-14.el7.remi       UNPATCHED (patched build available)
  php-common                       7.4.33-14.el7.remi       UNPATCHED (patched build available)
  php-pecl-redis5                  5.3.4-1.el7.remi.7.0     left as is (not shipped here)
  ...
==> Services
  php-fpm          active
  httpd            active
```

The script only replaces PHP packages that are already installed. It does not touch
packages that are not in the release, such as PECL extensions (`php-pecl-*`), `php-pear`
or `php74-runtime`. PECL extensions keep working because the PHP API/ABI is unchanged.

## What `install` does

1. Runs pre-flight checks: root, CentOS 7, x86_64, and `php-fpm -t` must already pass.
2. Downloads the RPM archive and verifies it against the pinned SHA256, then verifies
   each RPM against `SHA256SUMS`.
3. Saves a backup under `/var/lib/php74-cve-2026/<base|scl>/backup-<timestamp>/`:
   - the RPMs of the currently installed versions (see [Rollback backups](#rollback-backups))
   - the PHP configuration (`/etc/php.ini`, `/etc/php.d`, `/etc/php-fpm.d`, `/etc/opt/remi/php74`, …)
   - the list of services that were running
4. Upgrades the packages with `yum localinstall`.
5. Checks the result:
   - `php -v`
   - `php -m` must load without warnings
   - the changelog must contain the CVE
   - `php-fpm -t` and `apachectl -t` must pass
6. Restarts the services that were running (`php-fpm` / `php74-php-fpm`, `httpd`).
7. **Rolls back automatically** if any of these steps fails.

`uninstall` puts the backed-up RPMs back with `rpm -Uvh --oldpackage`, so the server
returns to exactly the versions it had. Configuration files are not restored
automatically; the backup path is printed.

**Packages replaced by the install.** The patched `php-gd` links Remi's `gd3php`, which
obsoletes `gd-last`. On a server whose current `php-gd` is an older build that needs
`gd-last` (`libgd.so.3`), yum therefore removes `gd-last` during the install. The script
detects this beforehand (yum dry run), backs `gd-last` up together with the PHP RPMs, and
`uninstall` puts it back and removes `gd3php` again once nothing needs it.

**Extensions copied by hand.** A PHP extension that is on disk without a package (for
example `/usr/lib64/php/modules/gd.so` copied from another build, with no `php-gd`
installed) still uses the libraries it was built against, which rpm does not know about.
When the patched package of that extension exists here, `install` installs it in place of
the copied files (listed before confirming, backed up to `adopted-files.tar.gz`);
`uninstall` removes the package and puts the original files back.

**Order and final check.** With both install types on one server, SCL is upgraded first,
then base. Afterwards both PHP installs are checked again (`php -m` without warnings,
`php-fpm -t`, …), since a later transaction can break the PHP checked earlier, for example
by replacing a library a hand-copied extension needs. If any check fails, every install
type upgraded in that run is rolled back.

**Known limitation:** when base `php-gd` and SCL `php74-php-gd` are both installed and
both are such older builds, each install type's transaction would remove `gd-last` that
the other one still needs. yum refuses that transaction and nothing is changed ("yum
install failed"). Upgrade or remove one of the two `gd` packages first.

### Rollback backups

yum does not keep the `.rpm` files of installed packages by default (`keepcache=0`), and
Remi's EL7 repositories only still carry the newest builds (`7.4.33-14` and `-15`). A
server running an older build, such as `7.4.14-1` or `7.4.30-1`, usually has that RPM
nowhere. Before upgrading, the script therefore looks for the RPM of each installed
version in this order:

| # | Source | Notes |
|---|---|---|
| 1 | **yum cache** (`/var/cache/yum`) | Present when `keepcache=1` or the package was downloaded earlier. The file must match the exact name-version-release and pass `rpm -K` |
| 2 | **repositories** (`yumdownloader`) | The exact version, if the repository still has it |
| 3 | **`rpmrebuild`** | Rebuilds the RPM from the RPM database and the installed files. The result is **unsigned** and not byte-identical to the original, and config files go in as they are on disk now. Files missing on disk (docs not installed, files deleted by hand) are left out. See [rpmrebuild on servers without repositories](#rpmrebuild-on-servers-without-repositories) |
| – | none of the above | The script warns and asks before continuing. `uninstall` then moves those packages to the newest version left in the repositories (Remi `7.4.33-15`, unpatched) |

#### rpmrebuild on servers without repositories

Old servers often cannot reach EPEL or the CentOS repositories, so `rpmrebuild` and
`rpm-build` cannot be installed from there. The release therefore also ships
`el7-rpmrebuild-tools.tar.gz`:

- `rpmrebuild-2.11-3.el7` from EPEL 7
- `rpm-build` for every `rpm` version CentOS 7 shipped, 13 in all from 7.0 to 7.9
  (`4.11.1-16` … `4.11.3-48.el7_9`). `rpm-build` only installs on the exact `rpm` version
  it was built for
- all packages are signed by CentOS 7 or EPEL 7 (`rpm -K` checked); the archive's SHA256
  is pinned in the script

When `rpmrebuild` is needed and not installed, the script uses these tools in this order:

1. It takes the `rpm-build` that matches the server's `rpm` and installs it together with
   `rpmrebuild` using `rpm -i --nodeps`. Rebuilding installed files needs neither perl,
   gdb nor `redhat-rpm-config`, which `rpm-build` would otherwise pull in.
2. It removes both packages again once the backup is done. Packages that were already
   installed are left alone.
3. Only if this fails does it try `yum install rpmrebuild`.

The rebuilt packages use SHA256 file digests and an xz payload, like the originals.

The source used for each package is printed during `install` and `uninstall`, and is
recorded in `sources.txt` inside the backup directory:

```
==> Creating backup: /var/lib/php74-cve-2026/base/backup-20261022-101500
  configuration: /var/lib/php74-cve-2026/base/backup-20261022-101500/config.tar.gz
  php-cli-7.4.14-1.el7.remi.x86_64                  rebuild
  php-common-7.4.14-1.el7.remi.x86_64               rebuild
  ...
  RPMs of the current versions: 10/10 backed up
WARNING: some RPMs were rebuilt from the installed files with rpmrebuild (unsigned, not identical to the original)
```

## Package contents (`7.4.33-31.1.el7`)

> `31.1` replaces `31`. The `31` packages were built on CentOS 7.9 and need openssl 1.0.2,
> so they do not run on CentOS 7.0–7.3 (openssl 1.0.1e). `31.1` adds
> `php-7.4-el7-openssl101-compat.patch` (see below). Servers on `31` are upgraded by `install`.

Both builds come from Remi Collet's `7.4.33-31` source packages (2026-10-21). They already
contain the fix as `php-7.4-cve-2026-109618.patch` ("Avoid state corruption via bailout"),
along with every security fix Remi backported to 7.4 since the last EL7 build (`-15`, June
2024). They were rebuilt for CentOS 7; the only code change is the openssl compatibility
patch.

- **base** (`php74-rpms-base.tar.gz`, `php-*`): Remi's `php-7.4.33-31` SRPM, which is the
  package `remi-php74` servers run. File lists, config files, scriptlets, provides and
  requires were compared with Remi's last EL7 build (`7.4.33-15.el7.remi`) and are identical
  in 89 of 90 checks. Only the version strings differ, and one sentence of the post-install
  EOL notice ("backported from 8.1" → "8.2").
- **scl** (`php74-rpms-scl.tar.gz`, `php74-php-*`): Remi's `php74-php-7.4.33-31` SRPM.

Build notes, the same as Remi's own EL7 builds:

- Built with `devtoolset-11` (GCC 11), because the ICU headers need C++11.
- `intl` is built against `libicu73` (Remi's EL7 ICU). The spec asks for ICU ≥ 74, but its
  ICU 74 patch only changes the C++ standard for ICU 74 and later.
- The SRPMs were checked against Remi's 2026 key before building (`rpm -K`: `digests
  signatures OK`).

### Runs on every CentOS 7 release (7.0–7.9)

The packages are built on CentOS 7.9, which has openssl 1.0.2k. Linked against it, PHP used
five functions that CentOS 7.0–7.3 (openssl 1.0.1e) do not have:

- `SSLeay_version` in its `OPENSSL_1.0.2` symbol version
- `X509_get_signature_nid`
- `SSL_CTX_set_alpn_protos`, `SSL_CTX_set_alpn_select_cb` and `SSL_get0_alpn_selected` (ALPN)

`php-7.4-el7-openssl101-compat.patch` (in `ext/openssl/openssl.c` and `xp_ssl.c`) no longer
links these functions. It looks them up at run time with `dlsym()` in the already loaded
`libssl`/`libcrypto`:

- **CentOS 7.4–7.9 (openssl 1.0.2k):** everything works as before, including ALPN.
- **CentOS 7.0–7.3 (openssl 1.0.1e):** PHP behaves as when built against openssl 1.0.1.
  The `alpn_protocols` stream context option gives a warning and is ignored.

After the patch, every `libssl`/`libcrypto` symbol the packages use (361) exists in CentOS
7.0's openssl. This was checked on the built binaries.

**Known limitation, `php-gd` on CentOS 7.0–7.5:** `php-gd` uses Remi's `gd3php`, which
pulls `libraqm` from EPEL, which needs fribidi ≥ 1.0. fribidi 1.0 arrived in CentOS 7.6.
Remi's own builds have the same dependency. On older releases `gd.so` fails to load. The
installer's verification sees the load warning and rolls the upgrade back. Updating
`fribidi` fixes it.

## Behaviour changes

These come from the upstream fix:

- A request that exceeds `memory_limit` (or hits another out-of-memory condition)
  terminates the worker process with `exit(1)` instead of unwinding. PHP-FPM starts a new
  worker. Shutdown functions and destructors do not run for that request.
- The out-of-memory fatal error goes to stderr, not to `error_log`. To see it in the
  PHP-FPM log, set `catch_workers_output = yes` in the pool configuration.
- `session.upload_progress` is disabled.

## FAQ

**Packages marked "left as is" (`php-pecl-*`, …): are they vulnerable, do they need updating?**
Not for these CVEs. CVE-2026-109618/109619 are in the PHP core: the Zend engine, request
startup and shutdown, multipart parsing and the session extension. Those are fixed by
upgrading `php-common`, `php-cli`, `php-fpm` and the other core packages. PECL extensions
are separate code that runs inside the patched core, so they don't need to change. They
can still have issues of their own. For example, `php-pecl-xdebug` should not be installed
on production servers.

**The script reports a PHP as "left as is" (not supported). What now?**
That PHP was not installed from Remi's packages: it may be a source build, Webtatic, IUS,
a Debian/Ubuntu package, or a version other than 7.4. It has to be patched or upgraded
some other way.

## Testing

Everything was tested in clean CentOS 7 containers against Remi's `7.4.33-15` packages
(the last EL7 build):

- **Installer, base and SCL:** install, re-install (no-op), uninstall, rollback when backup
  RPMs are missing, automatic rollback when verification fails, a tampered RPM or archive
  being refused, and no PHP on the host. PECL extensions (igbinary, redis5, memcached)
  keep loading.
- **php-src test suite**, about 4,100 tests: Zend, basic, lang, session and string tests,
  run on the SCL build. The only differences from Remi's `7.4.33-15` are the expected ones:
  the `session.upload_progress` (`rfc1867*`) tests fail, and one out-of-memory message has
  a cosmetic difference.
- **Old CentOS 7 (openssl 1.0.1e):** tested on `centos:7.3.1611` for base and SCL. The
  patched packages install through the installer, and the following work: PHP, php-fpm,
  the openssl extension and the `alpn_protocols` option (warning, no crash). mysqlnd, pdo,
  xml, mbstring, intl, opcache, soap, process, bcmath, ldap and pgsql load without
  warnings; gd is the exception, see the known limitation above.
- **Rollback backups and bundled `rpmrebuild`:** same code as `el7-php70-security`, which
  was tested with the yum cache only, the repositories only, `rpmrebuild` only, an offline
  server, and the bundled `rpm-build` on every CentOS 7 release (`7.0.1406` … `7.9.2009`).
- **`gd-last` replaced by the install:** an SCL server whose `php74-php-gd` needs `gd-last`
  (as older Remi builds do). The install removed `gd-last`; `uninstall` restored it from
  the backup, removed `gd3php`, and the old `gd` extension loaded again with no unsatisfied
  dependencies in the RPM database (8 checks).
- **Hand-copied extension:** a server with SCL `php-gd` needing `gd-last` and base mod_php
  loading a hand-copied `gd.so` linked to `gd-last` (no `php-gd` package). `install`
  installed the patched `php-gd` in its place, and both PHPs loaded gd. `uninstall`
  restored the original files byte for byte (15 checks). With an extension that has no
  patched package (`gd_custom.so`), the base check failed and both install types were
  rolled back to the exact previous state (11 checks).
- **Not covered:** real systemd and Apache. The containers used a stub `systemctl`. Run
  `status` and `install` on one server and check the output before rolling out further.

## Disclaimer

**USE AT YOUR OWN RISK.** This project, including the installer script, the patches and
the RPM packages, is provided **"AS IS", WITHOUT WARRANTY OF ANY KIND**, express or implied.
This includes, without limitation, warranties of merchantability, fitness for a particular
purpose, security and non-infringement.

- **Not official.** The packages are unofficial rebuilds of Remi Collet's source packages.
  They are not built, reviewed or supported by Remi Collet, Red Hat or the PHP project, and
  may contain build or packaging problems.
- **Your responsibility.** You decide whether to use this software, and you are
  responsible for testing it, for backing up your systems and data, and for any change you
  make to your servers. Running unsupported software (CentOS 7, PHP 7.4) carries risk that
  no patch removes. The recommended long-term fix is to move to a supported operating
  system and PHP version.
- **No liability.** In no event shall the authors or contributors be liable for any claim,
  damages or other liability arising from, out of, or in connection with this software or
  its use. This covers direct, indirect, incidental, special, consequential or punitive
  damages, data loss, downtime and security incidents, whether in contract, tort or
  otherwise, even if advised of the possibility of such damage.
- **No support obligation.** There is no commitment to support, maintenance, updates or
  security fixes.
- **Not security advice.** Nothing in this repository is professional, security or legal
  advice.
- **No affiliation.** This project is not affiliated with, endorsed by or sponsored by:
  - The PHP Group or the PHP project
  - Remi Collet / remirepo
  - Red Hat, Inc. or the CentOS Project
  - GitHub, Inc.

  "PHP", "CentOS", "Red Hat" and other names are trademarks of their respective owners
  and are used here only to describe compatibility.

## License

- **Installer script and documentation** (`php74-cve.sh`, `README.md`): MIT License, see
  [`LICENSE`](LICENSE).
- **RPM packages (release assets):** these contain third-party software that stays under
  its original license:
  - PHP is under the [PHP License v3.01](https://www.php.net/license/3_01.txt). The PHP
    patches in the source packages are derived from php-src and fall under the same
    license.
  - Zend Engine is under the Zend Engine License v2.00.
  - Bundled libraries and extensions are under their own licenses.
  - The RPM spec files and packaging come from Remi's repository under the MIT License.

  License texts are included in the packages: `/usr/share/licenses/php-common-7.4.33/`
  for base, `/opt/remi/php74/root/usr/share/licenses/php74-php-common-7.4.33/` for SCL.

This product includes PHP software, freely available from <http://www.php.net/software/>.
