# Ubuntu 26.04 OEM kernel 7.0 audio notes

This documents a hardware-tested path for the MacBookPro14,1 when the running Ubuntu kernel is an OEM flavour rather than the generic kernel.

## Tested system

- MacBookPro14,1 (2017)
- CS8409 codec: `1013:8409`
- Apple subsystem: `106b:3300`
- Ubuntu 26.04
- Kernel: `7.0.0-1015-oem`
- Ubuntu source package: `linux-oem-7.0 7.0.0-1015.15`

## Installer issue

`install.cirrus.driver.sh` currently obtains `sound/hda/` from the Ubuntu release kernel tree. On an OEM kernel this can produce source that does not match the running kernel. In the tested case the script subsequently failed while replacing the expected HDA Makefiles.

For OEM kernels, build the module against source from the **matching source package/version for the running kernel**, not the release branch HEAD.

The matching 7.0 OEM source used here has the Cirrus codec at:

```
sound/hda/codecs/cirrus/cs8409.c
sound/hda/codecs/cirrus/cs8409.h
sound/hda/codecs/cirrus/cs8409-tables.c
```

and the build headers at:

```
/lib/modules/$(uname -r)/build
```

## Verified module result

The out-of-tree module built with:

```
vermagic: 7.0.0-1015-oem SMP preempt mod_unload modversions
```

and was installed under:

```
/lib/modules/7.0.0-1015-oem/updates/codecs/cirrus/snd-hda-codec-cs8409.ko
```

After `depmod -a` and reboot, the Apple path probed successfully and ALSA exposed `CS8409 Analog`.

Direct speaker playback was verified with the hardware-supported format:

```bash
speaker-test -D hw:0,0 -c 2 -r 44100 -F S32_LE -t sine
```

The tested PCM constraints were 44.1 kHz with S24_LE/S32_LE; a default 48 kHz/S16 speaker-test therefore fails with `Sample format not available for playback`.

## PipeWire note

A separate local PipeWire filter-chain configuration referencing the unavailable LADSPA plugin `gate_1408` prevented PipeWire from starting. Disabling that configuration restored normal desktop audio after the kernel driver was working. This is separate from the kernel/OEM source mismatch.

## Current limitation

Internal speaker output is confirmed working. Headphone unsolicited-event handling was not fully validated, so this should not be taken as confirmation that headphone jack handling is fixed.

## Proposed installer direction

The installer should detect OEM kernel flavours (for example, `*-oem`) and resolve the exact Ubuntu source package and version corresponding to the installed/running kernel before copying and patching `sound/hda`. Falling back to the release kernel branch HEAD is not reliable for OEM kernels.
