# meshcore-keygrind

GPU-accelerated **MeshCore hex prefix key generator** using Vulkan compute shaders.

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
```

## Quick Start

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/meshcore-grind cafe      # Find key with 0xcafe prefix
```

Or download from [Releases](https://github.com/pcace/meshcore-keygrind/releases):

```bash
wget https://github.com/pcace/meshcore-keygrind/releases/download/v0.1.0/meshcore-keygrind-linux-x86_64.tar.gz
tar xzf meshcore-keygrind-linux-x86_64.tar.gz
./meshcore-grind cafe
```

## Usage

```
meshcore-grind <hex-pattern>[:<count>] [options]
```

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help |
| `-t, --threads N` | Workgroup threads (default: 64) |

### Pattern

Hex characters (`0-9`, `a-f`, `A-F`), must be even length.
Pattern matches the **first N bytes** of the Ed25519 public key.

### Examples

```bash
meshcore-grind 00              # 1 byte  → instant
meshcore-grind cafe            # 2 bytes → <1s
meshcore-grind 1337cafe        # 4 bytes → ~16 min (RX 6600)
meshcore-grind deadbeef:5      # Find 5 keys
meshcore-grind aabb -t 128     # Custom workgroup size
```

### Performance (AMD RX 6600, ~3M keys/s)

| Bytes | Example | P50 Time |
|-------|---------|----------|
| 1 | `42` | <1s |
| 2 | `cafe` | <1s |
| 3 | `abc123` | ~4s |
| 4 | `1337cafe` | ~16 min |
| 5 | — | ~3 days |

## Output

Keys saved as `meshcore_<pattern>_<shortid>.key`:

```
<public_key_hex>       # 32 bytes = 64 hex chars
<private_key_hex>      # 64 bytes = 128 hex chars
                        # Format: [scalar(32)][sha512_prefix(32)]
```

Both keys are raw hex, compatible with MeshCore/Meshtastic.

## How It Works

1. GPU generates random 32-byte seeds (xorshift128+)
2. SHA-512 hashes each seed → 64 bytes
3. Clamps the scalar (Ed25519 standard)
4. Computes public key via Ed25519 scalar multiplication
5. Compares public key bytes directly against pattern bytes
6. On match: returns keypair in MeshCore format

All steps in a single GLSL compute shader — no CPU bottleneck.

## Architecture

```
src/
├── main.zig              # Entry point
├── cli.zig               # CLI, validation, output
├── pattern.zig           # Hex pattern parsing & matching
├── grinders/
│   ├── mod.zig           # Types
│   └── vulkan.zig        # Vulkan backend (DynLib)
└── shaders/
    └── vanity.comp       # GLSL compute shader
```

## License

MIT
