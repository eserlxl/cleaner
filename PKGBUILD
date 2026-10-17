# Maintainer: Eser KUBALI <eserlxl@gmail.com>
pkgname=linux-cleaner
pkgver=1.5.0
pkgrel=1
pkgdesc="Safe, configuration-driven cleaner for caches and temporary files"
arch=('any')
url="https://github.com/eserlxl/cleaner"
license=('GPL-3.0-or-later')
depends=('bash' 'findutils' 'coreutils')
optdepends=('pacman-contrib: paccache-based package-cache actions')
backup=('etc/linux-cleaner/cleaner.conf')
install=linux-cleaner.install
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
# Pinned sha256 of the v$pkgver release tarball. After each version bump, run
# `updpkgsums` once the tag is pushed (see RELEASING.md "Packaging"); never
# publish with 'SKIP'.
sha256sums=('SKIP')

package() {
  cd "$srcdir/cleaner-$pkgver"
  make install DESTDIR="$pkgdir" PREFIX=/usr
}
