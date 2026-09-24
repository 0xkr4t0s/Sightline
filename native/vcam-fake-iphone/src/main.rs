//! Test binary that behaves like the iOS app: pairs, then streams scripted
//! motion from `testdata/` (task 1.2.7). For now it only reports its version.

fn version_line() -> String {
    format!(
        "vcam-fake-iphone {} (vcam-protocol {})",
        env!("CARGO_PKG_VERSION"),
        vcam_protocol::VERSION
    )
}

fn main() {
    println!("{}", version_line());
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_line_names_binary_and_protocol() {
        let line = super::version_line();
        assert!(line.starts_with("vcam-fake-iphone "), "{line}");
        assert!(
            line.contains(&format!("vcam-protocol {}", vcam_protocol::VERSION)),
            "{line}"
        );
    }
}
