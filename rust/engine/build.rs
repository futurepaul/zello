fn main() {
    // Optional for later: generate bindings/include/mcore.h with cbindgen.
    // For now we use a hand-written header in /bindings to get going.
    println!("cargo:rerun-if-changed=src/lib.rs");
}
