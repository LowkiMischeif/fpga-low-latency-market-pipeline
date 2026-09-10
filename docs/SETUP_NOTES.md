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

## Vivado licensing breaks when WSL2 changes its MAC address

**Symptom.** Simulation and synthesis worked yesterday; today every Vivado
invocation fails immediately:

```
ERROR: Vivado Design Suite cannot be launched because a valid license was not
found. Visit the Vivado Licensing page to choose and generate the right license.
```

The licence file is still present and has not expired -- `~/.Xilinx/Xilinx.lic`
still reads `INCREMENT Vivado_Simulation xilinxd 2027.09 10-sep-2027`.

**Cause.** The licence is node-locked to a `HOSTID`, which on a Linux host is
the MAC address of the primary interface. WSL2 generates its virtual NIC MAC at
boot, and unless it is pinned it changes when WSL restarts. The licence then
names a machine that no longer exists:

```sh
grep -oE 'HOSTID=[^ ;]*' ~/.Xilinx/Xilinx.lic          # e.g. 00155D3C09D3
ip link show eth0 | grep -oE 'link/ether [0-9a-f:]{17}'
```

Strip the colons from the second and compare. A mismatch is this problem.

**Fix.** Pin the MAC on the Windows side so it survives restarts. In
`C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
macAddress=00:15:5d:3c:09:d3
```

using the MAC the licence was issued against, then `wsl --shutdown` and
restart. Regenerating the licence against the new MAC also works once, but is
not a fix: WSL will reassign again.

**Why this is worth writing down.** The error names the licence, and the
licence is fine. Nothing in the message suggests networking, so the obvious
response is to re-download a licence that was never the problem.

## Simulator licensing

Tracked separately; `xsim` additionally requires a Vivado Simulator license
checkout, which is not covered by these notes.
