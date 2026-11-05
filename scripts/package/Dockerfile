# What the AppImage is built on. Its glibc is the oldest the AppImage runs on; GTK 4.10 is the
# oldest Doka compiles against (GtkFileDialog).
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    adwaita-icon-theme binutils ca-certificates curl file libgdk-pixbuf2.0-bin libgl-dev \
    libglib2.0-dev-bin libgtk-4-dev libopengl-dev librsvg2-common libvips-dev pkg-config shared-mime-info xz-utils
RUN curl -fsSL "https://ziglang.org/download/0.16.0/zig-$(uname -m)-linux-0.16.0.tar.xz" | tar -xJ -C /opt \
    && ln -s "/opt/zig-$(uname -m)-linux-0.16.0/zig" /usr/local/bin/zig
# Unpacked, since a container has no FUSE to mount an AppImage with.
RUN cd /opt && curl -fsSLo linuxdeploy "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$(uname -m).AppImage" \
    && chmod +x linuxdeploy && ./linuxdeploy --appimage-extract >/dev/null && mv squashfs-root linuxdeploy-dir && rm linuxdeploy \
    && chmod -R a+rX linuxdeploy-dir && ln -s /opt/linuxdeploy-dir/AppRun /usr/local/bin/linuxdeploy
