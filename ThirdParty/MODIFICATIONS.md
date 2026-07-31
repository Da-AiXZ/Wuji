# Wuji S1 Modifications And Integration Boundary

Wuji does not modify the pinned iSH or libarchive gitlinks. Wuji adds a separate
adapter in `Executor/WujiISHAdapter.c` and Swift contracts in `Wuji/`.

The adapter:

- maps an enum to four fixed self-test commands and accepts no command string;
- uses separate host pipes for stdout and stderr;
- bounds retained output while continuing to drain both pipes to EOF;
- observes root exit separately and completes only after root exit plus both
  EOF observations;
- records cancellation request, signal delivery, and the final known or
  unknown guest state.

Wuji does not use upstream `app/ISHShellExecutor.h/.m`, OpenMinis Runtime,
Coordinator, ViewModel, bridge, or session routing. It does not initialize
`deps/libapps` or `deps/linux`. S1 does not claim safe reap, complete process
tree quiescence, or cold recovery.
