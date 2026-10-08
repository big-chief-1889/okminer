// Embeds the app icon in the Windows .exe.
fn main() {
    println!("cargo:rerun-if-changed=../icons/windows/okminer.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out = std::env::var("OUT_DIR").unwrap();
    let ico = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../icons/windows/okminer.ico");
    let (rc, res) = (format!("{out}/okminer.rc"), format!("{out}/okminer.res"));
    std::fs::write(&rc, format!("1 ICON \"{}\"\n", ico.display())).unwrap();
    let windres = std::env::var("WINDRES").unwrap_or_else(|_| "x86_64-w64-mingw32-windres".into());
    let ok = std::process::Command::new(windres)
        .args([&rc, "-O", "coff", "-o", &res])
        .status()
        .is_ok_and(|s| s.success());
    assert!(ok, "windres failed");
    println!("cargo:rustc-link-arg-bins={res}");
}
