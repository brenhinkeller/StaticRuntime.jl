# The system and the architecture that the program that is being compiled is made for. The code of the runtime and of the overrides that differs between systems (the flags of
# `open`, the layout of `struct stat`, the names of functions of the C library) is chosen by these, by `if target_macos()`, and not by `@static if Sys.isapple()`, which is the
# host's, chosen when this package is compiled: a program for another system than the host's has the code of its own. While a program is compiled the calls of `target_system()`
# and `target_arch()` are constants for the inference (see `src/inference/dispatch.jl`), so the code for the other systems is not looked at, and not in the program; where they
# are called as Julia code they are the host's, unless `with_target` says another.

const TARGET_SYSTEM = Base.ScopedValues.ScopedValue{Symbol}(Sys.isapple() ? :macos : Sys.islinux() ? :linux : Sys.iswindows() ? :windows : :unknown)
const TARGET_ARCH = Base.ScopedValues.ScopedValue{Symbol}(Sys.ARCH)
# whether the program is made for a target other than the host's (what the host has when the program is made, as the library that BLAS is in, is not what the program finds where it runs)
const TARGET_CROSS = Base.ScopedValues.ScopedValue{Bool}(false)

"The system that the program is made for: `:macos`, `:linux`, ... (a constant while the program is compiled)"
@inline target_system() = TARGET_SYSTEM[]
"The architecture that the program is made for: `:aarch64`, `:x86_64`, ... (a constant while the program is compiled)"
@inline target_arch() = TARGET_ARCH[]
@inline target_macos() = target_system() === :macos
@inline target_windows() = target_system() === :windows
# the value for macOS, or the one for the other systems that this package has code for (Linux)
@inline target_choice(macos, other) = target_macos() ? macos : other
# the value for each of the systems that this package has code for
@inline target_value(macos, linux, windows) = target_macos() ? macos : target_windows() ? windows : linux

# Run `f` with the target of a compilation: `system` and `arch` as symbols
with_target(f, system::Symbol, arch::Symbol; cross::Bool = false) = Base.ScopedValues.with(f, TARGET_SYSTEM => system, TARGET_ARCH => arch, TARGET_CROSS => cross)
