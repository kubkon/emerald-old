# emerald

`emerald` is a drop-in replacement for your system linker `ld` written in Zig.

## Quick start guide

### Building

You will need Zig 0.13.0 in your path. You can download it from [here](https://ziglang.org/download/).

```
$ zig build
```

This will create the `ld.emerald` (Elf), `ld64.emerald` (MachO), `emerald-link.exe` (Coff) and `wasm-emerald` (Wasm) binaries in `zig-out/bin/`.
You can then use it like you'd use a standard linker.

```
$ cat <<EOF > hello.c
#include <stdio.h>

int main() {
    fprintf(stderr, "Hello, World!\n");
    return 0;
}
EOF

# Create .o using system clang
$ clang -c hello.c

# Or, create .o using zig cc
$ zig cc -c hello.c

# On macOS
$ ./zig-out/bin/ld64.emerald hello.o -o hello

# On Linux
$ ./zig-out/bin/ld.emerald hello.o -o hello

# Run!
$ ./hello
```

### Testing

If you'd like to run unit and end-to-end tests, run the tests like you'd normally do for any other Zig project.

```
$ zig build test
```

## Supported backends

- [x] Mach-O (x86_64)
- [x] Mach-O (aarch64)
- [x] ELF (x86_64)
- [x] ELF (aarch64)
- [ ] ELF (riscv64)
- [ ] COFF (x86_64)
- [ ] COFF (aarch64)
- [x] Wasm (static)

## Contributing

You are welcome to contribute to this repo.

