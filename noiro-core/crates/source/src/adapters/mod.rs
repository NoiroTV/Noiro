//! Thin adapters that wrap an existing source family as a [`crate::Source`]. They carry no logic of their
//! own: they delegate to the already-tested routing/mapping in `noiro-addons` / `noiro-adapters`.

mod nuvio;
mod stremio;

pub use nuvio::NuvioProviderSource;
pub use stremio::StremioAddonSource;
