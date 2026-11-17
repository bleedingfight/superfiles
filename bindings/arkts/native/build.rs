fn main() {
    let link_search_dir = std::env::var_os("UNIFFI_ARKTS_LINK_SEARCH_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            let default_dir = std::path::Path::new("../libs/arm64-v8a");
            if default_dir.is_absolute() {
                default_dir.to_path_buf()
            } else {
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(default_dir)
            }
        });
    println!("cargo:rustc-link-search=native={}", link_search_dir.display());
    println!("cargo:rustc-link-lib=dylib={}", "superfiles");
}