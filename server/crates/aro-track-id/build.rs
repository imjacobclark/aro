fn main() {
    // Dynamically link the real libchromaprint (see src/fingerprint.rs for why).
    // pkg-config finds it via `chromaprint.pc`, installed alongside the library by
    // both Homebrew (`chromaprint`) and Debian/Ubuntu (`libchromaprint-dev` at build
    // time, `libchromaprint1` at runtime).
    pkg_config::Config::new()
        .probe("libchromaprint")
        .expect(
            "libchromaprint not found via pkg-config — install it \
             (macOS: `brew install chromaprint`; Debian/Ubuntu: `apt-get install libchromaprint-dev`)",
        );
}
