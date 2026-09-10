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

## Vivado licensing under WSL2: use mirrored networking

The free Basic Tier licence is node-locked to a `HOSTID`, which on Linux is the
MAC address of the primary interface. Under WSL2's default NAT networking,
`eth0` is a virtual NIC whose MAC is regenerated at boot, so a licence issued
today stops working the next time WSL restarts:

```
ERROR: Vivado Design Suite cannot be launched because a valid license was not
found. Visit the Vivado Licensing page to choose and generate the right license.
```

The licence file is fine when this happens -- `~/.Xilinx/Xilinx.lic` is present
and unexpired. Nothing in the message suggests networking, which is why the
obvious response is to re-download a licence that was never the problem.

**Fix: mirrored networking.** In `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

then `wsl --shutdown` and restart. `eth0` inside WSL now carries the *physical*
Ethernet adapter's MAC, which does not change across reboots. Issue the Basic
Tier licence against that MAC and it keeps working.

Verify the two agree:

```sh
ip link show eth0 | grep -oE 'link/ether [0-9a-f:]{17}'
grep -oE 'HOSTID=[^ ;]*' ~/.Xilinx/Xilinx.lic
```

Strip the colons from the first; they must match. Then confirm the toolchain
actually launches, which is a stronger check than reading the licence file:

```sh
vivado -mode batch -source /dev/null    # exits 0
make sim TOP=tb_market_pkg              # PASS
```

**Approaches that did not work**, recorded so they are not retried:

- `macAddress=` in `.wslconfig` under default NAT networking. Pins the virtual
  NIC, but the licence still has to be reissued whenever the pinned value is
  changed, and it does not survive a networking-mode change.
- A `[boot]` command in `/etc/wsl.conf` setting the MAC, or adding a dummy
  interface with the licensed MAC. Both alter an interface Vivado's licence
  check does not end up reading, so the HOSTID it sees is unchanged.

Mirrored networking is the one that holds because it removes the virtual MAC
from the picture entirely rather than trying to pin it.

## Simulator licensing

`xsim` needs a Vivado Simulator feature checkout in addition to the Basic Tier
package. The free Basic Tier covers it for the parts this project targets, and
the first line of a working run says so:

```
INFO: [Common 17-3922] A valid Vivado Design Suite BASIC license has been detected.
```

If synthesis works but simulation does not, that is a separate feature
checkout failing, not the node-lock problem above.
