# Bundled FFmpeg

`lib/` contains universal Apple Silicon/Intel macOS dylibs. `include/` contains
the matching public headers. Xcode links these libraries and embeds/signs them
inside `vplay.app/Contents/Frameworks`; no Homebrew installation is needed.

`Legal/` is copied into the app's resources. It includes the LGPL license,
notices, corresponding source archive, and the build script. To rebuild:

```sh
Vendor/FFmpeg/Legal/build-ffmpeg.sh Vendor/FFmpeg
```

This requires Xcode command-line tools, not an installed FFmpeg executable.
No command-line FFmpeg programs are built. Keep the source archive, checksum,
versioned library names, headers, Xcode references, and notices in sync when
updating FFmpeg. Distribution pages must include the FFmpeg acknowledgement
and access to the corresponding source described by FFmpeg's LGPL checklist:
https://ffmpeg.org/legal.html
