# Zlay C API Example

This example demonstrates how to use the Zlay library from C code.

## Building

First, build the Zlay library:

```bash
cd ../../
zig build
```

Then, build the C example:

```bash
make
```

## Running

```bash
./zlay_c_example
```

## Notes

This example requires that the Zlay library has been built and is available in the `../../zig-out/lib` directory.

The example uses the C API defined in `zlay.h` to create a simple UI and render it to the console (using print statements in place of actual rendering).

Note that this is a demonstration - in a real application, you would likely link against actual rendering libraries like SDL, OpenGL, etc.