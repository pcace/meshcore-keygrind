# meshcore-keygrind

GPU-accelerated MeshCore hex prefix key generator using Vulkan compute shaders.

Finds Ed25519 keypairs whose public key starts with a given hex prefix.
All computation (SHA-512, Ed25519 scalar multiplication, pattern matching)
runs entirely on the GPU via GLSL compute shaders compiled to SPIR-V.

## Requirements

- **Zig 0.15+**
- **Vulkan** (libvulkan.so, Mesa RADV or similar)
- **glslc** (shaderc) for SPIR-V compilation

```bash
# Debian/Ubuntu
apt install libvulkan-dev glslc

# Or install glslc separately
# https://github.com/google/shaderc
```

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Binary: `./zig-out/bin/grincel`

## Usage

```
grincel <hex-pattern>[:<count>] [options]
```

### Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help |
| `-t, --threads N` | Workgroup threads (default: 64) |

### Pattern

Hex characters (`0-9`, `a-f`, `A-F`), must be even length.
The pattern matches the **first N bytes** of the Ed25519 public key.

### Examples

```bash
# Find one key with 00 prefix (1 byte, very fast)
grincel 00

# Find one key with 1337cafe prefix (4 bytes)
grincel 1337cafe

# Find 5 keys with deadbeef prefix
grincel deadbeef:5

# Custom workgroup size for tuning
grincel aabbccdd -t 128
```

## Output

Keys are saved as `meshcore_<pattern>_<shortid>.key`:

```
<public_key_hex>      # 32 bytes = 64 hex chars
<private_key_hex>     # 64 bytes = 128 hex chars
                       # Format: [scalar(32)][sha512_prefix(32)]
```

Both keys are raw hex, compatible with MeshCore.

## How It Works

1. GPU generates random 32-byte seeds
2. SHA-512 hashes each seed → 64 bytes
3. Clamps the scalar (Ed25519 standard clamping)
4. Computes public key via Ed25519 scalar multiplication
5. Compares public key bytes directly against pattern bytes
6. On match: returns keypair in MeshCore format

All steps run in a single GLSL compute shader — no CPU bottleneck.

## Architecture

```
src/
├── main.zig              # Entry point
├── cli.zig               # CLI, validation, output
├── pattern.zig           # Hex pattern parsing & matching
├── grinders/
│   ├── mod.zig           # Types: FoundKey, GpuPatternConfig
│   └── vulkan.zig        # Vulkan backend (dynamic loading)
└── shaders/
    └── vanity.comp       # GLSL compute shader (Ed25519 + matching)
```

## License

MIT
