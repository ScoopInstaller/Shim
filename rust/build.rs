use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=version");
    println!("cargo:rerun-if-changed=../shim.manifest");

    let dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let ver_path = dir.join("version");
    let lane = std::fs::read_to_string(&ver_path)
        .unwrap_or_else(|e| panic!("failed to read version file {}: {e}", ver_path.display()));
    let mut lines = lane.lines().map(str::trim).filter(|line| !line.is_empty());
    let ver = lines
        .next()
        .unwrap_or_else(|| panic!("version file {} has no version line", ver_path.display()));
    let features = lines
        .next()
        .unwrap_or_else(|| panic!("version file {} has no feature line", ver_path.display()));
    if lines.next().is_some() {
        panic!(
            "version file {} has more than two lines",
            ver_path.display()
        );
    }

    println!("cargo:rustc-env=SHIM_VERSION={ver}");
    println!("cargo:rustc-env=SHIM_FEATURES={features}");

    if std::env::var_os("CARGO_CFG_TARGET_OS").as_deref() == Some(std::ffi::OsStr::new("windows")) {
        let mut res = winres::WindowsResource::new();
        // Pack FILEVERSION/PRODUCTVERSION from `version`; winres would default them to Cargo.toml's.
        let mut parts = [0u16; 4];
        for (i, part) in ver.split('.').take(4).enumerate() {
            parts[i] = part.parse().expect("version file part is a u16");
        }
        let packed = ((parts[0] as u64) << 48)
            | ((parts[1] as u64) << 32)
            | ((parts[2] as u64) << 16)
            | (parts[3] as u64);
        res.set_version_info(winres::VersionInfo::FILEVERSION, packed);
        res.set_version_info(winres::VersionInfo::PRODUCTVERSION, packed);
        res.set("FileVersion", &ver);
        res.set("ProductVersion", &ver);
        res.set("ProductName", "Scoop Shim Ex");
        res.set("CompanyName", "Scoop contributors");
        res.set(
            "LegalCopyright",
            "Copyright (c) 2013-present Scoop contributors",
        );
        res.set("Comments", &format!("Features: {features}"));
        res.set("OriginalFilename", "shim.exe");
        res.set_manifest_file("../shim.manifest");
        res.compile().expect("failed to compile Windows resource");
    }
}
