# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Pinned media dependencies: same tarballs as renpy-build renpy-8.5.3.26051504 (SHA-256 verified
# against renpy-build/source/, docs/RESEARCH.md section 26).
$MediaDeps = [ordered]@{
    libpng       = @{ ver = '1.6.43'; file = 'libpng-1.6.43.tar.gz'; url = 'https://download.sourceforge.net/libpng/libpng-1.6.43.tar.gz'; sha = 'e804e465d4b109b5ad285a8fb71f0dd3f74f0068f91ce3cdfde618180c174925' }
    libjpeg      = @{ ver = '1.5.3'; file = 'libjpeg-turbo-1.5.3.tar.gz'; url = 'https://downloads.sourceforge.net/libjpeg-turbo/libjpeg-turbo-1.5.3.tar.gz'; sha = 'b24890e2bb46e12e72a79f7e965f409f4e16466d00e1dd15d93d73ee6b592523' }
    libwebp      = @{ ver = '1.3.2'; file = 'libwebp-1.3.2.tar.gz'; url = 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.3.2.tar.gz'; sha = '2a499607df669e40258e53d0ade8035ba4ec0175244869d1025d460562aa09b4' }
    freetype     = @{ ver = '2.13.3'; file = 'freetype-2.13.3.tar.gz'; url = 'https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz'; sha = '5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747' }
    harfbuzz     = @{ ver = '8.0.1'; file = 'harfbuzz-8.0.1.tar.xz'; url = 'https://github.com/harfbuzz/harfbuzz/releases/download/8.0.1/harfbuzz-8.0.1.tar.xz'; sha = 'c1ce780acd385569f25b9a29603d1d5bc71e6940e55bfdd4f7266fad50e42620' }
    fribidi      = @{ ver = '1.0.7'; file = 'fribidi-1.0.7.tar.bz2'; url = 'https://github.com/fribidi/fribidi/releases/download/v1.0.7/fribidi-1.0.7.tar.bz2'; sha = '5ab5f21e9f2fc57b4b40f8ea8f14dba78a5cc46d9cf94bc5e00a58e6886a935d' }
    # AVIF support (decode only): libavif 0.11.1 = the version renpy-build pins for Ren'Py 8.5.3,
    # with dav1d as the AV1 decoder (faster than aom and decode-only, so no encoder to build).
    dav1d        = @{ ver = '1.4.3'; file = 'dav1d-1.4.3.tar.gz'; url = 'https://code.videolan.org/videolan/dav1d/-/archive/1.4.3/dav1d-1.4.3.tar.gz'; sha = '88a023e58d955e0886faf49c72940e0e90914a948a8e60c1326ce3e09e7a6099' }
    libavif      = @{ ver = '0.11.1'; file = 'libavif-0.11.1.tar.gz'; url = 'https://github.com/AOMediaCodec/libavif/archive/refs/tags/v0.11.1.tar.gz'; sha = '0eb49965562a0e5e5de58389650d434cff32af84c34185b6c9b7b2fccae06d4e' }
    # Fallback decoder only (used if meson/dav1d cannot be built in the UWP environment). No pinned
    # hash yet: the build prints the computed SHA-256 so it can be pinned here after the first run.
    aom          = @{ ver = '3.5.0'; file = 'aom-3.5.0.tar.gz'; url = 'https://aomedia.googlesource.com/aom/+archive/refs/tags/v3.5.0.tar.gz'; sha = '03a8b05b174b92a87bd1ace88539da2eb183398dc46ee786cb789ca226f151ee' }
    sdl2_image   = @{ ver = '2.6.2'; file = 'SDL2_image-2.6.2.tar.gz'; url = 'https://github.com/libsdl-org/SDL_image/releases/download/release-2.6.2/SDL2_image-2.6.2.tar.gz'; sha = '48355fb4d8d00bac639cd1c4f4a7661c4afef2c212af60b340e06b7059814777' }
    ffmpeg       = @{ ver = '4.3.1'; file = 'ffmpeg-4.3.1.tar.gz'; url = 'https://ffmpeg.org/releases/ffmpeg-4.3.1.tar.gz'; sha = '45035f15d6f192772de2309c846e1d60472694f479679354a39c699719e53772' }
}
