// A made-up Rust part: two functions for the extension, and two commented out.

#[raycast]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[raycast]
async fn count(items: Vec<String>, limits: HashMap<String, u32>) -> Result<u32, String> {
    Ok(items.len() as u32)
}

// #[raycast]
// fn hidden() {}

/*
#[raycast]
fn also_hidden() -> u32 { 0 }
*/

fn main() {}
