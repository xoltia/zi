# zi: a zig installer

zi is a basic tool that helps you install specific versions of Zig from the official index.
It can also install ZLS, either from GitHub releases or by building it from source for use with the latest Zig version.

## Examples
Basic usage: installs from any mirror, first checking if a local install already exists.
```
zi install 0.14.0
```

Force install (maybe necessary if a previous install failed) Zig from the Mach Engine mirror, without trying to also download ZLS.
```
zi install 0.14.1 -f --mirror=https://pkg.machengine.org/zig --skip-zls
```

Mismatched Zig/ZLS versions. Useful if there is no matching ZLS version (such as with 0.14.1).
```
zi install 0.14.0
zi install 0.14.1 --skip-zls
zi use 0.14.0 --zls
```

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
