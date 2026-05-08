# RockPro64 Serial

Use a 3.3 V USB serial adapter and configure it for `115200n8`. If the USB
serial adapter has a 3.3 V selector, jumper, or solder bridge, short/select the
3.3 V setting before connecting it to the board.

Wire the serial adapter for bidirectional serial access:

| RockPro64 pin | Adapter pin | Purpose |
| --- | --- | --- |
| pin 6 `GND` | `GND` | Shared ground |
| pin 8 board `TXD` / `UART2_TX` | adapter `RXD` | Read board boot logs |
| pin 10 board `RXD` / `UART2_RX` | adapter `TXD` | Send U-Boot commands |

Do not connect the adapter power pin to the RockPro64. The 3.3 V setting is for
serial logic level selection, not for powering the board.

Bootswain fully supports this bidirectional RockPro64 serial workflow. It reads
boot logs from board `TXD` and sends U-Boot commands through board `RXD`, so
validation and recovery flows can both observe boot output and drive the U-Boot
shell.

## Manual Serial Console

Use `picocom` when you want to open the USB serial adapter directly:

```sh
nix-shell -p picocom
picocom -b 115200 /dev/ttyUSB0
```

Use the device path that matches the adapter if it is not `/dev/ttyUSB0`. Common
alternatives are `/dev/ttyUSB1` and `/dev/ttyACM0`. Exit picocom with
`Ctrl-a`, then `Ctrl-x`.

For Ignitix installer media, keep the serial console aligned with the ROCKPro64
module defaults:

```text
console=ttyS2,115200n8
earlycon=uart8250,mmio32,0xff1a0000,115200n8
```

If a board fails to power on with RXD connected, first verify adapter voltage,
grounding, and pin orientation. Then compare against Bootswain's current lab
notes before changing Ignitix serial policy.
