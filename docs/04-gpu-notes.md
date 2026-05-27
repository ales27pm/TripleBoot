# GPU Notes

## RTX 2070 / NVIDIA Turing

The discussed machine includes an NVIDIA RTX 2070. For macOS/OpenCore, treat this as unsupported for hardware acceleration.

Practical consequences:

- No reliable Metal acceleration.
- Poor or unusable desktop performance for normal macOS work.
- OpenCore may boot only in a limited/unaccelerated mode if the GPU is not disabled correctly.
- The best bare-metal path is a compatible AMD GPU or a supported Intel iGPU configuration.

## Script behavior

When building an OpenCore scaffold, this option is available:

```bash
sudo scripts/tripleboot_aio.sh build-opencore-scaffold \
  --gpu-policy disable-nvidia
```

That adds `-wegnoegpu` to OpenCore boot args. This is a mitigation, not a compatibility fix.

## Better paths

### Supported AMD dGPU

For a serious macOS bare-metal setup, use a known-compatible AMD GPU family. Verify exact model and macOS version before buying.

### Intel iGPU

An Intel iGPU may work depending on CPU generation, board firmware, display routing, and macOS target version. DeviceProperties and framebuffer settings usually need manual review.

### VM/lab mode

If the goal is experimentation, documentation, or bootloader learning, a VM or non-accelerated boot lab may be acceptable. Do not expect production macOS performance from RTX/Turing.
