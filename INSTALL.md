# Source installation

Use a matching Nyra SDK/compiler and a source workspace entry:

```yaml
version: 1
packages:
  hazptr: /absolute/path/to/hazptr/package.yaml
```

Declare the dependency in the consuming package:

```yaml
dependencies:
  hazptr:
    workspace: true
```

Import `hazptr:hazptr.ny`. The core imports only the implicit kernel package;
hosted tests and the sample consumer use implicit stdlib/ntest from the selected
SDK. No C/C++ provider, system library installation or raw platform face is
needed. An allocator is explicit; hosted callers may pass
`Allocator.ProcessHeap(0i64, 0i64)` from stdlib. Injected contexts remain alive
through the final deferred callback and domain destruction.

Run independent checks with a task-owned output path outside this repository:

```sh
python3 scripts/ci.py --compiler /absolute/path/to/nyrac \
  --sdk-root /absolute/path/to/sdk --out-dir /absolute/path/to/task-cache
```

The checker runs O0/O2 tests and the independent public-barrel consumer, records
identities and removes emitted objects and executables. It does not publish a
package or qualify/promote an SDK.
