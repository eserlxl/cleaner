# Maintainer: Eser KUBALI <eserlxl@gmail.com>
pkgname=linux-cleaner
pkgver=1.3.0
pkgrel=1
pkgdesc="Safe, configuration-driven cleaner for caches and temporary files"
arch=('any')
url="https://github.com/eserlxl/cleaner"
license=('GPL-3.0-or-later')
depends=('bash' 'findutils' 'coreutils')
optdepends=('pacman-contrib: paccache-based package-cache actions')
backup=('etc/linux-cleaner/cleaner.conf')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
# SECURITY: 'SKIP' disables source-tarball integrity verification and is a
# PLACEHOLDER ONLY -- no v$pkgver release tarball exists yet to checksum. Before
# any real build or AUR submission, run `updpkgsums` to pin the real sha256 of
# the release tarball (see RELEASING.md "Packaging"). Never publish with SKIP.
sha256sums=('SKIP')

package() {
  cd "$srcdir/cleaner-$pkgver"
  make install DESTDIR="$pkgdir" PREFIX=/usr
}
