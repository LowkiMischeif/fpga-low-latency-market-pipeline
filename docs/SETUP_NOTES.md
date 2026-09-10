# Environment setup notes

Host-specific quirks encountered while bringing up the toolchain. These are
notes about *the machine*, not about the design; nothing here is required
reading to understand the RTL.

## xsim needs ncurses 5 on Ubuntu 24.04 / WSL2

**Symptom.** Vivado's `xvlog` and `xelab` work, but the simulator itself
refuses to start:

```
$ xsim tb_snap -runall
.../Vivado/bin/unwrapped/lnx64.o/xsim: error while loading shared libraries:
libncurses.so.5: cannot open shared object file: No such file or directory
```

**Cause.** The `xsim` runtime binary is still linked against the ncurses 5
ABI. Ubuntu dropped `libncurses5` after 22.04, so on 24.04 (and the WSL2
images built from it) only `libncurses.so.6` / `libtinfo.so.6` are present and
there is no `libncurses5` package left to install.

**Fix.** The 5 → 6 ABI is compatible for the symbols xsim uses, so symlinks
are enough:

```sh
sudo ln -s /usr/lib/x86_64-linux-gnu/libncurses.so.6 \
           /usr/lib/x86_64-linux-gnu/libncurses.so.5
sudo ln -s /usr/lib/x86_64-linux-gnu/libtinfo.so.6 \
           /usr/lib/x86_64-linux-gnu/libtinfo.so.5
```

Verify with `xsim --version`, which should print `Vivado Simulator v2026.1`
rather than the loader error.

**Do not** work around this by pointing `LD_LIBRARY_PATH` at a private shim
directory. It works, but it has to be re-exported for every shell, CI step and
Makefile recipe, and it silently stops applying the moment something spawns a
clean environment.

## Diagnosing xsim library errors

`ldd` on the xsim binary is misleading here — it reports ~50 missing
`libxv_*`, `libboost_*` and similar entries. Those are Vivado's own bundled
libraries, resolved at run time by the wrapper script's `LD_LIBRARY_PATH`, and
they are not actually missing. Trust the loader error from running `xsim`
itself; that names the one library that genuinely is not on the system.

## Vivado is not on PATH by default

The installer does not modify your shell profile. Either source the settings
script per shell:

```sh
source ~/Xilinx/2026.1/Vivado/settings64.sh
```

or rely on the Makefile, which falls back to the default install path when
`vivado` is absent from PATH. Note that `source ... | head` runs the script in
a subshell and silently does nothing — a pipe will make it look like the
settings script failed.

## Simulator licensing

Tracked separately; `xsim` additionally requires a Vivado Simulator license
checkout, which is not covered by these notes.
