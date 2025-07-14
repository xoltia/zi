# zi: a zig installer

zi is a basic tool that helps you install specific versions of Zig from the official index.
It can also install ZLS, either from GitHub releases or by building it from source for use with the latest Zig version.

## Usage

```
 zi is a simple Zig version manager.
 
 Usage:
     zi [OPTIONS] [SUBCOMMAND]
 
 Subcommands:
     ls                   List Zig versions
     ls-mirrors           List available mirrors
     install <version>    Install a specific remote Zig version
     use [version]        Switch to a specific local Zig version,
                          using .zirc if version is omitted
 
 Flags:
     -h, --help           Print help information
     -V, --version        Print version information
 
 Flags for `ls` subcommand:
     -r, --remote         List only remote versions
     -l, --local          List only local versions
 
 Flags for `install` subcommand:
     -f, --force          Remove the existing download if it exists
     -s, --skip-zls       Skip downloading and/or linking the ZLS executable
         --mirror=<url>   Use a specific mirror (must be in the community-mirrors.txt
                          format; see https://ziglang.org/download/community-mirrors)
         --no-mirror      Download directly from ziglang.org (not recommended)
     -s, --skip-zls       Skip downloading and/or linking the ZLS executable
 
 Flags for `use` subcommand:
     --zls                Change only the ZLS version, useful for mismatching ZLS
                          and Zig versions
 
 Environment variables:
     ZI_INSTALL_DIR       Directory to install Zig versions (default: $HOME/.zi)
     ZI_LINK_DIR          Directory to create symlinks for the active Zig version
                          (default: $HOME/.local/bin)
 
```

