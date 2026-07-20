use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let ver = std::fs::read_to_string(dir.join("version"))
        .expect("failed to read version file")
        .trim()
        .to_string();

    if std::env::var_os("CARGO_CFG_TARGET_OS").as_deref() == Some(std::ffi::OsStr::new("windows")) {
        let mut res = winres::WindowsResource::new();
        res.set("FileVersion", &ver);
        res.set("ProductVersion", &ver);
        res.set("ProductName", "Scoop Shim Ex");
        res.set("CompanyName", "Scoop contributors");
        res.set(
            "LegalCopyright",
            "Copyright (c) 2013-present Scoop contributors",
        );
        res.set("OriginalFilename", "shim.exe");
        res.compile().expect("failed to compile Windows resource");
    }
}
