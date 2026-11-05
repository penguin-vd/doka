#!/bin/sh
# Inside the container of scripts/package.sh: /src the repository, read-only; /dist the output.
set -eu
arch=$(uname -m)
multiarch=$arch-linux-gnu
work=$(mktemp -d)
export HOME=$work
appdir=$work/AppDir

cd /src
# Baseline: any CPU of this architecture, not only the one that built it.
zig build -Doptimize=ReleaseSafe -Dcpu=baseline --prefix "$work/build" --cache-dir "$work/cache" --global-cache-dir "$work/zig"
# linuxdeploy's own strip is too old for this system's libraries, which are stripped already.
strip "$work/build/bin/doka"

# GTK draws symbolic icons through gdk-pixbuf's SVG loader; JPEG and PNG it reads itself.
loaders=$appdir/usr/lib/gdk-pixbuf/loaders
mkdir -p "$loaders"
cp "/usr/lib/$multiarch/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so" "$loaders/"
"/usr/lib/$multiarch/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders" "$loaders"/*.so | sed "s|$loaders/||" >"$appdir/usr/lib/gdk-pixbuf/loaders.cache"

mkdir -p "$appdir/usr/share/glib-2.0/schemas" "$appdir/usr/share/icons/Adwaita"
cp /usr/share/glib-2.0/schemas/org.gtk.gtk4.*.gschema.xml "$appdir/usr/share/glib-2.0/schemas/"
glib-compile-schemas "$appdir/usr/share/glib-2.0/schemas"
cp /usr/share/icons/Adwaita/index.theme "$appdir/usr/share/icons/Adwaita/"
cp -R /usr/share/icons/Adwaita/symbolic "$appdir/usr/share/icons/Adwaita/"
mkdir -p "$appdir/usr/share/doka"
cp -R /src/zig-out/package/looks "$appdir/usr/share/doka/looks"
# gdk-pixbuf tells an SVG by its MIME type, from this database.
mkdir -p "$appdir/usr/share/mime"
find /usr/share/mime -maxdepth 1 -type f -exec cp {} "$appdir/usr/share/mime/" \;
# Empty, so the system's GIO modules, built for its own GLib, aren't loaded into ours.
mkdir -p "$appdir/usr/lib/gio/modules"

cd "$work"
# linuxdeploy's list leaves these to the system, but a clean one doesn't have them.
extra=
for lib in libcom_err.so.2 libfontconfig.so.1 libfreetype.so.6 libfribidi.so.0 libharfbuzz.so.0; do
    extra="$extra --library /usr/lib/$multiarch/$lib"
done
# libstdc++ stays the system's: its OpenGL driver may need a newer one than this one, and only one loads.
NO_STRIP=1 ARCH=$arch OUTPUT=Doka-$arch.AppImage APPIMAGE_EXTRACT_AND_RUN=1 \
    linuxdeploy --appdir "$appdir" \
    --executable "$work/build/bin/doka" \
    --deploy-deps-only "$loaders" $extra \
    --exclude-library 'libstdc++*' --exclude-library 'libgcc_s*' \
    --desktop-file /src/scripts/package/doka.desktop \
    --icon-file /src/scripts/package/doka.svg \
    --custom-apprun /src/scripts/package/AppRun \
    --output appimage
cp "Doka-$arch.AppImage" /dist/
ls -l "/dist/Doka-$arch.AppImage"
