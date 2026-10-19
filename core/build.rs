// llama.cpp's Metal backend guards newer APIs with @available, which calls
// __isPlatformVersionAtLeast from clang's runtime (libclang_rt.osx.a) whenever the
// deployment target (14.0) is older than the API. clang links that runtime by default,
// but rustc links with -nodefaultlibs, so the test binaries and ft-replay name it here.
// rustc-link-arg does not touch the staticlib: the Swift shell links through clang.
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let out = Command::new("xcrun")
        .args(["clang", "--print-resource-dir"])
        .output()
        .expect("xcrun clang --print-resource-dir");
    let dir = String::from_utf8(out.stdout).expect("utf-8 resource dir");
    let lib = format!("{}/lib/darwin/libclang_rt.osx.a", dir.trim());
    assert!(std::path::Path::new(&lib).exists(), "{lib} not found");
    println!("cargo:rustc-link-arg={lib}");
}
