use clap::Parser;
use ignitix_bootmedia::cli::Cli;

fn main() {
    match Cli::parse().run() {
        Ok(0) => {}
        Ok(status) => std::process::exit(status),
        Err(error) => {
            eprintln!("ignitix-bootmedia: {error:#}");
            std::process::exit(1);
        }
    }
}
