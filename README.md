# zig installer

zi is a simple zig installer. Supports installation of tagged Zig versions available from
the official index, as well as ZLS installation (including master compilation).

## Usage

```
Usage:
    zi [OPTIONS] [SUBCOMMAND]

Subcommands:
    ls                   List Zig versions
    install <version>    Install a specific Zig version

Flags:
    -h, --help           Print help information
    -V, --version        Print version information

Flags for `ls` subcommand:
    -r, --remote         List only remote versions
    -l, --local          List only local versions

Environment variables:
    ZI_INSTALL_DIR       Directory to install Zig versions (default: $HOME/.zi)
    ZI_LINK_DIR          Directory to create symlinks for the active Zig version (default: $HOME/.local/bin)
```

## TODO
- [ ] Progress messages
- [ ] Better error handling
- [ ] Version removal
